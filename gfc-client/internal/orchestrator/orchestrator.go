package orchestrator

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/dnslists"
	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
	"github.com/278946647/sip-proxy/gfc-client/internal/render/mosdns"
	"github.com/278946647/sip-proxy/gfc-client/internal/render/singbox"
	"github.com/278946647/sip-proxy/gfc-client/internal/rules"
)

const BackupGenerations = config.BackupGenerations

type Orchestrator struct {
	cfg      *config.Config
	singbox  *singbox.Renderer
	mosdns   *mosdns.Renderer
	rules    *rules.Manager
	dnsLists *dnslists.Manager
}

func New(cfg *config.Config) *Orchestrator {
	return &Orchestrator{
		cfg:      cfg,
		singbox:  singbox.NewRenderer(cfg),
		mosdns:   mosdns.NewRenderer(cfg),
		rules:    rules.New(cfg),
		dnsLists: dnslists.New(cfg),
	}
}

func (o *Orchestrator) trackedFiles() map[string]string {
	return map[string]string{
		"sing-box.json":  o.cfg.Paths.SingboxConfig,
		"mosdns.yaml":    o.cfg.Paths.MosdnsConfig,
		"config_bundle":  o.cfg.Paths.ConfigBundle,
	}
}

func (o *Orchestrator) snapshotBefore(version string) error {
	id := version
	if id == "" {
		id = "pre-" + time.Now().UTC().Format("20060102-150405")
	}
	return Save(o.cfg.Paths.BackupsDir, id, o.trackedFiles())
}

func (o *Orchestrator) BootstrapIdle() (bool, string) {
	var msgs []string
	_ = o.dnsLists.EnsureDefaults()
	ok, rmsgs := o.rules.EnsureLocal(false)
	msgs = append(msgs, rmsgs...)
	if !ok {
		msgs = append(msgs, "rules incomplete (using bundled if present)")
	}
	if err := o.mosdns.Render(); err != nil {
		return false, "mosdns: " + err.Error()
	}
	if err := mosdns.CheckConfig(o.cfg.Paths.MosdnsConfig); err != nil {
		return false, "mosdns check: " + err.Error()
	}
	msgs = append(msgs, "mosdns ok")

	idle := o.singbox.IdleConfig()
	if err := singbox.WriteConfig(o.cfg.Paths.SingboxConfig, idle); err != nil {
		return false, err.Error()
	}
	if err := singbox.CheckConfig(o.cfg.Paths.SingboxConfig); err != nil {
		return false, "sing-box idle: " + err.Error()
	}
	msgs = append(msgs, "sing-box idle ok")
	o.writeMode("idle", false)
	return true, joinMsgs(msgs)
}

func (o *Orchestrator) ApplyPayload(payload map[string]any, version string, restart bool) (bool, string) {
	return o.applyPayload(payload, version, restart, true)
}

func (o *Orchestrator) applyPayload(payload map[string]any, version string, restart, snapshot bool) (bool, string) {
	node, _ := payload["node"].(map[string]any)
	addr, _ := node["address"].(string)
	if strings.TrimSpace(addr) == "" {
		return o.BootstrapIdle()
	}

	if snapshot {
		if err := o.snapshotBefore(version); err != nil {
			return false, "snapshot: " + err.Error()
		}
	}

	var msgs []string
	_ = o.dnsLists.EnsureDefaults()
	o.rules.EnsureLocal(true)

	if err := o.mosdns.Render(); err != nil {
		o.rollbackQuiet()
		return false, "mosdns: " + err.Error()
	}
	if err := mosdns.CheckConfig(o.cfg.Paths.MosdnsConfig); err != nil {
		o.rollbackQuiet()
		return false, "mosdns check: " + err.Error()
	}
	msgs = append(msgs, "mosdns ok")

	ruleSets := o.rules.Entries()
	cfg, err := o.singbox.RenderActive(payload, ruleSets)
	if err != nil {
		o.rollbackQuiet()
		return false, err.Error()
	}
	if err := singbox.WriteConfig(o.cfg.Paths.SingboxConfig, cfg); err != nil {
		o.rollbackQuiet()
		return false, err.Error()
	}
	if err := singbox.CheckConfig(o.cfg.Paths.SingboxConfig); err != nil {
		o.rollbackQuiet()
		return false, "sing-box: " + err.Error()
	}
	msgs = append(msgs, "sing-box active ok")

	if err := o.saveBundle(payload); err != nil {
		o.rollbackQuiet()
		return false, err.Error()
	}
	o.writeMode("active", true)
	msgs = append(msgs, o.postDataplaneRepair()...)
	if restart {
		msgs = append(msgs, o.restartDataplaneServices()...)
	}
	return true, joinMsgs(msgs)
}

