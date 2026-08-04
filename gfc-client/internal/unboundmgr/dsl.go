package unboundmgr

import (
	"fmt"
	"net"
	"strings"
)

// Entry is one operator intent line after DSL parse.
type Entry struct {
	Domain    string   // normalized FQDN without trailing dot for display
	IP        string   // static A record
	Upstreams []string // domestic forward-addr list
}

func normalizeDomain(raw string) (string, error) {
	s := strings.TrimSpace(strings.ToLower(raw))
	s = strings.TrimSuffix(s, ".")
	if s == "" || s == "." {
		return "", fmt.Errorf("empty domain")
	}
	if strings.ContainsAny(s, " \t") {
		return "", fmt.Errorf("invalid domain %q", raw)
	}
	if strings.Contains(s, "..") {
		return "", fmt.Errorf("invalid domain %q", raw)
	}
	for _, c := range s {
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' {
			continue
		}
		return "", fmt.Errorf("invalid domain %q", raw)
	}
	return s, nil
}

func fqdn(domain string) string {
	return domain + "."
}

func parseIPv4(raw string) (string, error) {
	ip := net.ParseIP(strings.TrimSpace(raw))
	if ip == nil || ip.To4() == nil {
		return "", fmt.Errorf("invalid IPv4 %q", raw)
	}
	return ip.To4().String(), nil
}

// ParseDSL parses operator-facing lines into entries.
//
//	block:    domain
//	static:   domain IPv4
//	domestic: domain upstream [upstream...]
func ParseDSL(kind, content string) ([]Entry, error) {
	var out []Entry
	seen := map[string]bool{}
	lines := strings.Split(content, "\n")
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		dom, err := normalizeDomain(fields[0])
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", i+1, err)
		}
		if seen[dom] {
			return nil, fmt.Errorf("line %d: duplicate domain %s", i+1, dom)
		}
		seen[dom] = true
		e := Entry{Domain: dom}
		switch kind {
		case SnippetBlock:
			if len(fields) != 1 {
				return nil, fmt.Errorf("line %d: block expects \"domain\" only", i+1)
			}
		case SnippetStatic:
			if len(fields) != 2 {
				return nil, fmt.Errorf("line %d: static expects \"domain IPv4\"", i+1)
			}
			ip, err := parseIPv4(fields[1])
			if err != nil {
				return nil, fmt.Errorf("line %d: %w", i+1, err)
			}
			e.IP = ip
		case SnippetDomesticForward:
			if len(fields) < 2 {
				return nil, fmt.Errorf("line %d: domestic-forward expects \"domain upstream [upstream...]\"", i+1)
			}
			for _, u := range fields[1:] {
				ip, err := parseIPv4(u)
				if err != nil {
					return nil, fmt.Errorf("line %d: %w", i+1, err)
				}
				e.Upstreams = append(e.Upstreams, ip)
			}
		default:
			return nil, fmt.Errorf("unknown snippet kind %q", kind)
		}
		out = append(out, e)
	}
	return out, nil
}

