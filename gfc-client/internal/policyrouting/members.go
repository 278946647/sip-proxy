package policyrouting

import (
	"fmt"
	"net"
	"strings"
	"unicode"
)

func normalizeMembers(kind string, raw []string) ([]string, error) {
	seen := map[string]struct{}{}
	var out []string
	for _, item := range raw {
		for _, token := range splitTokens(item) {
			var val string
			var err error
			switch kind {
			case KindSrcCIDR, KindDstCIDR:
				val, err = normalizeIPOrCIDR(token)
			case KindDomain:
				val, err = normalizeFQDN(token)
			default:
				return nil, fmt.Errorf("未知组类型 %q", kind)
			}
			if err != nil {
				return nil, err
			}
			if _, ok := seen[val]; ok {
				continue
			}
			seen[val] = struct{}{}
			out = append(out, val)
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("组成员不能为空")
	}
	return out, nil
}

func splitTokens(raw string) []string {
	raw = strings.ReplaceAll(raw, ",", " ")
	raw = strings.ReplaceAll(raw, ";", " ")
	raw = strings.ReplaceAll(raw, "\r", "\n")
	raw = strings.ReplaceAll(raw, "\n", " ")
	return strings.Fields(raw)
}

func normalizeIPOrCIDR(token string) (string, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return "", fmt.Errorf("空地址")
	}
	if strings.Contains(token, "/") {
		ip, n, err := net.ParseCIDR(token)
		if err != nil {
			return "", fmt.Errorf("无效网段 %q", token)
		}
		if ip.To4() == nil {
			return "", fmt.Errorf("仅支持 IPv4: %s", token)
		}
		ones, bits := n.Mask.Size()
		if bits != 32 {
			return "", fmt.Errorf("仅支持 IPv4: %s", token)
		}
		return fmt.Sprintf("%s/%d", n.IP.Mask(n.Mask).String(), ones), nil
	}
	ip := net.ParseIP(token)
	if ip == nil || ip.To4() == nil {
		return "", fmt.Errorf("无效地址 %q（仅 IPv4 或 CIDR）", token)
	}
	return ip.To4().String(), nil
}

func canonDomain(token string) string {
	return strings.TrimSpace(strings.ToLower(strings.TrimSuffix(token, ".")))
}

func isWildcardMember(token string) bool {
	return strings.HasPrefix(canonDomain(token), "*.")
}

func wildcardSuffix(member string) string {
	m := canonDomain(member)
	if !strings.HasPrefix(m, "*.") {
		return ""
	}
	return strings.TrimPrefix(m, "*.")
}

func normalizeExactFQDN(token string) (string, error) {
	token = canonDomain(token)
	if token == "" {
		return "", fmt.Errorf("空域名")
	}
	if strings.Contains(token, "*") {
		return "", fmt.Errorf("无效通配符写法: %s", token)
	}
	if ip := net.ParseIP(token); ip != nil {
		return "", fmt.Errorf("域名组成员必须是 FQDN，不是 IP: %s", token)
	}
	if !strings.Contains(token, ".") {
		return "", fmt.Errorf("域名必须是 FQDN: %s", token)
	}
	if len(token) > 253 {
		return "", fmt.Errorf("域名过长: %s", token)
	}
	for _, label := range strings.Split(token, ".") {
		if label == "" || len(label) > 63 {
			return "", fmt.Errorf("无效域名标签: %s", token)
		}
		if label[0] == '-' || label[len(label)-1] == '-' {
			return "", fmt.Errorf("无效域名标签: %s", token)
		}
		for _, r := range label {
			if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' {
				continue
			}
			return "", fmt.Errorf("无效域名字符: %s", token)
		}
	}
	return token, nil
}

func normalizeFQDN(token string) (string, error) {
	token = canonDomain(token)
	if token == "" {
		return "", fmt.Errorf("空域名")
	}
	if strings.HasPrefix(token, "*.") {
		rest, err := normalizeExactFQDN(strings.TrimPrefix(token, "*."))
		if err != nil {
			return "", fmt.Errorf("无效通配符: %s", token)
		}
		if strings.Count(rest, ".") < 1 {
			return "", fmt.Errorf("通配符后须为完整域名（至少两个标签）: %s", token)
		}
		return "*." + rest, nil
	}
	if strings.Contains(token, "*") {
		return "", fmt.Errorf("通配符仅允许最左一层 *.example.com: %s", token)
	}
	return normalizeExactFQDN(token)
}

