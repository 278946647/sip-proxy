package policyrouting

import (
	"strings"
	"testing"
)

func TestBuildOverlayChainNFTOrderAndSafety(t *testing.T) {
	groups := []Group{
		{ID: "g1", Name: "src", Kind: KindSrcCIDR, Members: []string{"192.168.68.10"}},
		{ID: "g2", Name: "dst", Kind: KindDstCIDR, Members: []string{"1.2.3.4"}},
	}
	policies := []Policy{
		{ID: "ovr_hi", Name: "hi", Enabled: true, Rank: 0, Action: ActionDirect, MatchSrcGroupID: "g1", MatchDstGroupID: "g2"},
		{ID: "ovr_lo", Name: "lo", Enabled: true, Rank: 1, Action: ActionProxy, MatchSrcGroupID: "g1"},
	}
	text, err := buildOverlayChainNFT(groups, policies, Env{ProxyMode: "gateway", Mark: "0x2023"}, "br-lan", "eth0", "0x00002023")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, "ip daddr @bypass_ip return") {
		t.Fatal("missing overlay safety bypass_ip")
	}
	if !strings.Contains(text, "usr_src_g1") || !strings.Contains(text, "usr_dst_g2") {
		t.Fatalf("missing usr_* refs:\n%s", text)
	}
	hi := strings.Index(text, "Override#ovr_hi")
	lo := strings.Index(text, "Override#ovr_lo")
	if hi < 0 || lo < 0 || hi > lo {
		t.Fatalf("override order wrong hi=%d lo=%d\n%s", hi, lo, text)
	}
	if strings.Contains(text, "iifname \"eth0\"") {
		t.Fatal("gateway mode must not emit WAN overlay rules")
	}
	if !strings.Contains(text, "ct mark set 0x00002023 meta mark set ct mark accept") {
		t.Fatal("proxy action must reuse 0x2023")
	}
}

func TestBuildOverlayChainNFTBypassWAN(t *testing.T) {
	groups := []Group{{ID: "g1", Name: "src", Kind: KindSrcCIDR, Members: []string{"10.20.30.10"}}}
	policies := []Policy{{
		ID: "ovr_1", Name: "src-only", Enabled: true, Rank: 0, Action: ActionProxy,
		MatchSrcGroupID: "g1",
	}}
	text, err := buildOverlayChainNFT(groups, policies, Env{ProxyMode: "bypass"}, "br-lan", "eth0", "0x00002023")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(text, `iifname "eth0" ip saddr @customer_hosts ip saddr @usr_src_g1`) {
		t.Fatalf("missing WAN+customer overlay:\n%s", text)
	}
}

func TestSanitizeSetID(t *testing.T) {
	if sanitizeSetID("g-ab/c") != "g_ab_c" {
		t.Fatalf("got %s", sanitizeSetID("g-ab/c"))
	}
}

func TestBuildReloadShell(t *testing.T) {
	sh := buildReloadShell([]Group{{
		ID: "g1", Kind: KindSrcCIDR, Members: []string{"10.0.0.1"},
	}}, nil, "/etc/gfc-client/policy-routing/user-overlay.nft")
	if !strings.Contains(sh, "usr_src_g1") || !strings.Contains(sh, "nft -f") {
		t.Fatalf("sh=%s", sh)
	}
}
