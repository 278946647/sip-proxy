package agent

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/activation"
	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/controlplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/dataplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/linecode"
	"github.com/278946647/sip-proxy/gfc-client/internal/metrics"
	"github.com/278946647/sip-proxy/gfc-client/internal/payload"
	"github.com/278946647/sip-proxy/gfc-client/internal/reversessh"
	"github.com/278946647/sip-proxy/gfc-client/internal/stats"
	"github.com/278946647/sip-proxy/gfc-client/internal/store"
	"github.com/278946647/sip-proxy/gfc-client/internal/traffic"
)

type Runner struct {
	cfg        *config.Config
	store      *store.Store
	engine     *dataplane.Engine
	activation *activation.Service
	revSSH     *reversessh.Manager
}

func NewRunner(cfg *config.Config, st *store.Store) *Runner {
	engine := dataplane.New(cfg)
	return &Runner{
		cfg:        cfg,
		store:      st,
		engine:     engine,
		activation: activation.New(cfg, st, engine),
		revSSH:     reversessh.New(cfg),
	}
}

func (r *Runner) Run() {
	rec := traffic.NewRecorder(r.store)
	go rec.Run(r.engine)

	if ok, msg := r.engine.ReapplyLocal(true); !ok {
		fmt.Printf("bootstrap dataplane failed: %s\n", msg)
	} else {
		fmt.Printf("bootstrap dataplane: %s\n", msg)
	}
	ticker := time.NewTicker(time.Duration(r.cfg.PollSeconds) * time.Second)
	defer ticker.Stop()
	for {
		r.tick()
		<-ticker.C
	}
}

func (r *Runner) tick() {
	code, payload, err := r.activation.ReadActivation()
	if err != nil || code == "" {
		r.writeIdle("请刷入线路码")
		return
	}
	if !linecode.IsLine(payload) {
		r.writeIdle("等待线路码")
		return
	}
	servers := r.resolveServers(payload)
	if len(servers) == 0 {
		r.writeIdle("线路码缺少控制平台地址")
		return
	}

	state, err := r.activation.LoadClientState()
	var client *controlplane.Client
	if err != nil || state == nil || state.ClientToken == "" {
		client, err = controlplane.New(servers, "")
		if err != nil {
			r.writeIdle(err.Error())
			return
		}
		mac := metrics.MACAddress()
		deviceID := metrics.DeviceIDFromMAC(mac)
		st, err := client.Activate(code, r.cfg.DeviceName, mac, deviceID, r.cfg.ProxyMode, config.Version)
		if err != nil {
			fmt.Printf("activate error: %v\n", err)
			r.writeIdle("激活失败: "+err.Error())
			return
		}
		state = st
		if err := r.saveState(st); err != nil {
			fmt.Printf("save state: %v\n", err)
		}
		_ = r.store.SaveDevice(store.Device{
			DeviceKey: st.DeviceKey, DeviceName: r.cfg.DeviceName, LanMAC: mac,
			DeviceID: deviceID, LineID: st.LineID, TID: st.TID, ClientToken: st.ClientToken,
			ControlPlaneURL: client.ActiveServer(), ProxyMode: r.cfg.ProxyMode, State: "active",
		})
		client, _ = controlplane.New(servers, st.ClientToken)
		fmt.Printf("activated line=%s via %s\n", st.TID, client.ActiveServer())
	} else {
		client, err = controlplane.New(servers, state.ClientToken)
		if err != nil {
			return
		}
	}

	reachable := client.CheckReachable()
	m := metrics.Collect(r.cfg, client.ActiveServer(), reachable)
	if r.engine.IsDirectMode() {
		stats.ResetTunnelSampler()
	} else if tunnel := stats.SampleTunnel(config.TunInterface, r.cfg.PollSeconds); tunnel != nil {
		m["tunnel_traffic"] = tunnel
	}
	m["agent_state"] = "active"
	device := map[string]any{"device_key": state.DeviceKey, "line_id": state.LineID, "tid": state.TID}
	_ = metrics.WriteStatus(r.cfg.Paths.StatusFile, m, device)

	sshPort := reversessh.Port(state.DeviceKey, 0)
	reverseSSH := &sshPort
	_ = client.Heartbeat(m, r.cfg.DeviceName, reverseSSH, r.cfg.ProxyMode, config.Version)
	if ok, msg := r.revSSH.Sync(state.DeviceKey); ok {
		fmt.Printf("reverse ssh: %s\n", msg)
	}

	bundle, err := client.PullConfig()
	if err != nil {
		fmt.Printf("pull config: %v\n", err)
		return
	}
	payload2 := bundle.Payload
	payload2["proxyMode"] = r.cfg.ProxyMode
	if cp := client.ActiveServer(); cp != "" {
		payload2["controlPlaneServers"] = []any{cp}
	}

	needApply := state.AppliedVersion != bundle.Version
	if !needApply {
		needApply = !r.configMatches(payload2)
	}
	if needApply {
		ok, msg := r.engine.ApplyPayload(payload2, bundle.Version, true)
		if ok {
			_ = client.AckConfig(bundle.Version, "applied", msg)
			state.AppliedVersion = bundle.Version
			_ = r.saveState(state)
			r.syncNode(payload2)
			_ = r.store.SaveDevice(store.Device{
				DeviceKey: state.DeviceKey, DeviceName: r.cfg.DeviceName,
				LineID: state.LineID, TID: state.TID, ClientToken: state.ClientToken,
				ControlPlaneURL: client.ActiveServer(), ProxyMode: r.cfg.ProxyMode,
				State: "active", AppliedVersion: bundle.Version,
			})
			fmt.Printf("applied version=%s %s\n", bundle.Version, msg)
		} else {
			_ = client.AckConfig(bundle.Version, "failed", msg)
			fmt.Printf("apply failed: %s\n", msg)
		}
	}
}

