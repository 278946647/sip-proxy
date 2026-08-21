package proxymode

import (
	"fmt"
	"net"
	"sort"
	"strings"
)

// NormalizeHosts parses IPv4 addresses or CIDRs from mixed separators.
func NormalizeHosts(raw []string) ([]string, error) {
	seen := map[string]struct{}{}
	var out []string
	for _, item := range raw {
		for _, token := range splitHostTokens(item) {
			host, err := normalizeHostToken(token)
			if err != nil {
				return nil, err
			}
			if _, ok := seen[host]; ok {
				continue
			}
			seen[host] = struct{}{}
			out = append(out, host)
		}
	}
	sort.Strings(out)
	return out, nil
}

func ParseHostsText(text string) ([]string, error) {
	return NormalizeHosts([]string{text})
}

func splitHostTokens(raw string) []string {
	raw = strings.ReplaceAll(raw, ",", " ")
	raw = strings.ReplaceAll(raw, ";", " ")
	raw = strings.ReplaceAll(raw, "\r", "\n")
	raw = strings.ReplaceAll(raw, "\n", " ")
	parts := strings.Fields(raw)
	return parts
}

func normalizeHostToken(token string) (string, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return "", fmt.Errorf("empty customer host")
	}
	if strings.Contains(token, "/") {
		ip, n, err := net.ParseCIDR(token)
		if err != nil {
			return "", fmt.Errorf("无效网段 %q: %w", token, err)
		}
		if ip.To4() == nil {
			return "", fmt.Errorf("customer_hosts 仅支持 IPv4: %s", token)
		}
		ones, bits := n.Mask.Size()
		if bits != 32 {
			return "", fmt.Errorf("customer_hosts 仅支持 IPv4: %s", token)
		}
		return fmt.Sprintf("%s/%d", n.IP.Mask(n.Mask).String(), ones), nil
	}
	ip := net.ParseIP(token)
	if ip == nil || ip.To4() == nil {
		return "", fmt.Errorf("无效地址 %q（仅 IPv4 或 CIDR）", token)
	}
	return ip.To4().String(), nil
}

func hostsOverlapLAN(hosts []string, lan *net.IPNet) error {
	if lan == nil {
		return nil
	}
	for _, host := range hosts {
		n, err := hostToNet(host)
		if err != nil {
			return err
		}
		if cidrsOverlap(n, lan) {
			return fmt.Errorf("customer_hosts %s 与管理 LAN %s 冲突", host, lan.String())
		}
	}
	return nil
}

func hostToNet(host string) (*net.IPNet, error) {
	if strings.Contains(host, "/") {
		_, n, err := net.ParseCIDR(host)
		return n, err
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() == nil {
		return nil, fmt.Errorf("无效地址 %s", host)
	}
	return &net.IPNet{IP: ip.To4(), Mask: net.CIDRMask(32, 32)}, nil
}
