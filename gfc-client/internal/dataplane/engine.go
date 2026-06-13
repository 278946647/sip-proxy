package dataplane

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/dnslists"
	"github.com/278946647/sip-proxy/gfc-client/internal/render/mosdns"
	"github.com/278946647/sip-proxy/gfc-client/internal/render/singbox"
	"github.com/278946647/sip-proxy/gfc-client/internal/rules"
)

type Engine struct {
	cfg      *config.Config
	singbox  *singbox.Renderer
	mosdns   *mosdns.Renderer
	rules    *rules.Manager
	dnsLists *dnslists.Manager
}

func New(cfg *config.Config) *Engine {
	return &Engine{
		cfg:      cfg,
		singbox:  singbox.NewRenderer(cfg),
		mosdns:   mosdns.NewRenderer(cfg),
		rules:    rules.New(cfg),
		dnsLists: dnslists.New(cfg),
	}
}

func (e *Engine) BootstrapIdle() (bool, string) {
	var msgs []string
	_ = e.dnsLists.EnsureDefaults()
	ok, rmsgs := e.rules.EnsureLocal(true)
	msgs = append(msgs, rmsgs...)
	if !ok {
		msgs = append(msgs, "rules incomplete")
	}
	if err := e.mosdns.Render(); err != nil {
		return false, "mosdns: " + err.Error()
	}
	if err := mosdns.CheckConfig(e.cfg.Paths.MosdnsConfig); err != nil {
		return false, "mosdns check: " + err.Error()
	}
	msgs = append(msgs, "mosdns ok")
	idle := e.singbox.IdleConfig()
	if err := singbox.WriteConfig(e.cfg.Paths.SingboxConfig, idle); err != nil {
		return false, err.Error()
	}
	if err := singbox.CheckConfig(e.cfg.Paths.SingboxConfig); err != nil {
		return false, "sing-box idle: " + err.Error()
	}
	msgs = append(msgs, "sing-box idle ok")
	e.writeMode("idle", false)
	msgs = append(msgs, e.RestartServices()...)
	return true, joinMsgs(msgs)
}

func (e *Engine) ApplyPayload(payload map[string]any, restart bool) (bool, string) {
	node, _ := payload["node"].(map[string]any)
	addr, _ := node["address"].(string)
	if addr == "" {
		return e.BootstrapIdle()
	}
	var msgs []string
	_ = e.dnsLists.EnsureDefaults()
	e.rules.EnsureLocal(true)
	if err := e.mosdns.Render(); err != nil {
		return false, "mosdns: " + err.Error()
	}
	if err := mosdns.CheckConfig(e.cfg.Paths.MosdnsConfig); err != nil {
		return false, "mosdns check: " + err.Error()
	}
	msgs = append(msgs, "mosdns ok")

	ruleSets := e.rules.Entries()
	cfg, err := e.singbox.RenderActive(payload, ruleSets)
	if err != nil {
		return false, err.Error()
	}
	if err := singbox.WriteConfig(e.cfg.Paths.SingboxConfig, cfg); err != nil {
		return false, err.Error()
	}
	if err := singbox.CheckConfig(e.cfg.Paths.SingboxConfig); err != nil {
		return false, "sing-box: " + err.Error()
	}
	msgs = append(msgs, "sing-box active ok")

	if err := e.saveBundle(payload); err != nil {
		return false, err.Error()
	}
	e.writeMode("active", true)
	if restart {
		msgs = append(msgs, e.RestartServices()...)
	}
	return true, joinMsgs(msgs)
}

func (e *Engine) saveBundle(payload map[string]any) error {
	path := e.cfg.Paths.ConfigBundle
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o600)
}

func (e *Engine) LoadBundle() map[string]any {
	data, err := os.ReadFile(e.cfg.Paths.ConfigBundle)
	if err != nil {
		return nil
	}
	var payload map[string]any
	if json.Unmarshal(data, &payload) != nil {
		return nil
	}
	return payload
}

func (e *Engine) ReapplyLocal(restart bool) (bool, string) {
	payload := e.LoadBundle()
	if payload == nil {
		return e.BootstrapIdle()
	}
	node, _ := payload["node"].(map[string]any)
	addr, _ := node["address"].(string)
	if addr == "" {
		return e.BootstrapIdle()
	}
	return e.ApplyPayload(payload, restart)
}

func (e *Engine) ReloadDNS() (bool, string) {
	payload := e.LoadBundle()
	if payload == nil {
		return e.BootstrapIdle()
	}
	if err := e.mosdns.Render(); err != nil {
		return false, err.Error()
	}
	if err := mosdns.CheckConfig(e.cfg.Paths.MosdnsConfig); err != nil {
		return false, err.Error()
	}
	return true, e.restartUnit("gfc-mosdns.service")
}

func (e *Engine) RestartServices() []string {
	return []string{
		e.restartUnit("gfc-mosdns.service"),
		e.restartUnit("gfc-client-sing-box.service"),
	}
}

func (e *Engine) restartUnit(unit string) string {
	if _, err := os.Stat("/bin/systemctl"); err != nil {
		return unit + ": no systemd"
	}
	cmd := exec.Command("systemctl", "restart", unit)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Sprintf("%s: %s", unit, string(out))
	}
	return unit + ": restarted"
}

func (e *Engine) RestartUnit(name string) (bool, string) {
	units := map[string]string{
		"agent":    "gfc-client-agent.service",
		"sing-box": "gfc-client-sing-box.service",
		"mosdns":   "gfc-mosdns.service",
		"api":      "gfc-client-api.service",
		"dnsmasq":  "dnsmasq.service",
	}
	unit, ok := units[name]
	if !ok {
		return false, "unknown service"
	}
	return true, e.restartUnit(unit)
}

func (e *Engine) writeMode(mode string, activated bool) {
	data, _ := json.MarshalIndent(map[string]any{"mode": mode, "activated": activated}, "", "  ")
	_ = os.WriteFile(e.cfg.Paths.DataplaneMode, data, 0o644)
}

func joinMsgs(msgs []string) string {
	return strings.Join(msgs, "; ")
}

func ServiceStatus() map[string]any {
	units := map[string]string{
		"agent": "gfc-client-agent.service", "sing-box": "gfc-client-sing-box.service",
		"mosdns": "gfc-mosdns.service", "api": "gfc-client-api.service",
	}
	result := map[string]any{}
	for name, unit := range units {
		active, sub := systemdActive(unit)
		result[name] = map[string]any{"unit": unit, "active": active, "sub": sub}
	}
	return result
}

func systemdActive(unit string) (string, string) {
	cmd := exec.Command("systemctl", "is-active", unit)
	out, _ := cmd.Output()
	active := string(out)
	cmd2 := exec.Command("systemctl", "show", unit, "--property=SubState", "--value")
	out2, _ := cmd2.Output()
	return active, string(out2)
}
