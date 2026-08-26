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
	"time"
)

const (
	DomainMapFile     = "domain-map.json"
	UnboundDNSAddr    = "127.0.0.1:53"
	resolveTimeout    = 4 * time.Second
	ResolveViaUnbound = "unbound:53"
)

// DomainMap is the authoritative apply-time snapshot: customer FQDN list → IPs
// obtained by querying local unbound (same CN/intl split as LAN clients).
type DomainMap struct {
	Resolver  string                     `json:"resolver"` // unbound:53
	UpdatedAt string                     `json:"updated_at"`
	Groups    map[string]DomainGroupMap  `json:"groups"`
}

type DomainGroupMap struct {
	GroupID   string                       `json:"group_id"`
	GroupName string                       `json:"group_name"`
	SetName   string                       `json:"usr_dom_set"`
	Domains   map[string]DomainResolveEntry `json:"domains"`
	IPs       []string                     `json:"ips"` // union of all domain A records for nft set
}

type DomainResolveEntry struct {
	IPs    []string `json:"ips"`
	Error  string   `json:"error,omitempty"`
	Source string   `json:"source"` // unbound:53
}

func (s *Service) domainMapPath() string {
	return filepath.Join(s.cfg.Paths.Etc, DirName, DomainMapFile)
}

func (s *Service) LoadDomainMap() DomainMap {
	data, err := os.ReadFile(s.domainMapPath())
	if err != nil {
		return DomainMap{Resolver: ResolveViaUnbound, Groups: map[string]DomainGroupMap{}}
	}
	var m DomainMap
	if json.Unmarshal(data, &m) != nil {
		return DomainMap{Resolver: ResolveViaUnbound, Groups: map[string]DomainGroupMap{}}
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
	if err := os.MkdirAll(filepath.Dir(s.domainMapPath()), 0o755); err != nil {
		return err
	}
	m.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	m.Resolver = ResolveViaUnbound
	raw, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.domainMapPath() + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.domainMapPath())
}

// buildDomainMap resolves every domain-group member via local unbound and
// returns per-group IP unions for usr_dom_* sync.
func buildDomainMap(groups []Group) (DomainMap, map[string][]string, error) {
	out := DomainMap{
		Resolver: ResolveViaUnbound,
		Groups:   map[string]DomainGroupMap{},
	}
	resolved := map[string][]string{}
	for _, g := range groups {
		if g.Kind != KindDomain {
			continue
		}
		entry := DomainGroupMap{
			GroupID:   g.ID,
			GroupName: g.Name,
			SetName:   setNameFor(g),
			Domains:   map[string]DomainResolveEntry{},
		}
		ipSeen := map[string]struct{}{}
		var ips []string
		for _, dom := range g.Members {
			dom = strings.TrimSpace(strings.TrimSuffix(strings.ToLower(dom), "."))
			if dom == "" {
				continue
			}
			got, err := resolveViaUnbound(dom)
			de := DomainResolveEntry{Source: ResolveViaUnbound, IPs: got}
			if err != nil {
				de.Error = err.Error()
			}
			entry.Domains[dom] = de
			for _, ip := range got {
				if _, ok := ipSeen[ip]; ok {
					continue
				}
				ipSeen[ip] = struct{}{}
				ips = append(ips, ip)
			}
		}
		sort.Strings(ips)
		entry.IPs = ips
		out.Groups[g.ID] = entry
		resolved[g.ID] = ips
	}
	return out, resolved, nil
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
