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
	"github.com/278946647/sip-proxy/gfc-client/internal/cpsync"
	"github.com/278946647/sip-proxy/gfc-client/internal/dataplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/envfile"
	"github.com/278946647/sip-proxy/gfc-client/internal/linecode"
	"github.com/278946647/sip-proxy/gfc-client/internal/metrics"
	"github.com/278946647/sip-proxy/gfc-client/internal/payload"
	"github.com/278946647/sip-proxy/gfc-client/internal/reversessh"
	"github.com/278946647/sip-proxy/gfc-client/internal/stats"
	"github.com/278946647/sip-proxy/gfc-client/internal/store"
	"github.com/278946647/sip-proxy/gfc-client/internal/traffic"
	"github.com/278946647/sip-proxy/gfc-client/internal/upgrade"
)

type Runner struct {
	cfg               *config.Config
	store             *store.Store
	engine            *dataplane.Engine
	activation        *activation.Service
	revSSH            *reversessh.Manager
	pendingReverseSSH bool
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
		delay := r.cfg.PollSeconds
		if r.pendingReverseSSH {
			fast := r.cfg.PollSecondsFast
			if fast > 0 && fast < delay {
				delay = fast
			}
		}
		ticker.Reset(time.Duration(delay) * time.Second)
		<-ticker.C
	}
}