func normalizeProbeQName(token string) (string, error) {
	token = canonDomain(token)
	if token == "" {
		return "", fmt.Errorf("空域名")
	}
	if strings.Contains(token, "*") {
		return "", fmt.Errorf("试算请填实际访问的域名，不要填通配符")
	}
	return normalizeExactFQDN(token)
}

// qnameMatchesMember: exact member = equality only; *.example.com = exactly one label.
func qnameMatchesMember(qname, member string) bool {
	qname = canonDomain(qname)
	member = canonDomain(member)
	if qname == "" || member == "" {
		return false
	}
	if isWildcardMember(member) {
		suffix := wildcardSuffix(member)
		if suffix == "" || qname == suffix {
			return false // apex excluded
		}
		if !strings.HasSuffix(qname, "."+suffix) {
			return false
		}
		prefix := strings.TrimSuffix(qname, "."+suffix)
		return prefix != "" && !strings.Contains(prefix, ".")
	}
	return qname == member
}

func matchingPattern(qname string, members []string) string {
	for _, m := range members {
		if qnameMatchesMember(qname, m) {
			return canonDomain(m)
		}
	}
	return ""
}

func membersMayMatchSameQName(a, b string) bool {
	a, b = canonDomain(a), canonDomain(b)
	if a == "" || b == "" {
		return false
	}
	if a == b {
		return true
	}
	if isWildcardMember(a) && !isWildcardMember(b) {
		return qnameMatchesMember(b, a)
	}
	if isWildcardMember(b) && !isWildcardMember(a) {
		return qnameMatchesMember(a, b)
	}
	return false
}

func parseIPv4(raw string) net.IP {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	if strings.Contains(raw, "/") {
		ip, _, err := net.ParseCIDR(raw)
		if err != nil {
			return nil
		}
		return ip.To4()
	}
	ip := net.ParseIP(raw)
	if ip == nil {
		return nil
	}
	return ip.To4()
}

func hostToNet(raw string) (*net.IPNet, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, fmt.Errorf("空地址")
	}
	if strings.Contains(raw, "/") {
		_, n, err := net.ParseCIDR(raw)
		if err != nil {
			return nil, err
		}
		if n.IP.To4() == nil {
			return nil, fmt.Errorf("仅支持 IPv4: %s", raw)
		}
		return n, nil
	}
	ip := net.ParseIP(raw)
	if ip == nil || ip.To4() == nil {
		return nil, fmt.Errorf("无效地址 %q", raw)
	}
	return &net.IPNet{IP: ip.To4(), Mask: net.CIDRMask(32, 32)}, nil
}

func ipInList(ip net.IP, cidrs []string) bool {
	if ip == nil {
		return false
	}
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	for _, c := range cidrs {
		n, err := hostToNet(c)
		if err != nil || n == nil {
			continue
		}
		if n.Contains(ip4) {
			return true
		}
	}
	return false
}

func listsIntersect(a, b []string) bool {
	for _, x := range a {
		ip := parseIPv4(x)
		if ip != nil && ipInList(ip, b) {
			return true
		}
		n, err := hostToNet(x)
		if err != nil {
			continue
		}
		for _, y := range b {
			yn, err := hostToNet(y)
			if err != nil {
				continue
			}
			if cidrsOverlap(n, yn) {
				return true
			}
		}
	}
	return false
}

func cidrsOverlap(a, b *net.IPNet) bool {
	if a == nil || b == nil {
		return false
	}
	return a.Contains(b.IP) || b.Contains(a.IP)
}

func domainMatches(probe string, members []string) bool {
	return matchingPattern(probe, members) != ""
}

func nftSetName(kind, id string) string {
	switch kind {
	case KindSrcCIDR:
		return SetPrefixSrc + id
	case KindDstCIDR:
		return SetPrefixDst + id
	case KindDomain:
		return SetPrefixDom + id
	default:
		return ""
	}
}
