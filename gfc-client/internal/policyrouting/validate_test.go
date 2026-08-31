package policyrouting

import (
	"path/filepath"
	"testing"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func TestNormalizeMembers(t *testing.T) {
	got, err := normalizeMembers(KindSrcCIDR, []string{"10.0.0.1\n10.0.1.0/24", "10.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != "10.0.0.1" || got[1] != "10.0.1.0/24" {
		t.Fatalf("got=%v", got)
	}
	if _, err := normalizeMembers(KindDomain, []string{"Example.COM."}); err != nil {
		t.Fatal(err)
	}
	gotW, err := normalizeMembers(KindDomain, []string{"*.LinkedIn.com"})
	if err != nil {
		t.Fatal(err)
	}
	if len(gotW) != 1 || gotW[0] != "*.linkedin.com" {
		t.Fatalf("wildcard got=%v", gotW)
	}
	if _, err := normalizeMembers(KindDomain, []string{"*"}); err == nil {
		t.Fatal("expected wildcard reject")
	}
	if _, err := normalizeMembers(KindDomain, []string{"*.com"}); err == nil {
		t.Fatal("expected *.com reject")
	}
	if _, err := normalizeMembers(KindDomain, []string{"foo.*.com"}); err == nil {
		t.Fatal("expected mid-star reject")
	}
}

func TestQnameMatchesMemberOneLevel(t *testing.T) {
	if !qnameMatchesMember("platform.linkedin.com", "*.linkedin.com") {
		t.Fatal("one-level should match")
	}
	if qnameMatchesMember("linkedin.com", "*.linkedin.com") {
		t.Fatal("apex must not match wildcard")
	}
	if qnameMatchesMember("a.b.linkedin.com", "*.linkedin.com") {
		t.Fatal("two-level must not match")
	}
	if qnameMatchesMember("platform.linkedin.com", "linkedin.com") {
		t.Fatal("exact must not suffix-match")
	}
	if !qnameMatchesMember("linkedin.com", "linkedin.com") {
		t.Fatal("exact equality")
	}
	if !domainMatches("www.linkedin.com", []string{"linkedin.com", "*.linkedin.com"}) {
		t.Fatal("group with both members should match www")
	}
	if domainMatches("linkedin.com", []string{"*.linkedin.com"}) {
		t.Fatal("apex vs wildcard-only group")
	}
}

func TestValidateRejectEmptyMatch(t *testing.T) {
	groups := []Group{{ID: "g1", Name: "src", Kind: KindSrcCIDR, Members: []string{"10.0.0.1"}}}
	_, err := NormalizeAndValidatePolicies([]Policy{{
		Name: "bad", Action: ActionProxy, Enabled: true,
	}}, groups, nil)
	if err == nil {
		t.Fatal("expected empty match reject")
	}
}

func TestValidateSrcOnlyNeedsDangerAck(t *testing.T) {
	groups := []Group{{ID: "g1", Name: "src", Kind: KindSrcCIDR, Members: []string{"10.0.0.1"}}}
	_, err := NormalizeAndValidatePolicies([]Policy{{
		Name: "force", Enabled: true, Action: ActionProxy, MatchSrcGroupID: "g1",
	}}, groups, nil)
	if err == nil {
		t.Fatal("expected danger_ack")
	}
	out, err := NormalizeAndValidatePolicies([]Policy{{
		Name: "force", Enabled: true, Action: ActionProxy, MatchSrcGroupID: "g1", DangerAck: true,
	}}, groups, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !out[0].DangerAck || out[0].Rank != 0 {
		t.Fatalf("out=%+v", out[0])
	}
}

func TestValidateDstDomainMutex(t *testing.T) {
	groups := []Group{
		{ID: "s", Name: "src", Kind: KindSrcCIDR, Members: []string{"10.0.0.1"}},
		{ID: "d", Name: "dst", Kind: KindDstCIDR, Members: []string{"1.1.1.1"}},
		{ID: "dom", Name: "dom", Kind: KindDomain, Members: []string{"example.com"}},
	}
	_, err := NormalizeAndValidatePolicies([]Policy{{
		Name: "x", Enabled: true, Action: ActionDirect,
		MatchSrcGroupID: "s", MatchDstGroupID: "d", MatchDomainGroupID: "dom", DangerAck: true,
	}}, groups, nil)
	if err == nil {
		t.Fatal("expected mutex")
	}
}

func TestProbeWildcardOneLevel(t *testing.T) {
	groups := []Group{{ID: "dom", Name: "li", Kind: KindDomain, Members: []string{"*.linkedin.com"}}}
	policies := []Policy{{
		ID: "ovr_1", Name: "li-direct", Enabled: true, Rank: 0, Action: ActionDirect,
		MatchDomainGroupID: "dom", DangerAck: true,
	}}
	res, err := Probe(ProbeRequest{ProbeDomain: "platform.linkedin.com"}, groups, policies, DefaultEnv(), Snapshot{})
	if err != nil {
		t.Fatal(err)
	}
	if res.WinnerID != "ovr_1" || res.Action != ActionDirect {
		t.Fatalf("child should hit wildcard: %+v", res)
	}
	res, err = Probe(ProbeRequest{ProbeDomain: "linkedin.com"}, groups, policies, DefaultEnv(), Snapshot{})
	if err != nil {
		t.Fatal(err)
	}
	if res.WinnerLayer != LayerSystem {
		t.Fatalf("apex must not hit *.linkedin.com: %+v", res)
	}
	res, err = Probe(ProbeRequest{ProbeDomain: "a.b.linkedin.com"}, groups, policies, DefaultEnv(), Snapshot{})
	if err != nil {
		t.Fatal(err)
	}
	if res.WinnerLayer != LayerSystem {
		t.Fatalf("two-level must not hit: %+v", res)
	}
}

func TestProbeExactNotSuffix(t *testing.T) {
	groups := []Group{{ID: "dom", Name: "li", Kind: KindDomain, Members: []string{"linkedin.com"}}}
	policies := []Policy{{
		ID: "ovr_1", Name: "apex", Enabled: true, Rank: 0, Action: ActionDirect,
		MatchDomainGroupID: "dom", DangerAck: true,
	}}
	res, err := Probe(ProbeRequest{ProbeDomain: "platform.linkedin.com"}, groups, policies, DefaultEnv(), Snapshot{})
	if err != nil {
		t.Fatal(err)
	}
	if res.WinnerLayer != LayerSystem {
		t.Fatalf("exact must not suffix-match: %+v", res)
	}
}

func TestProbeSafetyRailWins(t *testing.T) {
	groups := []Group{{ID: "s", Name: "src", Kind: KindSrcCIDR, Members: []string{"192.168.68.10"}}}
	policies := []Policy{{
		ID: "ovr_1", Name: "proxy-all", Enabled: true, Rank: 0, Action: ActionProxy,
		MatchSrcGroupID: "s", DangerAck: true,
	}}
	res, err := Probe(ProbeRequest{ProbeSrc: "192.168.68.10", ProbeDst: "8.8.8.8"}, groups, policies, Env{
		ProxyMode: "gateway", LANCIDR: "192.168.68.0/24", Mark: "0x2023", Table: "2022", Tun: "gfctun",
	}, Snapshot{BypassIP: []string{"8.8.8.8"}})
	if err != nil {
		t.Fatal(err)
	}
	if res.WinnerLayer != LayerSafety || res.Action != ActionDirect {
		t.Fatalf("res=%+v", res)
	}
}

func TestProbeUserOverrideOrder(t *testing.T) {
	groups := []Group{
		{ID: "s", Name: "src", Kind: KindSrcCIDR, Members: []string{"10.0.0.2"}},
		{ID: "d", Name: "dst", Kind: KindDstCIDR, Members: []string{"1.2.3.4"}},
	}
	policies := []Policy{
		{ID: "ovr_hi", Name: "hi", Enabled: true, Rank: 0, Action: ActionDirect, MatchSrcGroupID: "s", MatchDstGroupID: "d", DangerAck: true},
		{ID: "ovr_lo", Name: "lo", Enabled: true, Rank: 1, Action: ActionProxy, MatchSrcGroupID: "s", MatchDstGroupID: "d", DangerAck: true},
	}
	res, err := Probe(ProbeRequest{ProbeSrc: "10.0.0.2", ProbeDst: "1.2.3.4"}, groups, policies, DefaultEnv(), Snapshot{})
	if err != nil {
		t.Fatal(err)
	}
	if res.WinnerID != "ovr_hi" || res.Action != ActionDirect {
		t.Fatalf("res=%+v", res)
	}
}

func TestProbeBypassIngress(t *testing.T) {
	res, err := Probe(ProbeRequest{ProbeDst: "1.1.1.1", ProbeSrc: "10.20.30.9"}, nil, nil, Env{
		ProxyMode: "bypass", CustomerHosts: []string{"10.20.30.10"}, LANCIDR: "192.168.68.0/24",
	}, Snapshot{ExtConst: []string{"1.1.1.1"}})
	if err != nil {
		t.Fatal(err)
	}
	if res.IngressEligible {
		t.Fatalf("expected ineligible: %+v", res)
	}
	res, err = Probe(ProbeRequest{ProbeDst: "1.1.1.1", ProbeSrc: "10.20.30.10"}, nil, nil, Env{
		ProxyMode: "bypass", CustomerHosts: []string{"10.20.30.10"},
	}, Snapshot{ExtConst: []string{"1.1.1.1"}})
	if err != nil {
		t.Fatal(err)
	}
	if !res.IngressEligible || res.Action != ActionProxy {
		t.Fatalf("res=%+v", res)
	}
}

func TestStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	cfg := &config.Config{Paths: config.Paths{Etc: dir}}
	svc := NewService(cfg, func() Env {
		return Env{ProxyMode: "gateway", LANCIDR: "192.168.68.0/24", Mark: "0x2023", Table: "2022", Tun: "gfctun"}
	})
	groups, err := svc.PutGroups([]Group{{
		Name: "office", Kind: KindSrcCIDR, Members: []string{"192.168.68.50"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 || groups[0].ID == "" {
		t.Fatalf("groups=%+v", groups)
	}
	pols, err := svc.PutPolicies([]Policy{{
		Name: "force-proxy", Enabled: true, Action: ActionProxy,
		MatchSrcGroupID: groups[0].ID, DangerAck: true,
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(pols) != 1 || pols[0].ID == "" {
		t.Fatalf("pols=%+v", pols)
	}
	path := filepath.Join(dir, DirName, GroupsFile)
	if path == "" {
		t.Fatal("path")
	}
	got, err := svc.GetGroups()
	if err != nil || got[0].RefCount != 1 {
		t.Fatalf("ref=%+v err=%v", got, err)
	}
	apply, err := svc.Apply(ApplyInput{})
	if err != nil {
		t.Fatal(err)
	}
	if apply.DataplaneApplied {
		t.Log("dataplane applied (nft available)")
	}
	if apply.Groups[0].RefCount != 1 {
		t.Fatalf("ref after apply=%+v", apply.Groups)
	}
}
