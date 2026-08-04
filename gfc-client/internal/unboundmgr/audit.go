package unboundmgr

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// Hit describes one place a domain appears.
type Hit struct {
	Source string `json:"source"` // block|static|domestic-forward|cn
	Domain string `json:"domain"` // matched zone name
	Match  string `json:"match"`  // exact|parent|child
	Detail string `json:"detail,omitempty"`
	Level  string `json:"level"` // deny|warn|info
}

// AuditResult is the conflict report for a proposed snippet write or a lookup.
type AuditResult struct {
	Query   string `json:"query,omitempty"`
	Hits    []Hit  `json:"hits"`
	Denied  bool   `json:"denied"`
	Summary string `json:"summary"`
}

type cnIndex struct {
	mu    sync.Mutex
	mtime time.Time
	size  int64
	set   map[string]struct{}
}

var globalCN = &cnIndex{}

func (m *Manager) loadOperatorEntries(kind string) ([]Entry, error) {
	listPath := m.listPath(kind)
	if data, err := os.ReadFile(listPath); err == nil {
		entries, perr := ParseDSL(kind, string(data))
		if perr != nil {
			return nil, perr
		}
		if len(entries) > 0 {
			return entries, nil
		}
		// empty .list → fall through (migrate from legacy conf)
	}
	conf, err := m.GetSnippetConf(kind)
	if err != nil {
		return nil, err
	}
	return ExtractEntriesFromConf(kind, conf), nil
}

func (m *Manager) Lookup(query string) (AuditResult, error) {
	dom, err := normalizeDomain(query)
	if err != nil {
		return AuditResult{}, err
	}
	var hits []Hit
	for _, kind := range []string{SnippetBlock, SnippetStatic, SnippetDomesticForward} {
		entries, err := m.loadOperatorEntries(kind)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if rel := domainRelation(dom, e.Domain); rel != "" {
				detail := e.Domain
				if kind == SnippetStatic {
					detail = e.Domain + " -> " + e.IP
				}
				if kind == SnippetDomesticForward {
					detail = e.Domain + " -> " + strings.Join(e.Upstreams, ",")
				}
				hits = append(hits, Hit{
					Source: kind,
					Domain: e.Domain,
					Match:  rel,
					Detail: detail,
					Level:  "info",
				})
			}
		}
	}
	if cn, err := m.cnContains(dom); err == nil {
		hits = append(hits, cn...)
	}
	sum := "未找到匹配"
	if len(hits) > 0 {
		sum = fmtHitsSummary(hits)
	}
	return AuditResult{Query: dom, Hits: hits, Summary: sum}, nil
}

// AuditWrite checks proposed entries for kind against other operator lists and CN.
func (m *Manager) AuditWrite(kind string, entries []Entry) AuditResult {
	var hits []Hit
	denied := false
	otherEntries := map[string][]Entry{}
	for _, k := range []string{SnippetBlock, SnippetStatic, SnippetDomesticForward} {
		if k == kind {
			continue
		}
		ents, err := m.loadOperatorEntries(k)
		if err != nil {
			continue
		}
		otherEntries[k] = ents
	}
	for _, e := range entries {
		for okind, oents := range otherEntries {
			for _, o := range oents {
				rel := domainRelation(e.Domain, o.Domain)
				if rel == "" {
					continue
				}
				level := "warn"
				if rel == "exact" {
					level = "deny"
					denied = true
				}
				hits = append(hits, Hit{
					Source: okind,
					Domain: o.Domain,
					Match:  rel,
					Detail: fmt.Sprintf("%s:%s conflicts with %s:%s", kind, e.Domain, okind, o.Domain),
					Level:  level,
				})
			}
		}
		if cnHits, err := m.cnContains(e.Domain); err == nil {
			for _, h := range cnHits {
				if kind == SnippetBlock || kind == SnippetStatic {
					h.Level = "warn"
					h.Detail = "将被 local-zone 权威覆盖 CN 转发"
				} else {
					h.Level = "info"
					h.Detail = "与 CN 列表重复（可保留作显式覆盖）"
				}
				hits = append(hits, h)
			}
		}
	}
	sum := "无冲突"
	if len(hits) > 0 {
		sum = fmtHitsSummary(hits)
	}
	return AuditResult{Hits: hits, Denied: denied, Summary: sum}
}

func fmtHitsSummary(hits []Hit) string {
	var deny, warn, info int
	for _, h := range hits {
		switch h.Level {
		case "deny":
			deny++
		case "warn":
			warn++
		default:
			info++
		}
	}
	parts := make([]string, 0, 3)
	if deny > 0 {
		parts = append(parts, fmt.Sprintf("deny=%d", deny))
	}
	if warn > 0 {
		parts = append(parts, fmt.Sprintf("warn=%d", warn))
	}
	if info > 0 {
		parts = append(parts, fmt.Sprintf("info=%d", info))
	}
	return strings.Join(parts, " ")
}

// domainRelation returns exact|parent|child|"" relative to query vs candidate zone.
// parent = candidate is parent zone of query (query is under candidate)
// child  = candidate is under query
func domainRelation(query, candidate string) string {
	if query == candidate {
		return "exact"
	}
	if strings.HasSuffix(query, "."+candidate) {
		return "parent"
	}
	if strings.HasSuffix(candidate, "."+query) {
		return "child"
	}
	return ""
}

func (m *Manager) cnContains(domain string) ([]Hit, error) {
	set, err := m.cnSet()
	if err != nil {
		return nil, err
	}
	var hits []Hit
	if _, ok := set[domain]; ok {
		hits = append(hits, Hit{Source: "cn", Domain: domain, Match: "exact", Level: "info"})
	}
	parts := strings.Split(domain, ".")
	for i := 1; i < len(parts); i++ {
		parent := strings.Join(parts[i:], ".")
		if parent == "" {
			continue
		}
		if _, ok := set[parent]; ok {
			hits = append(hits, Hit{Source: "cn", Domain: parent, Match: "parent", Level: "info"})
		}
	}
	return hits, nil
}

func (m *Manager) cnSet() (map[string]struct{}, error) {
	path := m.paths()["cn"]
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	globalCN.mu.Lock()
	defer globalCN.mu.Unlock()
	if globalCN.set != nil && globalCN.mtime.Equal(st.ModTime()) && globalCN.size == st.Size() {
		return globalCN.set, nil
	}
	set, err := buildCNIndex(path)
	if err != nil {
		return nil, err
	}
	globalCN.set = set
	globalCN.mtime = st.ModTime()
	globalCN.size = st.Size()
	return set, nil
}

func buildCNIndex(path string) (map[string]struct{}, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	set := make(map[string]struct{}, 65536)
	sc := bufio.NewScanner(f)
	buf := make([]byte, 0, 64*1024)
	sc.Buffer(buf, 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, "name:") {
			continue
		}
		rest := strings.TrimSpace(strings.TrimPrefix(line, "name:"))
		rest = strings.Trim(rest, "\"'")
		dom, err := normalizeDomain(rest)
		if err != nil || dom == "." {
			continue
		}
		set[dom] = struct{}{}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return set, nil
}

func (m *Manager) InvalidateCNIndex() {
	globalCN.mu.Lock()
	defer globalCN.mu.Unlock()
	globalCN.set = nil
}
