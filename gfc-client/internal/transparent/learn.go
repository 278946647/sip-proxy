package transparent

import (
	"encoding/binary"
	"net"
	"strings"
	"time"
)

const (
	ethLen     = 14
	etherARP   = 0x0806
	etherIPv4  = 0x0800
	etherDot1Q = 0x8100
	etherIPv6  = 0x86dd
	etherPPPoEDisc = 0x8863
	etherPPPoESess = 0x8864
	arpOpRequest = 1
	arpOpReply   = 2
)

// Role is which cable port a frame arrived on.
type Role string

const (
	RoleISP Role = "isp"
	RoleCPE Role = "cpe"
)

// ApplyFrame updates learned state from one Ethernet frame. Passive only.
func ApplyFrame(role Role, frame []byte, st *Learned) {
	if st == nil || len(frame) < ethLen {
		return
	}
	if st.CECandidates == nil {
		st.CECandidates = map[string]int{}
	}
	et := binary.BigEndian.Uint16(frame[12:14])
	srcMAC := formatMAC(frame[6:12])
	payload := frame[ethLen:]
	switch et {
	case etherDot1Q, etherIPv6, etherPPPoEDisc, etherPPPoESess:
		return
	case etherARP:
		applyARP(role, srcMAC, payload, st)
	case etherIPv4:
		applyIPv4(role, srcMAC, payload, st)
	}
	if st.CEIP == "" && len(st.CECandidates) > 0 {
		st.CEIP = topCandidate(st.CECandidates, st.GWIP)
	}
	if !usableHitchIP(st.CEIP) {
		st.CEIP = topCandidate(st.CECandidates, st.GWIP)
	}
	if !onLinkGW(st.CEIP, st.GWIP) {
		st.GWIP = ""
	}
	recomputeState(st)
}

func applyARP(role Role, srcMAC string, payload []byte, st *Learned) {
	if len(payload) < 28 {
		return
	}
	htype := binary.BigEndian.Uint16(payload[0:2])
	ptype := binary.BigEndian.Uint16(payload[2:4])
	if htype != 1 || ptype != etherIPv4 {
		return
	}
	op := binary.BigEndian.Uint16(payload[6:8])
	spa := net.IP(payload[14:18]).To4()
	tpa := net.IP(payload[24:28]).To4()
	if spa == nil {
		return
	}
	spaStr := spa.String()
	switch role {
	case RoleCPE:
		st.CPEMAC = srcMAC
		st.LearnedCustomer = true
		if usableHitchIP(spaStr) && spaStr != st.GWIP {
			st.CECandidates[spaStr]++
			if op == arpOpRequest && tpa != nil && !tpa.IsUnspecified() && usableHitchIP(tpa.String()) {
				// Host ARPing the gateway — strongest CE signal.
				st.CECandidates[spaStr] += 5
			}
		}
		// GW is the on-link next hop the CE is ARPing, not transit IPv4.
		if op == arpOpRequest && tpa != nil && onLinkGW(st.CEIP, tpa.String()) {
			st.GWIP = tpa.String()
		}
	case RoleISP:
		st.PEMAC = srcMAC
		if onLinkGW(st.CEIP, spaStr) {
			st.GWIP = spaStr
		}
	}
}

func applyIPv4(role Role, srcMAC string, payload []byte, st *Learned) {
	if len(payload) < 20 {
		return
	}
	ihl := int(payload[0]&0x0f) * 4
	if ihl < 20 || len(payload) < ihl {
		return
	}
	src := net.IP(payload[12:16]).To4()
	if src == nil {
		return
	}
	srcStr := src.String()
	proto := payload[9]
	switch role {
	case RoleCPE:
		st.CPEMAC = srcMAC
		st.LearnedCustomer = true
		if usableHitchIP(srcStr) && srcStr != st.GWIP {
			st.CECandidates[srcStr]++
		}
		if proto == 17 {
			applyDHCP(payload[ihl:], st)
		}
	case RoleISP:
		st.PEMAC = srcMAC
		// IPv4 src on isp is transit (VPN/CDN). GW comes from ARP/DHCP only.
	}
}

