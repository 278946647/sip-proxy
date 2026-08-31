package policyrouting

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	DomainMapFile     = "domain-map.json"
	UnboundDNSAddr    = "127.0.0.1:53"
	resolveTimeout    = 4 * time.Second
	ResolveViaUnbound = "unbound:53"
	ResolveViaSnoop   = "dns-snoop"
	ResolveWildcard   = "wildcard"
	minSnoopTTL       = 60 * time.Second
	maxSnoopTTL       = time.Hour
)

var domainMapFileMu sync.Mutex

// DomainMap is FQDN → IPs: exact names via unbound:53; wildcards via UDP/53 snoop.
type DomainMap struct {
	Resolver  string                    `json:"resolver"` // unbound:53
	Snoop     string                    `json:"snoop,omitempty"`
	UpdatedAt string                    `json:"updated_at"`
	Groups    map[string]DomainGroupMap `json:"groups"`
}

type DomainGroupMap struct {
	GroupID   string                        `json:"group_id"`
	GroupName string                        `json:"group_name"`
	SetName   string                        `json:"usr_dom_set"`
	Domains   map[string]DomainResolveEntry `json:"domains"`
	Learned   []LearnedDomain               `json:"learned,omitempty"`
	IPs       []string                      `json:"ips"` // union for nft set
}

type DomainResolveEntry struct {
	IPs    []string `json:"ips"`
	Error  string   `json:"error,omitempty"`
	Source string   `json:"source"` // unbound:53 | wildcard
}

type LearnedDomain struct {
	QName     string   `json:"qname"`
	Pattern   string   `json:"pattern"`
	IPs       []string `json:"ips"`
	ExpiresAt string   `json:"expires_at"`
	Source    string   `json:"source"`
}

func (s *Service) domainMapPath() string {
	return filepath.Join(s.cfg.Paths.Etc, DirName, DomainMapFile)
}

func (s *Service) LoadDomainMap() DomainMap {
	return loadDomainMapFile(s.domainMapPath())
}

func loadDomainMapFile(path string) DomainMap {
	domainMapFileMu.Lock()
	defer domainMapFileMu.Unlock()
	return loadDomainMapFileLocked(path)
}

func loadDomainMapFileLocked(path string) DomainMap {
	empty := DomainMap{Resolver: ResolveViaUnbound, Groups: map[string]DomainGroupMap{}}
	data, err := os.ReadFile(path)
	if err != nil {
		return empty
	}
	var m DomainMap
	if json.Unmarshal(data, &m) != nil {
		return empty
	}
	if m.Groups == nil {
		m.Groups = map[string]DomainGroupMap{}
	}
	if m.Resolver == "" {
		m.Resolver = ResolveViaUnbound
	}
	return m
}

func (s *Service) saveDomainMap(m DomainMap) error {
	domainMapFileMu.Lock()
	defer domainMapFileMu.Unlock()
	return saveDomainMapFileLocked(s.domainMapPath(), m)
}

func saveDomainMapFileLocked(path string, m DomainMap) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	m.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	m.Resolver = ResolveViaUnbound
	if m.Snoop == "" {
		m.Snoop = "udp/53"
	}
	raw, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func unionIPs(ipSeen map[string]struct{}, ips []string, add []string) []string {
	for _, ip := range add {
		if _, ok := ipSeen[ip]; ok {
			continue
		}
		ipSeen[ip] = struct{}{}
		ips = append(ips, ip)
	}
	return ips
}

func keepLearned(g Group, prev DomainGroupMap, now time.Time) []LearnedDomain {
	var out []LearnedDomain
	for _, L := range prev.Learned {
		if L.ExpiresAt != "" {
			t, err := time.Parse(time.RFC3339, L.ExpiresAt)
			if err == nil && !t.After(now) {
				continue
			}
		}
		pat := matchingPattern(L.QName, g.Members)
		if pat == "" {
			continue
		}
		L.Pattern = pat
		if L.Source == "" {
			L.Source = ResolveViaSnoop
		}
		out = append(out, L)
	}
	return out
}

