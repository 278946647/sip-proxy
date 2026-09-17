package transparent

import (
	"encoding/binary"
	"net"
	"sort"
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

// CEReplaceAfter is how long the hitch MAC may stay silent before a different
// cable MAC with a usable IP takes the primary slot. Shorter than CEStaleAfter:
// Plan A (same MAC, shutdown/standby, no other host) never hits this path.
// Dual-PC both talking keep the sticky primary.
const CEReplaceAfter = 2 * time.Second

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
	now := time.Now().UTC()
	demoteDeadCE(st, now)
	if st.CEIP == "" && (len(st.CECandidates) > 0 || len(st.Hosts) > 0) {
		st.CEIP = electCE(st, now)
	}
	if !usableHitchIP(st.CEIP) {
		st.CEIP = electCE(st, now)
	}
	if strings.TrimSpace(st.CEIP) != "" && strings.TrimSpace(st.GWIP) != "" {
		// Private-vs-public (onLinkGW) or a different /24 (cable moved) must
		// drop the old next hop so we do not keep posting to a dead PE MAC.
		if !onLinkGW(st.CEIP, st.GWIP) || !sameIPv4Slash24(st.CEIP, st.GWIP) {
			st.GWIP = ""
			st.GWStrong = false
			st.PEMAC = ""
		}
	}
	syncPrimaryMAC(st)
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
		st.LearnedCustomer = true
		if usableHitchIP(spaStr) && spaStr != st.GWIP {
			rememberHost(st, spaStr, srcMAC)
			st.CECandidates[spaStr]++
			if op == arpOpRequest && tpa != nil && !tpa.IsUnspecified() && usableHitchIP(tpa.String()) {
				// Host ARPing the gateway — strongest CE signal.
				st.CECandidates[spaStr] += 5
			}
			hotUpdateCEIfSameMAC(st, spaStr, srcMAC)
		}
		if spaStr == st.CEIP {
			st.CEMiss = 0
		}
		// GW is the on-link next hop the CE is ARPing. A target we already know
		// as a cable host is a peer, never the gateway. Weak evidence only: it
		// must not overwrite a next hop confirmed from the PE side.
		if op == arpOpRequest && tpa != nil && !isKnownHost(st, tpa.String()) {
			setGW(st, tpa.String(), false)
		}
	case RoleISP:
		// Learn the PE MAC only from the gateway's own ARP. Transit IPv4
		// and ARP from other ISP-side hosts must not rotate the L2 next hop.
		if op == arpOpRequest && tpa != nil {
			target := tpa.String()
			if target == st.CEIP && st.CEIP != "" {
				// Unanswered who-has the hitch IP. Demote only if another
				// cable host is fresh (Plan A: sole CE keeps hitch).
				st.CEMiss++
			}
			if (target == st.CEIP && st.CEIP != "") || isKnownHost(st, target) {
				// Only the real next hop ARPs for hosts on our side of the
				// cable. A second on-link IP who-has CE (lab vSwitch / VMware
				// .1) must not steal a GW we already confirmed on this /24.
				setGW(st, spaStr, true)
				if st.PEMAC == "" && spaStr == st.GWIP {
					st.PEMAC = srcMAC
				}
			}
		}
		if st.GWIP == "" && st.PEMAC == "" && !isKnownHost(st, spaStr) && onLinkGW(st.CEIP, spaStr) {
			setGW(st, spaStr, false)
			if st.GWIP == spaStr {
				st.PEMAC = srcMAC
			}
		} else if spaStr == st.GWIP {
			// First ARP from the gateway fills PE. Later ARP claiming the
			// same GW IP (proxy-ARP, extra ISP hosts) must not rotate the
			// L2 next hop — that blackholes all WAN DNS and VLESS.
			if st.PEMAC == "" {
				st.PEMAC = srcMAC
			}
		}
	}
}

func isKnownHost(st *Learned, ip string) bool {
	if st == nil || len(st.Hosts) == 0 {
		return false
	}
	_, ok := st.Hosts[strings.TrimSpace(ip)]
	return ok
}

// setGW records the on-link next hop. Weak evidence (a CPE-side ARP target)
// only fills an empty slot. Strong evidence (ISP who-has CE/host) may fill or
// confirm the slot, but must not replace an already-chosen GW while the CE
// still sits on that /24 — that is the lab twin / VMware .1 steal. A cable
// moved to another /24 clears GW in ApplyFrame, then this may learn again.
func setGW(st *Learned, gw string, strong bool) {
	gw = strings.TrimSpace(gw)
	if st == nil || !onLinkGW(st.CEIP, gw) {
		return
	}
	cur := strings.TrimSpace(st.GWIP)
	if !strong && (st.GWStrong || cur != "") {
		return
	}
	if strong && cur != "" && cur != gw && sameIPv4Slash24(st.CEIP, cur) {
		return
	}
	if cur != "" && cur != gw {
		// The freeze is scoped to one GW identity: it stops proxy-ARP and lab
		// twins from rotating the next hop, but a cable moved to another
		// segment must be able to learn the new PE instead of posting frames
		// to a MAC that no longer exists there.
		st.PEMAC = ""
	}
	st.GWIP = gw
	st.GWStrong = strong
	if strong {
		// A confirmed next hop is not a customer; drop any stale host entry so
		// it stops claiming a /32 route and a host_mac return rule.
		delete(st.Hosts, gw)
		delete(st.CECandidates, gw)
	}
}