func (o *Orchestrator) Rollback() (bool, string) {
	mapping := map[string]string{
		"sing-box.json": o.cfg.Paths.SingboxConfig,
		"mosdns.yaml":   o.cfg.Paths.MosdnsConfig,
		"config_bundle": o.cfg.Paths.ConfigBundle,
	}
	id, err := Restore(o.cfg.Paths.BackupsDir, mapping)
	if err != nil {
		return false, err.Error()
	}
	msgs := []string{"restored snapshot " + id}

	// Re-render from restored bundle (current templates + WAN patch), not raw JSON only.
	payload := o.LoadBundle()
	if payload != nil {
		if node, _ := payload["node"].(map[string]any); node != nil {
			if addr, _ := node["address"].(string); strings.TrimSpace(addr) != "" {
				ok, sub := o.applyPayload(payload, "rollback", true, false)
				if !ok {
					return false, joinMsgs(append(msgs, sub))
				}
				return true, joinMsgs(append(msgs, sub))
			}
		}
	}
	msgs = append(msgs, o.postDataplaneRepair()...)
	msgs = append(msgs, o.restartDataplaneServices()...)
	return true, joinMsgs(msgs)
}

func (o *Orchestrator) rollbackQuiet() {
	_, _ = o.Rollback()
}

func (o *Orchestrator) LoadBundle() map[string]any {
	data, err := os.ReadFile(o.cfg.Paths.ConfigBundle)
	if err != nil {
		return nil
	}
	var payload map[string]any
	if json.Unmarshal(data, &payload) != nil {
		return nil
	}
	return payload
}

func (o *Orchestrator) ReapplyLocal(restart bool) (bool, string) {
	payload := o.LoadBundle()
	if payload == nil {
		return o.BootstrapIdle()
	}
	node, _ := payload["node"].(map[string]any)
	addr, _ := node["address"].(string)
	if strings.TrimSpace(addr) == "" {
		return o.BootstrapIdle()
	}
	return o.applyPayload(payload, "local", restart, false)
}

func (o *Orchestrator) postDataplaneRepair() []string {
	var msgs []string
	root := o.cfg.Paths.Root
	shell := "/bin/bash"
	routingScript := filepath.Join(root, "deploy", "gfc-routing.sh")
	if platform.IsOpenWrt() {
		shell = "/bin/sh"
		routingScript = filepath.Join(root, "deploy", "immortalwrt", "gfc-routing.sh")
	}
	for _, spec := range []struct {
		label string
		args  []string
	}{
		{"patch-singbox-wan", []string{filepath.Join(root, "deploy", "patch-singbox-wan.sh")}},
		{"gfc-routing", []string{routingScript, "start"}},
	} {
		script := spec.args[0]
		if _, err := os.Stat(script); err != nil {
			continue
		}
		cmd := exec.Command(shell, spec.args...)
		out, err := cmd.CombinedOutput()
		line := strings.TrimSpace(string(out))
		if err != nil {
			msgs = append(msgs, fmt.Sprintf("%s: %s", spec.label, line))
			continue
		}
		if line != "" {
			msgs = append(msgs, line)
		} else {
			msgs = append(msgs, spec.label+": ok")
		}
	}
	return msgs
}

func (o *Orchestrator) restartDataplaneServices() []string {
	o.purgeStaleTun()
	return o.RestartServices()
}

func (o *Orchestrator) purgeStaleTun() {
	if _, err := exec.LookPath("ip"); err != nil {
		return
	}
	_ = exec.Command("ip", "link", "delete", config.TunInterface).Run()
}

func (o *Orchestrator) ReloadDNS() (bool, string) {
	if o.LoadBundle() == nil {
		return o.BootstrapIdle()
	}
	if err := o.mosdns.Render(); err != nil {
		return false, err.Error()
	}
	if err := mosdns.CheckConfig(o.cfg.Paths.MosdnsConfig); err != nil {
		return false, err.Error()
	}
	return true, o.restartUnit(config.ServiceMosDNS)
}

func (o *Orchestrator) RestartServices() []string {
	return []string{
		o.restartUnit(config.ServiceMosDNS),
		o.restartUnit(config.ServiceSingbox),
		o.restartUnit(config.ServiceRouting),
	}
}

func (o *Orchestrator) RestartUnit(name string) (bool, string) {
	return platform.RestartLogical(name)
}

func (o *Orchestrator) restartUnit(unit string) string {
	ok, msg := platform.Restart(unit)
	if !ok {
		return fmt.Sprintf("%s: %s", unit, msg)
	}
	return msg
}

func (o *Orchestrator) saveBundle(payload map[string]any) error {
	path := o.cfg.Paths.ConfigBundle
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(path, raw, 0o600)
}

func (o *Orchestrator) writeMode(mode string, activated bool) {
	data, _ := json.MarshalIndent(map[string]any{"mode": mode, "activated": activated}, "", "  ")
	_ = os.WriteFile(o.cfg.Paths.DataplaneMode, data, 0o644)
}

func joinMsgs(msgs []string) string {
	return strings.Join(msgs, "; ")
}

func ServiceStatus() map[string]any {
	return platform.ServiceStatus()
}