// FormatDSL renders entries back to operator DSL (stable, comment-free body).
func FormatDSL(kind string, entries []Entry) string {
	var b strings.Builder
	b.WriteString(dslHeader(kind))
	for _, e := range entries {
		switch kind {
		case SnippetBlock:
			b.WriteString(e.Domain)
			b.WriteByte('\n')
		case SnippetStatic:
			b.WriteString(e.Domain)
			b.WriteByte(' ')
			b.WriteString(e.IP)
			b.WriteByte('\n')
		case SnippetDomesticForward:
			b.WriteString(e.Domain)
			for _, u := range e.Upstreams {
				b.WriteByte(' ')
				b.WriteString(u)
			}
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func dslHeader(kind string) string {
	switch kind {
	case SnippetBlock:
		return `# 格式：每行一个域名
# 例：ads.example.com
`
	case SnippetStatic:
		return `# 格式：域名 IPv4
# 例：mmo.example.com 203.0.113.10
`
	case SnippetDomesticForward:
		return `# 格式：域名 上游DNS [上游DNS...]
# 例：special.example.com 223.5.5.5 119.29.29.29
`
	default:
		return "# GFC DNS snippet\n"
	}
}

// GenerateConf builds unbound include content from entries.
// block/static wrap in server:; domestic-forward emits top-level forward-zone blocks.
func GenerateConf(kind string, entries []Entry) (string, error) {
	var b strings.Builder
	switch kind {
	case SnippetBlock:
		b.WriteString("# Generated from gfc-block.list — do not hand-edit; edit via LuCI DSL\n")
		b.WriteString("server:\n")
		if len(entries) == 0 {
			b.WriteString("    # (empty)\n")
			return b.String(), nil
		}
		for _, e := range entries {
			name := fqdn(e.Domain)
			b.WriteString(fmt.Sprintf("    local-zone: %q static\n", name))
			b.WriteString(fmt.Sprintf("    local-data: \"%s 3600 IN A 0.0.0.0\"\n", name))
		}
	case SnippetStatic:
		b.WriteString("# Generated from gfc-static.list — do not hand-edit; edit via LuCI DSL\n")
		b.WriteString("server:\n")
		if len(entries) == 0 {
			b.WriteString("    # (empty)\n")
			return b.String(), nil
		}
		for _, e := range entries {
			name := fqdn(e.Domain)
			b.WriteString(fmt.Sprintf("    local-zone: %q static\n", name))
			b.WriteString(fmt.Sprintf("    local-data: \"%s 3600 IN A %s\"\n", name, e.IP))
		}
	case SnippetDomesticForward:
		b.WriteString("# Generated from gfc-domestic-forward.list — do not hand-edit; edit via LuCI DSL\n")
		b.WriteString("# forward-zone MUST stay outside server: (UNBOUND_ARCHITECTURE)\n")
		if len(entries) == 0 {
			b.WriteString("# (empty)\n")
			return b.String(), nil
		}
		for _, e := range entries {
			b.WriteString("forward-zone:\n")
			b.WriteString(fmt.Sprintf("    name: %q\n", e.Domain))
			for _, u := range e.Upstreams {
				b.WriteString(fmt.Sprintf("    forward-addr: %s\n", u))
			}
			b.WriteByte('\n')
		}
	default:
		return "", fmt.Errorf("unknown snippet kind %q", kind)
	}
	return b.String(), nil
}

// ExtractEntriesFromConf best-effort reverse parse of existing unbound snippet conf.
func ExtractEntriesFromConf(kind, conf string) []Entry {
	switch kind {
	case SnippetBlock, SnippetStatic:
		return extractLocalEntries(kind, conf)
	case SnippetDomesticForward:
		return extractForwardEntries(conf)
	default:
		return nil
	}
}

func extractLocalEntries(kind, conf string) []Entry {
	var out []Entry
	zones := map[string]bool{}
	dataA := map[string]string{}
	for _, line := range strings.Split(conf, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") || line == "" {
			continue
		}
		if strings.HasPrefix(line, "local-zone:") {
			rest := strings.TrimSpace(strings.TrimPrefix(line, "local-zone:"))
			q := strings.Index(rest, "\"")
			if q < 0 {
				continue
			}
			rest = rest[q+1:]
			q2 := strings.Index(rest, "\"")
			if q2 < 0 {
				continue
			}
			dom, err := normalizeDomain(rest[:q2])
			if err != nil {
				continue
			}
			zones[dom] = true
			continue
		}
		if strings.HasPrefix(line, "local-data:") {
			q := strings.Index(line, "\"")
			if q < 0 {
				continue
			}
			inner := line[q+1:]
			if i := strings.Index(inner, "\""); i >= 0 {
				inner = inner[:i]
			}
			fields := strings.Fields(inner)
			if len(fields) < 5 || !strings.EqualFold(fields[3], "A") {
				continue
			}
			dom, err := normalizeDomain(fields[0])
			if err != nil {
				continue
			}
			dataA[dom] = fields[4]
		}
	}
	for dom := range zones {
		e := Entry{Domain: dom}
		if kind == SnippetStatic {
			ip := dataA[dom]
			if ip == "" || ip == "0.0.0.0" {
				continue
			}
			e.IP = ip
		} else if kind == SnippetBlock {
			if ip, ok := dataA[dom]; ok && ip != "0.0.0.0" {
				continue
			}
		}
		out = append(out, e)
	}
	return sortEntries(out)
}

func extractForwardEntries(conf string) []Entry {
	var out []Entry
	var cur *Entry
	flush := func() {
		if cur != nil && cur.Domain != "" && len(cur.Upstreams) > 0 {
			out = append(out, *cur)
		}
		cur = nil
	}
	for _, line := range strings.Split(conf, "\n") {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		if trim == "forward-zone:" || strings.HasPrefix(trim, "forward-zone:") {
			flush()
			cur = &Entry{}
			continue
		}
		if cur == nil {
			continue
		}
		if strings.HasPrefix(trim, "name:") {
			rest := strings.TrimSpace(strings.TrimPrefix(trim, "name:"))
			rest = strings.Trim(rest, "\"'")
			if dom, err := normalizeDomain(rest); err == nil {
				cur.Domain = dom
			}
			continue
		}
		if strings.HasPrefix(trim, "forward-addr:") {
			rest := strings.TrimSpace(strings.TrimPrefix(trim, "forward-addr:"))
			// strip DoT suffix host if any: 1.1.1.1@853#...
			if i := strings.IndexAny(rest, "@#"); i >= 0 {
				rest = rest[:i]
			}
			if ip, err := parseIPv4(rest); err == nil {
				cur.Upstreams = append(cur.Upstreams, ip)
			}
		}
	}
	flush()
	return sortEntries(out)
}
