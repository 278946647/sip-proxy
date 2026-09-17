package transparent

import (
	"encoding/binary"
	"fmt"
	"net"
	"strings"
)

// HitchInput is the runtime evidence ComputeHitch needs (no timers).
type HitchInput struct {
	Learned             Learned
	Spare               SpareConfig
	CPEDown             bool
	HoldSpareUntilFrame bool
	BoxMAC              string
}

// ComputeHitch picks Plan A (CE + CPE MAC) or Plan B (spare + box MAC).
// Plan B only when spare is configured and (cpe down, never learned, or
// holding spare until the first usable CPE frame after a down→up).
func ComputeHitch(in HitchInput) HitchIdentity {
	spare := in.Spare.Normalized()
	boxMAC := strings.ToLower(strings.TrimSpace(in.BoxMAC))
	learned := in.Learned
	never := !learned.LearnedCustomer && strings.TrimSpace(learned.CEIP) == ""
	useSpare := spare.Usable() && (in.CPEDown || never || in.HoldSpareUntilFrame)
	if useSpare {
		gw := spare.Gateway
		if strings.TrimSpace(learned.GWIP) != "" {
			gw = learned.GWIP
		}
		return HitchIdentity{
			Mode:   HitchModeSpare,
			IP:     spare.IP,
			SrcMAC: boxMAC,
			PEMAC:  learned.PEMAC,
			GWIP:   gw,
		}
	}
	return HitchIdentity{
		Mode:   HitchModeCE,
		IP:     strings.TrimSpace(learned.CEIP),
		SrcMAC: strings.ToLower(strings.TrimSpace(learned.CPEMAC)),
		PEMAC:  learned.PEMAC,
		GWIP:   learned.GWIP,
	}
}

// ShouldAnswerCEARPWithSpare is false once a customer was learned, or when a
// spare IP is configured (never guess a CE to answer).
func ShouldAnswerCEARPWithSpare(st Learned, spare SpareConfig) bool {
	if spare.Usable() {
		return false
	}
	return ShouldAnswerCEARP(st)
}

// ValidateSpare allows an empty spare (Plan B stays off). A set address must
// be a hitch-usable unicast IPv4 that is not on the management LAN.
func ValidateSpare(spare SpareConfig, lanCIDR string) error {
	spare = spare.Normalized()
	if spare.IP == "" {
		return nil
	}
	if !usableHitchIP(spare.IP) {
		return fmt.Errorf("备用管理 IP 无效: %s", spare.IP)
	}
	if spare.Prefix < 1 || spare.Prefix > 32 {
		return fmt.Errorf("备用管理 IP 前缀无效: %d", spare.Prefix)
	}
	ip := net.ParseIP(spare.IP).To4()
	if lanCIDR != "" {
		_, lanNet, err := net.ParseCIDR(strings.TrimSpace(lanCIDR))
		if err == nil && lanNet.Contains(ip) {
			return fmt.Errorf("备用管理 IP %s 与管理 LAN %s 冲突", spare.IP, lanCIDR)
		}
	}
	if spare.Gateway != "" && !usableHitchIP(spare.Gateway) {
		return fmt.Errorf("备用管理网关无效: %s", spare.Gateway)
	}
	if spare.Gateway != "" && spare.Gateway == spare.IP {
		return fmt.Errorf("备用管理网关不能与备用 IP 相同")
	}
	return nil
}

// ApplySpareARP learns PE/GW from ISP ARP aimed at the spare IP or sourced
// from the configured spare gateway. Does not answer CE ARP.
func ApplySpareARP(role Role, frame []byte, st *Learned, spare SpareConfig) {
	if st == nil || role != RoleISP || !spare.Usable() || len(frame) < ethLen {
		return
	}
	et := binary.BigEndian.Uint16(frame[12:14])
	if et != etherARP {
		return
	}
	payload := frame[ethLen:]
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
	srcMAC := formatMAC(frame[6:12])
	spaStr := spa.String()
	spare = spare.Normalized()
	gwWant := spare.Gateway
	target := ""
	if tpa != nil {
		target = tpa.String()
	}
	if op == arpOpRequest && target == spare.IP {
		setGW(st, spaStr, true)
		if st.PEMAC == "" && spaStr == st.GWIP {
			st.PEMAC = srcMAC
		}
		return
	}
	if gwWant != "" && spaStr == gwWant {
		if st.GWIP == "" {
			setGW(st, gwWant, false)
		}
		if st.PEMAC == "" && (st.GWIP == gwWant || st.GWIP == "") {
			if st.GWIP == "" {
				st.GWIP = gwWant
			}
			st.PEMAC = srcMAC
		}
	}
}

func frameUsableHitchHost(frame []byte, gw string) bool {
	ip := frameSourceIP(frame)
	if !usableHitchIP(ip) {
		return false
	}
	return ip != strings.TrimSpace(gw)
}

func frameSourceIP(frame []byte) string {
	if len(frame) < ethLen {
		return ""
	}
	et := binary.BigEndian.Uint16(frame[12:14])
	payload := frame[ethLen:]
	switch et {
	case etherARP:
		if len(payload) < 28 {
			return ""
		}
		spa := net.IP(payload[14:18]).To4()
		if spa == nil {
			return ""
		}
		return spa.String()
	case etherIPv4:
		if len(payload) < 20 {
			return ""
		}
		src := net.IP(payload[12:16]).To4()
		if src == nil {
			return ""
		}
		return src.String()
	default:
		return ""
	}
}
