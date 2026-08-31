package policyrouting

import (
	"path/filepath"
	"testing"
	"time"

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
	}}, DomainMap{})
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

func TestBuildDomainMapMergesUnexpiredLearned(t *testing.T) {
	exp := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)
	prev := DomainMap{Groups: map[string]DomainGroupMap{
		"g1": {Learned: []LearnedDomain{{
			QName: "platform.linkedin.com", Pattern: "*.linkedin.com",
			IPs: []string{"1.2.3.4"}, ExpiresAt: exp, Source: ResolveViaSnoop,
		}}},
	}}
	m, resolved, err := buildDomainMap([]Group{{
		ID: "g1", Name: "li", Kind: KindDomain, Members: []string{"*.linkedin.com"},
	}}, prev)
	if err != nil {
		t.Fatal(err)
	}
	if m.Groups["g1"].Domains["*.linkedin.com"].Source != ResolveWildcard {
		t.Fatalf("wildcard source=%+v", m.Groups["g1"].Domains["*.linkedin.com"])
	}
	if len(resolved["g1"]) != 1 || resolved["g1"][0] != "1.2.3.4" {
		t.Fatalf("resolved=%v", resolved["g1"])
	}
	if len(m.Groups["g1"].Learned) != 1 {
		t.Fatalf("learned=%+v", m.Groups["g1"].Learned)
	}
}

func TestBuildDomainMapDropsExpiredOrUnmatchedLearned(t *testing.T) {
	past := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)
	prev := DomainMap{Groups: map[string]DomainGroupMap{
		"g1": {Learned: []LearnedDomain{
			{QName: "platform.linkedin.com", IPs: []string{"1.2.3.4"}, ExpiresAt: past},
			{QName: "static.licdn.com", IPs: []string{"5.6.7.8"}, ExpiresAt: time.Now().UTC().Add(time.Hour).Format(time.RFC3339)},
		}},
	}}
	_, resolved, err := buildDomainMap([]Group{{
		ID: "g1", Name: "li", Kind: KindDomain, Members: []string{"*.linkedin.com"},
	}}, prev)
	if err != nil {
		t.Fatal(err)
	}
	if len(resolved["g1"]) != 0 {
		t.Fatalf("resolved=%v", resolved["g1"])
	}
}