func applyDHCP(udp []byte, st *Learned) {
	// UDP header 8 + BOOTP yiaddr at offset 16 of BOOTP = UDP payload[16:20]
	if len(udp) < 8+20 {
		return
	}
	sport := binary.BigEndian.Uint16(udp[0:2])
	dport := binary.BigEndian.Uint16(udp[2:4])
	if sport != 67 && dport != 67 && sport != 68 && dport != 68 {
		return
	}
	bootp := udp[8:]
	if len(bootp) < 240 {
		return
	}
	yiaddr := net.IP(bootp[16:20]).To4()
	if yiaddr != nil && usableHitchIP(yiaddr.String()) {
		st.CECandidates[yiaddr.String()] += 8
	}
	// options after magic cookie 236+4
	opts := bootp[240:]
	gw := dhcpOptionIP(opts, 3)
	if gw != "" && onLinkGW(st.CEIP, gw) && (st.GWIP == "" || !onLinkGW(st.CEIP, st.GWIP)) {
		st.GWIP = gw
	}
}

func dhcpOptionIP(opts []byte, code byte) string {
	i := 0
	for i < len(opts) {
		c := opts[i]
		if c == 255 {
			return ""
		}
		if c == 0 {
			i++
			continue
		}
		if i+1 >= len(opts) {
			return ""
		}
		n := int(opts[i+1])
		if i+2+n > len(opts) {
			return ""
		}
		if c == code && n >= 4 {
			ip := net.IP(opts[i+2 : i+6]).To4()
			if ip != nil && !ip.IsUnspecified() {
				return ip.String()
			}
		}
		i += 2 + n
	}
	return ""
}

func recomputeState(st *Learned) {
	hasCPE := st.CPEMAC != "" || st.CEIP != ""
	hasISP := st.PEMAC != "" || st.GWIP != ""
	switch {
	case hasCPE && hasISP:
		st.State = StateDual
	case hasCPE:
		st.State = StateCPEOnly
	case hasISP && !st.LearnedCustomer:
		st.State = StateISPOnly
	case hasISP && st.LearnedCustomer:
		// Customer was learned; CPE later silent — still not ARP master.
		st.State = StateCPEOnly
	default:
		st.State = StateIdle
	}
	st.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
}

func topCandidate(counts map[string]int, gw string) string {
	best := ""
	bestN := 0
	for ip, n := range counts {
		if ip == gw || !usableHitchIP(ip) {
			continue
		}
		if n > bestN {
			best, bestN = ip, n
		}
	}
	return best
}

// usableHitchIP is a unicast address we may hitchhike. Spec: learn hosts only;
// never 169.254 (APIPA / leftover iface), GFC reserved VIP/hitch, or TUN.
func usableHitchIP(s string) bool {
	ip := net.ParseIP(strings.TrimSpace(s)).To4()
	if ip == nil || ip.IsUnspecified() || ip.IsLoopback() || ip.IsMulticast() || ip.IsLinkLocalUnicast() {
		return false
	}
	if ip[0] >= 224 {
		return false
	}
	if ip[0] == 172 && ip[1] == 31 && (ip[2] == 252 || ip[2] == 253) {
		return false
	}
	if ip[0] == 172 && ip[1] == 19 && ip[2] == 0 && ip[3] <= 3 {
		return false
	}
	return true
}

func isRFC1918(ip net.IP) bool {
	ip = ip.To4()
	if ip == nil {
		return false
	}
	if ip[0] == 10 {
		return true
	}
	if ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31 {
		return true
	}
	return ip[0] == 192 && ip[1] == 168
}

// onLinkGW is an ARP/DHCP next hop we may hitch via. Spec: GW from isp ARP,
// not from transit IPv4. Private CE cannot hitch a public VPN/CDN address.
func onLinkGW(ce, gw string) bool {
	if !usableHitchIP(gw) || gw == strings.TrimSpace(ce) {
		return false
	}
	ceIP := net.ParseIP(strings.TrimSpace(ce)).To4()
	gwIP := net.ParseIP(strings.TrimSpace(gw)).To4()
	if gwIP == nil {
		return false
	}
	if ceIP == nil {
		return true
	}
	return isRFC1918(ceIP) == isRFC1918(gwIP)
}

func formatMAC(b []byte) string {
	if len(b) != 6 {
		return ""
	}
	return strings.ToLower(net.HardwareAddr(b).String())
}

// ShouldAnswerCEARP is false once a real customer has been observed.
func ShouldAnswerCEARP(st Learned) bool {
	if st.LearnedCustomer {
		return false
	}
	return NormalizeState(st.State) == StateISPOnly
}
