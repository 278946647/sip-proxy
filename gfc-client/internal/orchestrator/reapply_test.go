package orchestrator

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func testOrchestrator(t *testing.T) *Orchestrator {
	t.Helper()
	dir := t.TempDir()
	cfg := &config.Config{
		Paths: config.Paths{
			Etc:            dir,
			Lib:            filepath.Join(dir, "lib"),
			ConfigBundle:   filepath.Join(dir, "lib", "state", "config_bundle.json"),
			SingboxConfig:  filepath.Join(dir, "sing-box.json"),
			DataplaneMode:  filepath.Join(dir, "dataplane-mode.json"),
			BackupsDir:     filepath.Join(dir, "lib", "backups"),
			UnboundConfig:  filepath.Join(dir, "unbound.conf"),
		},
	}
	if err := os.MkdirAll(filepath.Join(dir, "lib", "state"), 0o755); err != nil {
		t.Fatal(err)
	}
	return New(cfg)
}

func TestReapplyLocalKeepsLastGoodTunWhenBundleMissing(t *testing.T) {
	t.Setenv("GFC_SKIP_DATAPLANE_REPAIR", "1")
	o := testOrchestrator(t)
	tunJSON := `{"inbounds":[{"type":"tun","tag":"tun-in"}],"outbounds":[{"type":"direct","tag":"direct"}]}`
	if err := os.WriteFile(o.cfg.Paths.SingboxConfig, []byte(tunJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(o.cfg.Paths.DataplaneMode, []byte(`{"mode":"active","activated":true}`), 0o644); err != nil {
		t.Fatal(err)
	}
	ok, msg := o.ReapplyLocal(false)
	if !ok {
		t.Fatalf("expected keep last-good, got fail: %s", msg)
	}
	if !strings.Contains(msg, "kept last-good tun") {
		t.Fatalf("msg=%s", msg)
	}
	got, err := os.ReadFile(o.cfg.Paths.SingboxConfig)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != tunJSON {
		t.Fatalf("sing-box.json overwritten:\n%s", got)
	}
}

func TestReapplyLocalIdleWhenNoTun(t *testing.T) {
	o := testOrchestrator(t)
	idleJSON := `{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}`
	if err := os.WriteFile(o.cfg.Paths.SingboxConfig, []byte(idleJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(o.cfg.Paths.DataplaneMode, []byte(`{"mode":"idle","activated":false}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if o.hasLastGoodActiveTun() {
		t.Fatal("idle config must not count as last-good tun")
	}
}

func TestReloadDNSKeepsLastGoodWhenBundleMissing(t *testing.T) {
	o := testOrchestrator(t)
	tunJSON := `{"inbounds":[{"type":"tun","tag":"tun-in"}]}`
	if err := os.WriteFile(o.cfg.Paths.SingboxConfig, []byte(tunJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(o.cfg.Paths.DataplaneMode, []byte(`{"mode":"active"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	ok, msg := o.ReloadDNS()
	if !ok {
		t.Fatalf("expected keep last-good dns: %s", msg)
	}
	if !strings.Contains(msg, "kept last-good dns") {
		t.Fatalf("msg=%s", msg)
	}
}
