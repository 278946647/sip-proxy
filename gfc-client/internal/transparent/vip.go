package transparent

import (
	"fmt"
	"net"
	"strings"
)

// ResolveVIP picks a DNS VIP in the reserved pools that does not overlap
// management LAN, learned CE/GW, WAN IPs, or customer_hosts.
func ResolveVIP(want string, lanCIDR string, learned Learned, wanIPs, customerHosts []string) (string, error) {
	want = strings.TrimSpace(want)
	if want == "" {
		want = DefaultVIP
	}
	blocked := conflictNets(lanCIDR, learned, wanIPs, customerHosts)
	if ip := net.ParseIP(want); ip != nil && ip.To4() != nil {
		if !ipConflicts(ip.To4(), blocked) && ip.To4().String() != HitchBindIP {
			return ip.To4().String(), nil
		}
	}
	for _, pool := range []string{VIPPoolPrimary, VIPPoolBackup} {
		if vip, ok := firstFreeInPool(pool, blocked); ok {
			return vip, nil
		}
	}
	return "", fmt.Errorf("DNS VIP 保留池已耗尽（与 LAN/CE/GW/WAN/customer_hosts 冲突）")
}

func conflictNets(lanCIDR string, learned Learned, wanIPs, hosts []string) []*net.IPNet {
	var out []*net.IPNet
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" {
			return
		}
		if n := parseIPv4Net(s); n != nil {
			out = append(out, n)
		}
	}
	add(lanCIDR)
	add(learned.CEIP)
	add(learned.GWIP)
	add(HitchBindIP)
	for _, w := range wanIPs {
		add(w)
	}
	for _, h := range hosts {
		add(h)
	}
	return out
}

func firstFreeInPool(cidr string, blocked []*net.IPNet) (string, bool) {
	_, n, err := net.ParseCIDR(cidr)
	if err != nil {
		return "", false
	}
	ones, bits := n.Mask.Size()
	if bits != 32 || ones > 30 {
		return "", false
	}
	start := n.IP.To4()
	if start == nil {
		return "", false
	}
	// skip network (.0), hitch .1 in primary, broadcast
	max := 1 << uint(32-ones)
	for i := 1; i < max-1; i++ {
		ip := make(net.IP, 4)
		copy(ip, start)
		v := uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
		v += uint32(i)
		cand := net.IPv4(byte(v>>24), byte(v>>16), byte(v>>8), byte(v)).To4()
		if cand.String() == HitchBindIP {
			continue
		}
		if ipConflicts(cand, blocked) {
			continue
		}
		return cand.String(), true
	}
	return "", false
}

func ipConflicts(ip net.IP, nets []*net.IPNet) bool {
	for _, n := range nets {
		if n != nil && n.Contains(ip) {
			return true
		}
	}
	return false
}

func parseIPv4Net(s string) *net.IPNet {
	if strings.Contains(s, "/") {
		_, n, err := net.ParseCIDR(s)
		if err != nil || n.IP.To4() == nil {
			return nil
		}
		return n
	}
	ip := net.ParseIP(s)
	if ip == nil || ip.To4() == nil {
		return nil
	}
	return &net.IPNet{IP: ip.To4(), Mask: net.CIDRMask(32, 32)}
}
