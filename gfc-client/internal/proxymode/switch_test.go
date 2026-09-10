package proxymode

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/transparent"
)

func testCfg(t *testing.T) *config.Config {
	t.Helper()
	dir := t.TempDir()
	return &config.Config{
		ProxyMode: ModeGateway,
		LanCIDR:   "192.168.68.0/24",
		Paths:     config.Paths{Etc: dir},
	}
}

func TestSwitchApplyConfirm(t *testing.T) {
	cfg := testCfg(t)
	var applied []map[string]any
	c := NewController(cfg, func(body map[string]any) (map[string]any, error) {
		applied = append(applied, body)
		return map[string]any{"ok": true}, nil
	}, func() string { return cfg.LanCIDR })

	st, err := c.Apply(SwitchRequest{
		Mode:              ModeBypass,
		CustomerHosts:     []string{"10.20.30.10", "10.20.30.0/24"},
		WAN:               WANConfig{Mode: "static", Address: "10.20.30.2", Netmask: "255.255.255.0", Gateway: "10.20.30.1"},
		ConfirmTimeoutSec: 120,
	})
	if err != nil {
		t.Fatal(err)
	}
	if st.Pending == nil || st.Pending.ToMode != ModeBypass {
		t.Fatalf("pending=%+v", st.Pending)
	}
	if _, err := os.Stat(filepath.Join(cfg.Paths.Etc, fileCustomerHosts)); err != nil {
		t.Fatal(err)
	}
	if len(applied) != 1 {
		t.Fatalf("applied=%d", len(applied))
	}

	st, err = c.Confirm(st.Pending.Token)
	if err != nil {
		t.Fatal(err)
	}
	if st.Pending != nil {
		t.Fatalf("pending still set: %+v", st.Pending)
	}
	if CommittedMode(cfg) != ModeBypass {
		t.Fatalf("committed=%s", CommittedMode(cfg))
	}
	if NormalizeMode(cfg.ProxyMode) != ModeGateway {
		t.Fatalf("dataplane env stays gateway in unit test without ModeApply, got %s", cfg.ProxyMode)
	}
}