// sameIPv4Slash24 is the L2-segment hint for GW freeze. Spec forbids guessing
// a LAN prefix to own; this only asks whether CE and GW still share a /24 so
// a neighbour on the same wire cannot rotate the next hop.
func sameIPv4Slash24(a, b string) bool {
	aa := net.ParseIP(strings.TrimSpace(a)).To4()
	bb := net.ParseIP(strings.TrimSpace(b)).To4()
	if aa == nil || bb == nil {
		return false
	}
	return aa[0] == bb[0] && aa[1] == bb[1] && aa[2] == bb[2]
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
		st.LearnedCustomer = true
		if usableHitchIP(srcStr) && srcStr != st.GWIP {
			rememberHost(st, srcStr, srcMAC)
			st.CECandidates[srcStr]++
			hotUpdateCEIfSameMAC(st, srcStr, srcMAC)
		}
		if srcStr == st.CEIP {
			st.CEMiss = 0
		}
		if proto == 17 {
			applyDHCP(payload[ihl:], srcMAC, st)
		}
	case RoleISP:
		// IPv4 on ISP is transit traffic. PE MAC / GW IP come from ARP;
		// accepting this source MAC would let any upstream host replace PE.
	}
}

func applyDHCP(udp []byte, srcMAC string, st *Learned) {
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
	chaddr := strings.TrimSpace(srcMAC)
	if bootp[1] == 1 && bootp[2] >= 6 && len(bootp) >= 34 {
		if mac := formatMAC(bootp[28:34]); mac != "" {
			chaddr = mac
		}
	}
	learnDHCPHost := func(ip string) {
		ip = strings.TrimSpace(ip)
		if !usableHitchIP(ip) || ip == strings.TrimSpace(st.GWIP) {
			return
		}
		st.CECandidates[ip] += 8
		if chaddr == "" {
			return
		}
		rememberHost(st, ip, chaddr)
		hotUpdateCEIfSameMAC(st, ip, chaddr)
	}
	if yiaddr := net.IP(bootp[16:20]).To4(); yiaddr != nil {
		learnDHCPHost(yiaddr.String())
	}
	// options after magic cookie 236+4
	opts := bootp[240:]
	if req := dhcpOptionIP(opts, 50); req != "" {
		learnDHCPHost(req)
	}
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

func rememberHost(st *Learned, ip, mac string) {
	if st == nil || !usableHitchIP(ip) || ip == st.GWIP || strings.TrimSpace(mac) == "" {
		return
	}
	if st.Hosts == nil {
		st.Hosts = map[string]HostEntry{}
	}
	st.Hosts[ip] = HostEntry{MAC: mac, At: time.Now().UTC().Format(time.RFC3339)}
	pruneHosts(st)
}

func sameMAC(a, b string) bool {
	return strings.EqualFold(strings.TrimSpace(a), strings.TrimSpace(b))
}

// hotUpdateCEIfSameMAC implements "CE DHCP 换址则热更新": the same Ethernet
// host moved to another unicast IP. A different MAC is not this path.
func hotUpdateCEIfSameMAC(st *Learned, ip, mac string) {
	if st == nil || !usableHitchIP(ip) {
		return
	}
	ce := strings.TrimSpace(st.CEIP)
	if ce == "" || ip == ce {
		return
	}
	primaryMAC := strings.TrimSpace(st.CPEMAC)
	if h, ok := st.Hosts[ce]; ok && strings.TrimSpace(h.MAC) != "" {
		primaryMAC = h.MAC
	}
	if primaryMAC == "" || !sameMAC(mac, primaryMAC) {
		return
	}
	delete(st.Hosts, ce)
	delete(st.CECandidates, ce)
	st.CEIP = ip
	st.CEMiss = 0
}

func pruneHosts(st *Learned) {
	if st == nil || len(st.Hosts) == 0 {
		return
	}
	now := time.Now().UTC()
	for ip, h := range st.Hosts {
		if strings.TrimSpace(h.At) == "" {
			continue
		}
		t, err := time.Parse(time.RFC3339, h.At)
		if err != nil {
			continue
		}
		if now.Sub(t) > HostTTL {
			delete(st.Hosts, ip)
		}
	}
}

func hostSeenAt(h HostEntry) (time.Time, bool) {
	at := strings.TrimSpace(h.At)
	if at == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, at)
	if err != nil {
		return time.Time{}, false
	}
	return t.UTC(), true
}

func hostFresh(st *Learned, ip string, now time.Time) bool {
	h, ok := st.Hosts[strings.TrimSpace(ip)]
	if !ok {
		return false
	}
	at, ok := hostSeenAt(h)
	if !ok {
		return false
	}
	return now.Sub(at) <= CEStaleAfter
}

