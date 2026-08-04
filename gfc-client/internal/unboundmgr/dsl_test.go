package unboundmgr

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func TestParseAndGenerateBlock(t *testing.T) {
	entries, err := ParseDSL(SnippetBlock, "# comment\nip.sb\nADS.Example.com.\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("got %d entries", len(entries))
	}
	conf, err := GenerateConf(SnippetBlock, entries)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(conf, `local-zone: "ip.sb." static`) {
		t.Fatalf("missing zone:\n%s", conf)
	}
	if !strings.Contains(conf, `local-data: "ip.sb. 3600 IN A 0.0.0.0"`) {
		t.Fatalf("missing sinkhole:\n%s", conf)
	}
	if strings.Contains(conf, "forward-zone") {
		t.Fatal("block must not emit forward-zone")
	}
}

func TestParseAndGenerateStatic(t *testing.T) {
	entries, err := ParseDSL(SnippetStatic, "mmo.example.com 203.0.113.10\n")
	if err != nil {
		t.Fatal(err)
	}
	conf, err := GenerateConf(SnippetStatic, entries)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(conf, `local-data: "mmo.example.com. 3600 IN A 203.0.113.10"`) {
		t.Fatalf("bad static:\n%s", conf)
	}
}

func TestParseAndGenerateDomestic(t *testing.T) {
	entries, err := ParseDSL(SnippetDomesticForward, "special.example.com 223.5.5.5 119.29.29.29\n")
	if err != nil {
		t.Fatal(err)
	}
	conf, err := GenerateConf(SnippetDomesticForward, entries)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(conf, "server:") {
		t.Fatal("domestic-forward must not wrap in server:")
	}
	if !strings.Contains(conf, "forward-zone:") || !strings.Contains(conf, `name: "special.example.com"`) {
		t.Fatalf("bad forward:\n%s", conf)
	}
}

func TestDomainRelation(t *testing.T) {
	if domainRelation("a.b.com", "a.b.com") != "exact" {
		t.Fatal("exact")
	}
	if domainRelation("a.b.com", "b.com") != "parent" {
		t.Fatal("parent")
	}
	if domainRelation("b.com", "a.b.com") != "child" {
		t.Fatal("child")
	}
	if domainRelation("x.com", "y.com") != "" {
		t.Fatal("none")
	}
}

func TestPutSnippetConflictAndPersist(t *testing.T) {
	root := t.TempDir()
	cfg := &config.Config{}
	cfg.Paths.Root = root
	cfg.Paths.Lib = filepath.Join(root, "lib")
	cfg.Paths.UnboundConfig = filepath.Join(root, "etc", "unbound", "unbound.conf")
	cfg.Paths.UnboundConfD = filepath.Join(root, "etc", "unbound", "conf.d")
	_ = os.MkdirAll(cfg.Paths.UnboundConfD, 0o755)
	_ = os.MkdirAll(filepath.Join(root, "etc", "unbound", "local.d"), 0o755)
	_ = os.WriteFile(cfg.Paths.UnboundConfig, []byte("server:\n    interface: 127.0.0.1\n"), 0o644)
	_ = os.WriteFile(filepath.Join(cfg.Paths.UnboundConfD, "cn.unbound.conf"), []byte("# empty cn\n"), 0o644)
	os.Setenv("GFC_SKIP_UNBOUND_CHECK", "1")
	t.Cleanup(func() { os.Unsetenv("GFC_SKIP_UNBOUND_CHECK") })

	m := New(cfg)
	if err := m.EnsureTree(); err != nil {
		t.Fatal(err)
	}
	if _, err := m.PutSnippet(SnippetBlock, "ip.sb\n", false); err != nil {
		t.Fatalf("block put: %v", err)
	}
	conf, err := m.GetSnippetConf(SnippetBlock)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(conf, `local-zone: "ip.sb." static`) {
		t.Fatalf("conf not generated:\n%s", conf)
	}
	_, err = m.PutSnippet(SnippetStatic, "ip.sb 1.2.3.4\n", false)
	if err == nil {
		t.Fatal("expected conflict deny")
	}
	audit := m.AuditWrite(SnippetStatic, []Entry{{Domain: "ip.sb", IP: "1.2.3.4"}})
	if !audit.Denied {
		t.Fatalf("expected denied audit: %+v", audit)
	}
	look, err := m.Lookup("ip.sb")
	if err != nil {
		t.Fatal(err)
	}
	if len(look.Hits) == 0 {
		t.Fatal("lookup should find block")
	}
}

func TestCopyIfMissingSemanticsViaExtract(t *testing.T) {
	raw := `server:
    local-zone: "ads.example.com." static
    local-data: "ads.example.com. 3600 IN A 0.0.0.0"
`
	ents := ExtractEntriesFromConf(SnippetBlock, raw)
	if len(ents) != 1 || ents[0].Domain != "ads.example.com" {
		t.Fatalf("extract=%+v", ents)
	}
}
