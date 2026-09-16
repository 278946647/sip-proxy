package proxymode

import (
	"testing"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func TestSwitchRequestFromBodyIsInAPI(t *testing.T) {
	// compile-time sanity: config paths used by store helpers
	cfg := &config.Config{Paths: config.Paths{Etc: t.TempDir()}, ProxyMode: ModeGateway, LanCIDR: "192.168.68.0/24"}
	if CommittedMode(cfg) != ModeGateway {
		t.Fatal(CommittedMode(cfg))
	}
}

func TestLiveModeEnvWins(t *testing.T) {
	cfg := &config.Config{Paths: config.Paths{Etc: t.TempDir()}, ProxyMode: ModeGateway}
	t.Setenv("GFC_PROXY_MODE", "transparent")
	if LiveMode(cfg) != ModeTransparent {
		t.Fatalf("got %s", LiveMode(cfg))
	}
}

func TestLiveModeCommittedWinsOverStaleEnv(t *testing.T) {
	cfg := &config.Config{Paths: config.Paths{Etc: t.TempDir()}, ProxyMode: ModeGateway}
	if err := SaveCommitted(cfg, ModeTransparent); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GFC_PROXY_MODE", "gateway")
	if got := LiveMode(cfg); got != ModeTransparent {
		t.Fatalf("got %s", got)
	}
}

func TestLiveModePendingWinsOverCommitted(t *testing.T) {
	cfg := &config.Config{Paths: config.Paths{Etc: t.TempDir()}, ProxyMode: ModeGateway}
	if err := SaveCommitted(cfg, ModeGateway); err != nil {
		t.Fatal(err)
	}
	p := &PendingSwitch{
		Token:     "tok",
		FromMode:  ModeGateway,
		ToMode:    ModeTransparent,
		ExpiresAt: time.Now().UTC().Add(time.Hour).Format(time.RFC3339),
	}
	if err := SavePending(cfg, p); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GFC_PROXY_MODE", "gateway")
	if got := LiveMode(cfg); got != ModeTransparent {
		t.Fatalf("got %s", got)
	}
}