func (r *Runner) tick() {
	if reversessh.ConsumeRestoreRequest() {
		if ok, msg := r.revSSH.RestoreAfterNetwork(); msg != "" {
			fmt.Printf("reverse ssh restore: %s (ok=%v)\n", msg, ok)
		}
		r.pendingReverseSSH = true
	}

	state, stateErr := r.activation.LoadClientState()
	hasToken := stateErr == nil && state != nil && state.ClientToken != ""

	code, payload, actErr := r.activation.ReadActivation()
	hasLineCode := actErr == nil && code != "" && linecode.IsLine(payload)

	var servers []string
	if hasLineCode {
		servers = r.resolveServers(payload)
	} else {
		servers = r.envServers()
	}

	// Soft factory reset clears line code but keeps token — stay platform-managed.
	if !hasLineCode {
		if !hasToken {
			r.writeIdle("请刷入线路码")
			return
		}
		if len(servers) == 0 {
			r.writeIdle("缺少控制平台地址")
			return
		}
	} else if len(servers) == 0 {
		r.writeIdle("线路码缺少控制平台地址")
		return
	}

	var client *controlplane.Client
	if !hasToken {
		if !hasLineCode {
			r.writeIdle("请刷入线路码")
			return
		}
		var err error
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
		// Prefer line TID as local display name when hostname is a stock placeholder
		// (e.g. ImmortalWrt "(none)"); platform also maps placeholders → TID.
		deviceName := r.cfg.DeviceName
		if st.TID != "" && isPlaceholderDeviceName(deviceName) {
			deviceName = st.TID
			r.cfg.DeviceName = st.TID
		}
		if err := r.saveState(st); err != nil {
			fmt.Printf("save state: %v\n", err)
		}
		_ = r.store.SaveDevice(store.Device{
			DeviceKey: st.DeviceKey, DeviceName: deviceName, LanMAC: mac,
			DeviceID: deviceID, LineID: st.LineID, TID: st.TID, ClientToken: st.ClientToken,
			ControlPlaneURL: client.ActiveServer(), ProxyMode: r.cfg.ProxyMode, State: "active",
		})
		client, _ = controlplane.New(servers, st.ClientToken)
		fmt.Printf("activated line=%s via %s\n", st.TID, client.ActiveServer())
	} else {
		var err error
		client, err = controlplane.New(servers, state.ClientToken)
		if err != nil {
			return
		}
		if state.TID != "" && isPlaceholderDeviceName(r.cfg.DeviceName) {
			r.cfg.DeviceName = state.TID
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

	pubKey, _ := r.revSSH.EnsureKeypair()
	hb, err := client.Heartbeat(m, r.cfg.DeviceName, nil, nil, pubKey, nil, r.cfg.ProxyMode, config.Version, nil)
	r.pendingReverseSSH = false
	if err != nil {
		fmt.Printf("heartbeat: %v\n", err)
		if strings.Contains(err.Error(), "401") || strings.Contains(strings.ToLower(err.Error()), "invalid client token") {
			// Hard-retire invalidates token; clear local state so we do not loop forever.
			// Soft unbind keeps token — do not clear on generic heartbeat errors.
			fmt.Printf("heartbeat auth failed; clearing client state (re-flash or reclaim required)\n")
			_ = os.Remove(r.cfg.Paths.StateFile)
			return
		}
	} else {
		cmd := reversessh.ParseCommand(nil)
		var deviceCmdAck map[string]any
		if hb != nil {
			cmd = reversessh.ParseCommand(hb.ReverseSSH)
			if err := reversessh.EnsureWebSSHAuthorizedKey(hb.WebSSHAuthorizedKey); err != nil {
				fmt.Printf("webssh authorized key: %v\n", err)
			}
			if hb.DeviceCommand != nil {
				deviceCmdAck = r.applyDeviceCommand(hb.DeviceCommand)
			}
		}
		ok, msg, active := r.syncReverseSSH(cmd)
		if reversessh.ProcessRunning() {
			active = true
		}
		if cmd != nil && cmd.Enabled && !active {
			r.pendingReverseSSH = true
		}
		status := map[string]any{"active": active}
		if !active && ok && msg == "reverse ssh disabled" {
			status["active"] = false
		}
		if active {
			status["active"] = true
		}
		if _, err := client.Heartbeat(m, r.cfg.DeviceName, nil, nil, "", status, r.cfg.ProxyMode, config.Version, deviceCmdAck); err != nil {
			fmt.Printf("heartbeat status: %v\n", err)
		}
		if msg != "" {
			fmt.Printf("reverse ssh: %s\n", msg)
		}
	}

	bundle, err := client.PullConfig()
	if err != nil {
		fmt.Printf("pull config: %v\n", err)
		return
	}
	payload2 := bundle.Payload
	r.applyPlatformDeviceName(payload2)
	r.mergePayloadProxyMode(payload2)
	r.reconcileRoutingScheme(payload2, bundle.Version, state.AppliedVersion)
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
	if payload.RoutingMode(old) != payload.RoutingMode(p) {
		return false
	}
	return r.currentSingboxMatches(p)
}

func (r *Runner) mergePayloadProxyMode(payload map[string]any) {
	pm, ok := payload["proxyMode"].(string)
	if !ok || strings.TrimSpace(pm) == "" {
		payload["proxyMode"] = r.cfg.ProxyMode
		return
	}
	pm = strings.ToLower(strings.TrimSpace(pm))
	if pm != r.cfg.ProxyMode {
		_ = envfile.Set(r.cfg.Paths.EnvFile, "GFC_PROXY_MODE", pm)
		_ = os.Setenv("GFC_PROXY_MODE", pm)
		r.cfg.ProxyMode = pm
	}
	payload["proxyMode"] = pm
}

func (r *Runner) reconcileRoutingScheme(cpPayload map[string]any, cpVersion, appliedVersion string) {
	local := r.engine.LoadBundle()
	if local == nil {
		return
	}
	localMode := payload.RoutingMode(local)
	cpMode := payload.RoutingMode(cpPayload)
	if localMode == cpMode {
		return
	}
	// New bundle version from control plane — platform change wins.
	if cpVersion != appliedVersion {
		return
	}
	if err := cpsync.SyncRuntime(r.cfg, r.store, cpsync.Runtime{RoutingScheme: localMode}); err != nil {
		fmt.Printf("sync routing to control plane: %v\n", err)
	}
	cpPayload["routingScheme"] = localMode
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

func (r *Runner) syncReverseSSH(cmd *reversessh.Command) (bool, string, bool) {
	ok, msg := r.revSSH.SyncCommand(cmd)
	active := r.revSSH.Status()["active"] == "active"
	return ok, msg, active
}

// applyPlatformDeviceName syncs admin-authored device name from config bundle.
func (r *Runner) applyPlatformDeviceName(p map[string]any) {
	raw, _ := p["deviceName"].(string)
	name := strings.TrimSpace(raw)
	if name == "" || name == r.cfg.DeviceName {
		return
	}
	r.cfg.DeviceName = name
	_ = envfile.Set(r.cfg.Paths.EnvFile, "DEVICE_NAME", name)
	_ = os.Setenv("DEVICE_NAME", name)
	fmt.Printf("device name synced from platform: %s\n", name)
}

func (r *Runner) applyDeviceCommand(cmd *controlplane.DeviceCommand) map[string]any {
	if cmd == nil || cmd.RequestID == "" {
		return nil
	}
	switch cmd.Action {
	case "factory_reset_soft":
		if err := r.activation.ClearLineCode(); err != nil {
			fmt.Printf("soft factory reset: clear line code: %v\n", err)
		} else {
			fmt.Printf("soft factory reset: line code cleared (platform custody retained)\n")
		}
		return map[string]any{
			"request_id": cmd.RequestID,
			"status":     "ok",
			"action":     cmd.Action,
		}
	case "runtime_upgrade":
		url := strings.TrimSpace(cmd.DownloadURL)
		if url == "" && cmd.DownloadPath != "" {
			base := ""
			if st, err := r.activation.LoadClientState(); err == nil && st != nil {
				_ = st
			}
			servers := r.envServers()
			if len(servers) > 0 {
				base = strings.TrimRight(servers[0], "/")
			}
			url = base + cmd.DownloadPath
		}
		token := ""
		if st, err := r.activation.LoadClientState(); err == nil && st != nil {
			token = st.ClientToken
		}
		fmt.Printf("runtime upgrade: downloading %s version=%s\n", url, cmd.Version)
		msg, err := upgrade.DownloadAndApply(url, token, cmd.SHA256, cmd.Filename)
		status := "ok"
		if err != nil {
			status = "failed"
			msg = err.Error() + " " + msg
			fmt.Printf("runtime upgrade failed: %s\n", msg)
		} else {
			fmt.Printf("runtime upgrade ok: %s\n", msg)
		}
		return map[string]any{
			"request_id": cmd.RequestID,
			"status":     status,
			"action":     cmd.Action,
			"message":    msg,
		}
	default:
		fmt.Printf("unknown device command: %s\n", cmd.Action)
		return map[string]any{
			"request_id": cmd.RequestID,
			"status":     "ignored",
			"action":     cmd.Action,
		}
	}
}

func isPlaceholderDeviceName(name string) bool {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "", "(none)", "none", "openwrt", "immortalwrt", "localhost", "gfc-client":
		return true
	default:
		return false
	}
}