func otherFreshHost(st *Learned, ce string, now time.Time) bool {
	if st == nil {
		return false
	}
	ce = strings.TrimSpace(ce)
	for ip := range st.Hosts {
		if ip != ce && hostFresh(st, ip, now) {
			return true
		}
	}
	return false
}

func primaryMAC(st *Learned) string {
	if st == nil {
		return ""
	}
	ce := strings.TrimSpace(st.CEIP)
	if h, ok := st.Hosts[ce]; ok && strings.TrimSpace(h.MAC) != "" {
		return h.MAC
	}
	return strings.TrimSpace(st.CPEMAC)
}

func ceSeenWithin(st *Learned, ce string, now time.Time, window time.Duration) bool {
	h, ok := st.Hosts[strings.TrimSpace(ce)]
	if !ok {
		return false
	}
	at, ok := hostSeenAt(h)
	if !ok {
		return false
	}
	return now.Sub(at) < window
}

// replacedByNewMAC is a device swap: a fresh cable host whose MAC is not the
// hitch CPE, and the old hitch identity has been quiet for CEReplaceAfter.
// Same-MAC standby has no other MAC, so Plan A still holds.
func replacedByNewMAC(st *Learned, now time.Time) bool {
	if st == nil {
		return false
	}
	ce := strings.TrimSpace(st.CEIP)
	cpe := primaryMAC(st)
	if ce == "" || cpe == "" {
		return false
	}
	if ceSeenWithin(st, ce, now, CEReplaceAfter) {
		return false
	}
	for ip, h := range st.Hosts {
		if ip == ce {
			continue
		}
		if !hostFresh(st, ip, now) || strings.TrimSpace(h.MAC) == "" {
			continue
		}
		if sameMAC(h.MAC, cpe) {
			continue
		}
		return true
	}
	return false
}

// demoteDeadCE retires a hitch IP only on evidence, never on a timer guess.
// Plan A: a quiet sole CE (shutdown/standby, cpe still up) keeps the hitch —
// unanswered PE who-has is not enough without another fresh cable host.
func demoteDeadCE(st *Learned, now time.Time) {
	ce := strings.TrimSpace(st.CEIP)
	if ce == "" {
		return
	}
	other := otherFreshHost(st, ce, now)
	dead := (st.CEMiss >= CEArpMissLimit && other) || (!hostFresh(st, ce, now) && other) || replacedByNewMAC(st, now)
	if !dead {
		return
	}
	delete(st.Hosts, ce)
	delete(st.CECandidates, ce)
	st.CEMiss = 0
	st.CEIP = electCE(st, now)
	if st.CEIP == "" {
		// Nothing left to hitch: stop spoofing a MAC whose owner is gone.
		st.CPEMAC = ""
	}
}

// electCE prefers a cable host proven alive recently; weight breaks ties so a
// host that ARPs the gateway still wins over a chatty peer.
func electCE(st *Learned, now time.Time) string {
	best := ""
	bestScore := -1
	var bestAt time.Time
	for ip, h := range st.Hosts {
		if ip == st.GWIP || h.MAC == "" || !usableHitchIP(ip) {
			continue
		}
		at, ok := hostSeenAt(h)
		if !ok || now.Sub(at) > CEStaleAfter {
			continue
		}
		score := st.CECandidates[ip]
		if score > bestScore || (score == bestScore && at.After(bestAt)) {
			best, bestScore, bestAt = ip, score, at
		}
	}
	if best != "" {
		return best
	}
	return topCandidate(st.CECandidates, st.GWIP)
}

func syncPrimaryMAC(st *Learned) {
	if st == nil || strings.TrimSpace(st.CEIP) == "" {
		return
	}
	if h, ok := st.Hosts[st.CEIP]; ok && h.MAC != "" {
		st.CPEMAC = h.MAC
	}
}

// PublicACLHosts are extra unbound allows for public interconnect hosts.
// RFC1918 sources are already allowed in the main server: block.
func (l Learned) PublicACLHosts() []string {
	seen := map[string]struct{}{}
	var out []string
	add := func(ip string) {
		ip = strings.TrimSpace(ip)
		parsed := net.ParseIP(ip)
		if parsed == nil || parsed.To4() == nil || isRFC1918(parsed.To4()) || !usableHitchIP(ip) {
			return
		}
		if _, ok := seen[ip]; ok {
			return
		}
		seen[ip] = struct{}{}
		out = append(out, ip)
	}
	add(l.CEIP)
	for ip := range l.Hosts {
		add(ip)
	}
	sort.Strings(out)
	return out
}

func recomputeState(st *Learned) {
	hasCPE := st.CPEMAC != "" || st.CEIP != "" || len(st.Hosts) > 0
	// GWIP may be learned from a CPE ARP request or DHCP option before any
	// ISP frame is observed. Only PEMAC proves that the ISP side is present.
	hasISP := st.PEMAC != ""
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
