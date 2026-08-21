package proxymode

import (
	"testing"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func TestSwitchRequestFromBodyIsInAPI(t *testing.T) {
	// compile-time sanity: config paths used by store helpers
	cfg := &config.Config{Paths: config.Paths{Etc: t.TempDir()}, ProxyMode: ModeGateway, LanCIDR: "192.168.68.0/24"}
	if CommittedMode(cfg) != ModeGateway {
		t.Fatal(CommittedMode(cfg))
	}
}