func (r *Runner) syncNode(payload map[string]any) {
	node, _ := payload["node"].(map[string]any)
	vless, _ := payload["vless"].(map[string]any)
	if node == nil {
		return
	}
	id := fmt.Sprint(node["id"])
	name, _ := node["name"].(string)
	addr, _ := node["address"].(string)
	port := 443
	if p, ok := node["port"].(float64); ok {
		port = int(p)
	}
	uuid, _ := vless["uuid"].(string)
	cfg := map[string]any{"node": node, "vless": vless}
	_ = r.store.UpsertNode(id, name, addr, port, uuid, cfg)
}

func (r *Runner) configMatches(p map[string]any) bool {
	if payload.IsDirect(p) {
		return r.engine.IsDirectMode()
	}
	if r.engine.IsDirectMode() {
		return false
	}
	old := r.engine.LoadBundle()
	if old == nil {
		return false
	}
	if fmt.Sprint(old["proxyMode"]) != fmt.Sprint(p["proxyMode"]) {
		return false
	}
	return r.currentSingboxMatches(p)
}

func (r *Runner) currentSingboxMatches(payload map[string]any) bool {
	node, _ := payload["node"].(map[string]any)
	if node == nil {
		return false
	}
	wantServer := strings.TrimSpace(fmt.Sprint(node["address"]))
	if wantServer == "" {
		return false
	}
	data, err := os.ReadFile(r.cfg.Paths.SingboxConfig)
	if err != nil {
		return false
	}
	var cfg map[string]any
	if json.Unmarshal(data, &cfg) != nil {
		return false
	}
	hasTun := false
	if inbounds, ok := cfg["inbounds"].([]any); ok {
		for _, item := range inbounds {
			m, _ := item.(map[string]any)
			if fmt.Sprint(m["type"]) == "tun" {
				hasTun = true
				break
			}
		}
	}
	hasNode := false
	if outbounds, ok := cfg["outbounds"].([]any); ok {
		for _, item := range outbounds {
			m, _ := item.(map[string]any)
			if fmt.Sprint(m["type"]) == "vless" && strings.TrimSpace(fmt.Sprint(m["server"])) == wantServer {
				hasNode = true
				break
			}
		}
	}
	return hasTun && hasNode
}

func (r *Runner) saveState(st *controlplane.ClientState) error {
	raw, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(r.cfg.Paths.StateFile), 0o755); err != nil {
		return err
	}
	return os.WriteFile(r.cfg.Paths.StateFile, raw, 0o600)
}

func (r *Runner) writeIdle(msg string) {
	servers := r.envServers()
	cp := ""
	if len(servers) > 0 {
		cp = servers[0]
	}
	m := metrics.Collect(r.cfg, cp, false)
	m["agent_state"] = "waiting_line_code"
	m["agent_message"] = msg
	_ = metrics.WriteStatus(r.cfg.Paths.StatusFile, m, map[string]any{})
}

func (r *Runner) resolveServers(payload map[string]any) []string {
	urls := linecode.ServerURLs(payload)
	if len(urls) > 0 {
		return urls
	}
	return r.envServers()
}

func (r *Runner) envServers() []string {
	var urls []string
	for _, key := range []string{"SERVER_URL", "SERVER_URL_FALLBACK"} {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			urls = append(urls, strings.TrimRight(v, "/"))
		}
	}
	return urls
}
