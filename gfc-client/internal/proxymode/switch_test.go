package proxymode

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
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