func TestSwitchApplyCallsDataplane(t *testing.T) {
	cfg := testCfg(t)
	var modes []string
	c := NewController(cfg, func(body map[string]any) (map[string]any, error) {
		return map[string]any{"ok": true}, nil
	}, func() string { return cfg.LanCIDR })
	c.SetDataplaneApply(func(mode string) error {
		modes = append(modes, mode)
		cfg.ProxyMode = mode
		return nil
	})
	st, err := c.Apply(SwitchRequest{
		Mode:              ModeBypass,
		CustomerHosts:     []string{"10.20.30.10"},
		WAN:               WANConfig{Mode: "static", Address: "10.20.30.2", Netmask: "255.255.255.0", Gateway: "10.20.30.1"},
		ConfirmTimeoutSec: 120,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(modes) != 1 || modes[0] != ModeBypass {
		t.Fatalf("modes=%v", modes)
	}
	if _, err := c.Confirm(st.Pending.Token); err != nil {
		t.Fatal(err)
	}
	if cfg.ProxyMode != ModeBypass {
		t.Fatalf("proxy mode=%s", cfg.ProxyMode)
	}
	if len(modes) != 2 || modes[0] != ModeBypass || modes[1] != ModeBypass {
		t.Fatalf("confirm must reapply dataplane, modes=%v", modes)
	}
}

func TestSwitchTransparentApply(t *testing.T) {
	cfg := testCfg(t)
	var modes []string
	c := NewController(cfg, nil, func() string { return cfg.LanCIDR })
	c.SetDataplaneApply(func(mode string) error {
		modes = append(modes, mode)
		cfg.ProxyMode = mode
		return nil
	})
	st, err := c.Apply(SwitchRequest{
		Mode:     ModeTransparent,
		IspPort:  "eth1",
		CpePort:  "eth2",
		LANIface: "br-lan",
	})
	if err != nil {
		t.Fatal(err)
	}
	if st.Pending == nil || st.Pending.ToMode != ModeTransparent {
		t.Fatalf("pending=%+v", st.Pending)
	}
	if len(modes) != 1 || modes[0] != ModeTransparent {
		t.Fatalf("modes=%v", modes)
	}
	ports := transparent.LoadPorts(cfg)
	if ports.ISP != "eth1" || ports.CPE != "eth2" {
		t.Fatalf("ports=%+v", ports)
	}
}

func TestSwitchRejectsEmptyHosts(t *testing.T) {
	cfg := testCfg(t)
	c := NewController(cfg, nil, nil)
	_, err := c.Apply(SwitchRequest{
		Mode: ModeBypass,
		WAN:  WANConfig{Mode: "static", Address: "10.20.30.2", Netmask: "255.255.255.0", Gateway: "10.20.30.1"},
	})
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestSwitchTimeoutRollback(t *testing.T) {
	cfg := testCfg(t)
	_ = writeJSON(wanPath(cfg), map[string]any{"mode": "dhcp", "interface": "eth1"})
	c := NewController(cfg, func(body map[string]any) (map[string]any, error) {
		return map[string]any{"ok": true}, nil
	}, func() string { return cfg.LanCIDR })

	now := time.Now().UTC()
	c.now = func() time.Time { return now }
	var fired func()
	c.after = func(d time.Duration, f func()) *time.Timer {
		fired = f
		return time.NewTimer(time.Hour)
	}

	st, err := c.Apply(SwitchRequest{
		Mode:              ModeBypass,
		CustomerHosts:     []string{"10.20.30.10"},
		WAN:               WANConfig{Mode: "static", Address: "10.20.30.2", Netmask: "255.255.255.0", Gateway: "10.20.30.1", Interface: "eth1"},
		ConfirmTimeoutSec: 30,
	})
	if err != nil {
		t.Fatal(err)
	}
	if st.Pending == nil {
		t.Fatal("expected pending")
	}
	if fired == nil {
		t.Fatal("timer not armed")
	}
	now = now.Add(2 * time.Minute)
	c.now = func() time.Time { return now }
	fired()

	pending, err := LoadPending(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if pending != nil {
		t.Fatalf("pending should be cleared: %+v", pending)
	}
	if CommittedMode(cfg) != ModeGateway {
		t.Fatalf("mode rolled back, got %s", CommittedMode(cfg))
	}
	wan := c.loadWANFile()
	if wan["mode"] != "dhcp" {
		t.Fatalf("wan rolled back, got %v", wan)
	}
}

func TestSwitchGatewayRestoresDHCPFromBypass(t *testing.T) {
	cfg := testCfg(t)
	if err := SaveCommitted(cfg, ModeBypass); err != nil {
		t.Fatal(err)
	}
	if err := writeJSON(wanPath(cfg), map[string]any{
		"enabled": true, "interface": "eth0", "mode": "static",
		"address": "192.168.88.194", "netmask": "255.255.255.0", "gateway": "192.168.88.1", "mtu": 1500,
	}); err != nil {
		t.Fatal(err)
	}
	var applied []map[string]any
	c := NewController(cfg, func(body map[string]any) (map[string]any, error) {
		applied = append(applied, cloneMap(body))
		return map[string]any{"ok": true}, nil
	}, func() string { return cfg.LanCIDR })
	c.SetDataplaneApply(func(mode string) error {
		cfg.ProxyMode = mode
		return nil
	})

	st, err := c.Apply(SwitchRequest{Mode: ModeGateway, ConfirmTimeoutSec: 120})
	if err != nil {
		t.Fatal(err)
	}
	if st.Pending == nil || st.Pending.ToMode != ModeGateway {
		t.Fatalf("pending=%+v", st.Pending)
	}
	if len(applied) != 1 {
		t.Fatalf("applied=%d", len(applied))
	}
	if applied[0]["mode"] != "dhcp" {
		t.Fatalf("wan mode=%v", applied[0]["mode"])
	}
	if addr, _ := applied[0]["address"].(string); addr != "" {
		t.Fatalf("address leftover %q", addr)
	}
	wan := c.loadWANFile()
	if wan["mode"] != "dhcp" {
		t.Fatalf("json mode=%v", wan["mode"])
	}
	if wan["interface"] != "eth0" {
		t.Fatalf("interface=%v", wan["interface"])
	}
}

func TestSwitchGatewayCleansLeftoverStatic(t *testing.T) {
	cfg := testCfg(t)
	if err := writeJSON(wanPath(cfg), map[string]any{
		"mode": "static", "interface": "eth0",
		"address": "192.168.88.194", "netmask": "255.255.255.0", "gateway": "192.168.88.1",
	}); err != nil {
		t.Fatal(err)
	}
	var applied []map[string]any
	c := NewController(cfg, func(body map[string]any) (map[string]any, error) {
		applied = append(applied, cloneMap(body))
		return map[string]any{"ok": true}, nil
	}, func() string { return cfg.LanCIDR })

	if _, err := c.Apply(SwitchRequest{Mode: ModeGateway}); err != nil {
		t.Fatal(err)
	}
	if len(applied) != 1 || applied[0]["mode"] != "dhcp" {
		t.Fatalf("applied=%v", applied)
	}
}

func TestSwitchGatewayKeepsDHCPWithoutReapply(t *testing.T) {
	cfg := testCfg(t)
	if err := writeJSON(wanPath(cfg), map[string]any{"mode": "dhcp", "interface": "eth0"}); err != nil {
		t.Fatal(err)
	}
	var applied int
	c := NewController(cfg, func(body map[string]any) (map[string]any, error) {
		applied++
		return map[string]any{"ok": true}, nil
	}, func() string { return cfg.LanCIDR })
	on := true
	if _, err := c.Apply(SwitchRequest{Mode: ModeGateway, DNSHijack: &on}); err != nil {
		t.Fatal(err)
	}
	if applied != 0 {
		t.Fatalf("WAN should not reapply when already gateway+dhcp, got %d", applied)
	}
}

func TestSwitchTransparentToGatewayReappliesDHCP(t *testing.T) {
	cfg := testCfg(t)
	if err := SaveCommitted(cfg, ModeTransparent); err != nil {
		t.Fatal(err)
	}
	if err := writeJSON(wanPath(cfg), map[string]any{"mode": "dhcp", "interface": "eth0"}); err != nil {
		t.Fatal(err)
	}
	var applied []map[string]any
	c := NewController(cfg, func(body map[string]any) (map[string]any, error) {
		applied = append(applied, cloneMap(body))
		return map[string]any{"ok": true}, nil
	}, func() string { return cfg.LanCIDR })

	if _, err := c.Apply(SwitchRequest{Mode: ModeGateway}); err != nil {
		t.Fatal(err)
	}
	if len(applied) != 0 {
		t.Fatalf("leaving transparent defers live WAN apply until leave-trans, applied=%v", applied)
	}
	wan := c.loadWANFile()
	if wan["mode"] != "dhcp" {
		t.Fatalf("json mode=%v", wan["mode"])
	}
}
