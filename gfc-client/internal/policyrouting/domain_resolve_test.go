package policyrouting

import (
	"path/filepath"
	"testing"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func TestDomainMapPersist(t *testing.T) {
	dir := t.TempDir()
	svc := NewService(&config.Config{Paths: config.Paths{Etc: dir}}, DefaultEnv)
	m := DomainMap{
		Resolver: ResolveViaUnbound,
		Groups: map[string]DomainGroupMap{
			"g1": {
				GroupID: "g1", GroupName: "intl", SetName: "usr_dom_g1",
				Domains: map[string]DomainResolveEntry{
					"example.com": {IPs: []string{"93.184.216.34"}, Source: ResolveViaUnbound},
				},
				IPs: []string{"93.184.216.34"},
			},
		},
	}
	if err := svc.saveDomainMap(m); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, DirName, DomainMapFile)
	if path == "" {
		t.Fatal("empty")
	}
	got := svc.LoadDomainMap()
	if got.Resolver != ResolveViaUnbound {
		t.Fatalf("resolver=%s", got.Resolver)
	}
	g := got.Groups["g1"]
	if len(g.IPs) != 1 || g.Domains["example.com"].IPs[0] != "93.184.216.34" {
		t.Fatalf("got=%+v", g)
	}
}

func TestBuildDomainMapEmptyMembers(t *testing.T) {
	// No live unbound required: empty domain list yields empty map entry.
	m, resolved, err := buildDomainMap([]Group{{
		ID: "g1", Name: "empty", Kind: KindDomain, Members: nil,
	}})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := m.Groups["g1"]; !ok {
		t.Fatal("missing group")
	}
	if len(resolved["g1"]) != 0 {
		t.Fatalf("resolved=%v", resolved["g1"])
	}
}