// buildDomainMap resolves exact FQDNs via unbound and merges unexpired snoop-learned IPs.
func buildDomainMap(groups []Group, prev DomainMap) (DomainMap, map[string][]string, error) {
	out := DomainMap{
		Resolver: ResolveViaUnbound,
		Snoop:    "udp/53",
		Groups:   map[string]DomainGroupMap{},
	}
	resolved := map[string][]string{}
	now := time.Now().UTC()
	for _, g := range groups {
		if g.Kind != KindDomain {
			continue
		}
		prevG := DomainGroupMap{}
		if prev.Groups != nil {
			prevG = prev.Groups[g.ID]
		}
		entry := DomainGroupMap{
			GroupID:   g.ID,
			GroupName: g.Name,
			SetName:   setNameFor(g),
			Domains:   map[string]DomainResolveEntry{},
			Learned:   keepLearned(g, prevG, now),
		}
		ipSeen := map[string]struct{}{}
		var ips []string
		for _, dom := range g.Members {
			dom = canonDomain(dom)
			if dom == "" {
				continue
			}
			if isWildcardMember(dom) {
				entry.Domains[dom] = DomainResolveEntry{Source: ResolveWildcard}
				continue
			}
			got, err := resolveViaUnbound(dom)
			de := DomainResolveEntry{Source: ResolveViaUnbound, IPs: got}
			if err != nil {
				de.Error = err.Error()
			}
			entry.Domains[dom] = de
			ips = unionIPs(ipSeen, ips, got)
		}
		for _, L := range entry.Learned {
			ips = unionIPs(ipSeen, ips, L.IPs)
		}
		sort.Strings(ips)
		entry.IPs = ips
		out.Groups[g.ID] = entry
		resolved[g.ID] = ips
	}
	return out, resolved, nil
}

func clampSnoopTTL(d time.Duration) time.Duration {
	if d < minSnoopTTL {
		return minSnoopTTL
	}
	if d > maxSnoopTTL {
		return maxSnoopTTL
	}
	return d
}

func recordSnoopHit(etc, groupID, setName, qname, pattern string, ips []string, ttl time.Duration) {
	if etc == "" || groupID == "" || setName == "" || len(ips) == 0 {
		return
	}
	ttl = clampSnoopTTL(ttl)
	path := filepath.Join(etc, DirName, DomainMapFile)
	domainMapFileMu.Lock()
	defer domainMapFileMu.Unlock()
	_ = addSetElementsTimeout(setName, ips, ttl)
	m := loadDomainMapFileLocked(path)
	g := m.Groups[groupID]
	if g.Domains == nil {
		g.Domains = map[string]DomainResolveEntry{}
	}
	g.GroupID = groupID
	g.SetName = setName
	expires := time.Now().UTC().Add(ttl).Format(time.RFC3339)
	replaced := false
	for i, L := range g.Learned {
		if canonDomain(L.QName) == qname {
			g.Learned[i] = LearnedDomain{QName: qname, Pattern: pattern, IPs: ips, ExpiresAt: expires, Source: ResolveViaSnoop}
			replaced = true
			break
		}
	}
	if !replaced {
		g.Learned = append(g.Learned, LearnedDomain{QName: qname, Pattern: pattern, IPs: ips, ExpiresAt: expires, Source: ResolveViaSnoop})
	}
	ipSeen := map[string]struct{}{}
	var union []string
	for _, de := range g.Domains {
		union = unionIPs(ipSeen, union, de.IPs)
	}
	for _, L := range g.Learned {
		union = unionIPs(ipSeen, union, L.IPs)
	}
	sort.Strings(union)
	g.IPs = union
	m.Groups[groupID] = g
	_ = saveDomainMapFileLocked(path, m)
}

// resolveViaUnbound asks 127.0.0.1:53 so CN/intl split matches LAN clients.
// Does not change unbound.conf; does not use the OS default recursive path.
func resolveViaUnbound(domain string) ([]string, error) {
	domain = strings.TrimSpace(strings.TrimSuffix(strings.ToLower(domain), "."))
	if domain == "" {
		return nil, fmt.Errorf("空域名")
	}
	ctx, cancel := context.WithTimeout(context.Background(), resolveTimeout)
	defer cancel()

	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			d := net.Dialer{Timeout: resolveTimeout}
			return d.DialContext(ctx, "udp", UnboundDNSAddr)
		},
	}
	ips, err := r.LookupIP(ctx, "ip4", domain)
	if err != nil {
		return nil, fmt.Errorf("unbound 解析 %s 失败: %w", domain, err)
	}
	seen := map[string]struct{}{}
	var out []string
	for _, ip := range ips {
		ip4 := ip.To4()
		if ip4 == nil {
			continue
		}
		s := ip4.String()
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	sort.Strings(out)
	return out, nil
}

// ResolveDomainForProbe resolves a single FQDN via unbound for conflict probe.
func ResolveDomainForProbe(domain string) ([]string, error) {
	return resolveViaUnbound(domain)
}
