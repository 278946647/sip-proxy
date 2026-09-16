package transparent

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"
)

func TestApplyFrameCPEThenISPReachesDual(t *testing.T) {
	st := &Learned{}
	cpeMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x01}
	peMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x02}
	ce := net.IPv4(10, 50, 0, 2).To4()
	gw := net.IPv4(10, 50, 0, 1).To4()

	ApplyFrame(RoleCPE, arpFrame(cpeMAC, ce, gw, arpOpRequest), st)
	if !st.LearnedCustomer || st.State != StateCPEOnly {
		t.Fatalf("after cpe: %+v", st)
	}
	if ShouldAnswerCEARP(*st) {
		t.Fatal("must not answer CE ARP after customer learned")
	}
	ApplyFrame(RoleISP, arpFrame(peMAC, gw, ce, arpOpReply), st)
	if st.State != StateDual {
		t.Fatalf("expected dual, got %+v", st)
	}
	if st.CEIP != "10.50.0.2" || st.GWIP != "10.50.0.1" {
		t.Fatalf("ce/gw %+v", st)
	}
	if st.CPEMAC != "02:00:00:00:00:01" || st.PEMAC != "02:00:00:00:00:02" {
		t.Fatalf("macs %+v", st)
	}
}

func TestShouldAnswerCEARPOnlyISPOnlyNeverLearned(t *testing.T) {
	if ShouldAnswerCEARP(Learned{State: StateISPOnly, LearnedCustomer: false}) != true {
		t.Fatal("isp_only never-learned may answer")
	}
	if ShouldAnswerCEARP(Learned{State: StateDual, LearnedCustomer: true}) {
		t.Fatal("dual must not answer")
	}
	if ShouldAnswerCEARP(Learned{State: StateCPEOnly, LearnedCustomer: true}) {
		t.Fatal("cpe_only must not answer")
	}
}

func TestSkipLinkLocalCE(t *testing.T) {
	st := &Learned{}
	cpeMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x01}
	ll := net.IPv4(169, 254, 57, 225).To4()
	gw := net.IPv4(192, 168, 88, 1).To4()
	ApplyFrame(RoleCPE, arpFrame(cpeMAC, ll, gw, arpOpRequest), st)
	if st.CEIP == "169.254.57.225" {
		t.Fatal("must not hitch APIPA CE")
	}
	ce := net.IPv4(192, 168, 88, 20).To4()
	ApplyFrame(RoleCPE, arpFrame(cpeMAC, ce, gw, arpOpRequest), st)
	if st.CEIP != "192.168.88.20" {
		t.Fatalf("want real CE, got %+v", st)
	}
	if st.GWIP != "192.168.88.1" {
		t.Fatalf("want ARP gateway, got %+v", st)
	}
}

func TestISPTransitIPv4DoesNotBecomeGW(t *testing.T) {
	st := &Learned{PEMAC: "02:00:00:00:00:00"}
	cpeMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x01}
	transitMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x99}
	ce := net.IPv4(192, 168, 88, 193).To4()
	gw := net.IPv4(192, 168, 88, 1).To4()
	vpn := net.IPv4(116, 63, 224, 146).To4()
	ApplyFrame(RoleCPE, arpFrame(cpeMAC, ce, gw, arpOpRequest), st)
	if st.CEIP != "192.168.88.193" || st.GWIP != "192.168.88.1" {
		t.Fatalf("after cpe arp: %+v", st)
	}
	frame := make([]byte, 14+20)
	copy(frame[6:12], transitMAC)
	binary.BigEndian.PutUint16(frame[12:14], etherIPv4)
	frame[14] = 0x45
	copy(frame[26:30], vpn)
	copy(frame[30:34], ce)
	ApplyFrame(RoleISP, frame, st)
	if st.GWIP != "192.168.88.1" {
		t.Fatalf("transit IPv4 must not become GW, got %+v", st)
	}
	if st.PEMAC != "02:00:00:00:00:00" {
		t.Fatalf("transit IPv4 replaced PE MAC: %+v", st)
	}
}

func TestISPNonGatewayARPDoesNotReplacePEMAC(t *testing.T) {
	st := &Learned{GWIP: "192.168.88.1", PEMAC: "02:00:00:00:00:02"}
	hostMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x99}
	host := net.IPv4(192, 168, 88, 200).To4()
	target := net.IPv4(192, 168, 88, 199).To4()

	ApplyFrame(RoleISP, arpFrame(hostMAC, host, target, arpOpRequest), st)

	if st.GWIP != "192.168.88.1" || st.PEMAC != "02:00:00:00:00:02" {
		t.Fatalf("non-gateway ARP replaced PE identity: %+v", st)
	}
}

func TestISPGatewayARPDoesNotRotateExistingPEMAC(t *testing.T) {
	st := &Learned{GWIP: "192.168.88.1", PEMAC: "00:a5:27:e0:28:18"}
	other := []byte{0x70, 0x70, 0xfc, 0x07, 0xc2, 0x3e}
	gw := net.IPv4(192, 168, 88, 1).To4()
	ce := net.IPv4(192, 168, 88, 191).To4()

	ApplyFrame(RoleISP, arpFrame(other, gw, ce, arpOpReply), st)

	if st.PEMAC != "00:a5:27:e0:28:18" {
		t.Fatalf("gateway ARP rotated PE MAC: %+v", st)
	}
}

func TestFieldCPEUnicastICMPToGWLearnsDual(t *testing.T) {
	// Field: eth1 00:e2:69:1b:31:60 192.168.88.193 → 192.168.88.1 (PE 00:a5:27:e0:28:18).
	st := &Learned{State: StateISPOnly, PEMAC: "00:a5:27:e0:28:18", GWIP: "192.168.88.1"}
	cpeMAC, _ := net.ParseMAC("00:e2:69:1b:31:60")
	peMAC, _ := net.ParseMAC("00:a5:27:e0:28:18")
	ce := net.IPv4(192, 168, 88, 193).To4()
	gw := net.IPv4(192, 168, 88, 1).To4()
	frame := make([]byte, 14+20)
	copy(frame[0:6], peMAC)
	copy(frame[6:12], cpeMAC)
	binary.BigEndian.PutUint16(frame[12:14], etherIPv4)
	frame[14] = 0x45
	copy(frame[26:30], ce)
	copy(frame[30:34], gw)
	ApplyFrame(RoleCPE, frame, st)
	if st.State != StateDual || !st.LearnedCustomer {
		t.Fatalf("expected dual after cpe unicast, got %+v", st)
	}
	if st.CEIP != "192.168.88.193" || st.CPEMAC != "00:e2:69:1b:31:60" {
		t.Fatalf("ce/mac %+v", st)
	}
}

func TestApplyFrameIPv4LearnsCE(t *testing.T) {
	st := &Learned{}
	cpeMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x01}
	ce := net.IPv4(10, 50, 0, 2).To4()
	dst := net.IPv4(8, 8, 8, 8).To4()
	frame := make([]byte, 14+20)
	copy(frame[6:12], cpeMAC)
	binary.BigEndian.PutUint16(frame[12:14], etherIPv4)
	frame[14] = 0x45
	copy(frame[26:30], ce)
	copy(frame[30:34], dst)
	ApplyFrame(RoleCPE, frame, st)
	if !st.LearnedCustomer || st.CEIP != "10.50.0.2" {
		t.Fatalf("ipv4 learn: %+v", st)
	}
	if st.CPEMAC != "02:00:00:00:00:01" {
		t.Fatalf("cpe mac %+v", st)
	}
}

func TestCPESecondHostDoesNotRotatePrimaryMAC(t *testing.T) {
	st := &Learned{}
	aMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x01}
	bMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x0b}
	a := net.IPv4(10, 50, 0, 2).To4()
	b := net.IPv4(10, 50, 0, 3).To4()
	gw := net.IPv4(10, 50, 0, 1).To4()
	ApplyFrame(RoleCPE, arpFrame(aMAC, a, gw, arpOpRequest), st)
	if st.CEIP != "10.50.0.2" || st.CPEMAC != "02:00:00:00:00:01" {
		t.Fatalf("primary after A: %+v", st)
	}
	ApplyFrame(RoleCPE, arpFrame(bMAC, b, gw, arpOpRequest), st)
	if st.CEIP != "10.50.0.2" {
		t.Fatalf("primary CE must stay sticky, got %+v", st)
	}
	if st.CPEMAC != "02:00:00:00:00:01" {
		t.Fatalf("CPE MAC last-writer rotated to B: %+v", st)
	}
	if st.Hosts["10.50.0.3"].MAC != "02:00:00:00:00:0b" {
		t.Fatalf("host B missing: %+v", st.Hosts)
	}
	if st.Hosts["10.50.0.2"].MAC != "02:00:00:00:00:01" {
		t.Fatalf("host A missing: %+v", st.Hosts)
	}
}

func TestPublicACLHostsSkipsRFC1918(t *testing.T) {
	st := Learned{
		CEIP: "10.50.0.2",
		Hosts: map[string]HostEntry{
			"10.50.0.3": {MAC: "02:00:00:00:00:0b"},
			"203.0.113.10": {MAC: "02:00:00:00:00:0c"},
		},
	}
	got := st.PublicACLHosts()
	if len(got) != 1 || got[0] != "203.0.113.10" {
		t.Fatalf("want only public host, got %v", got)
	}
}

func TestTaggedAndIPv6Ignored(t *testing.T) {
	st := &Learned{}
	frame := make([]byte, 18)
	copy(frame[6:12], []byte{1, 2, 3, 4, 5, 6})
	binary.BigEndian.PutUint16(frame[12:14], etherDot1Q)
	ApplyFrame(RoleCPE, frame, st)
	if st.LearnedCustomer {
		t.Fatal("802.1Q must stay L2 / not learn")
	}
}

func TestResolveVIPAvoidsLANAndCE(t *testing.T) {
	vip, err := ResolveVIP(DefaultVIP, "172.31.253.0/24", Learned{CEIP: "10.1.1.2"}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if vip == DefaultVIP {
		t.Fatalf("VIP should move out of overlapping LAN pool, got %s", vip)
	}
	if vip == HitchBindIP {
		t.Fatal("must not use hitch bind IP")
	}
	ok, err := ResolveVIP(DefaultVIP, "192.168.1.0/24", Learned{CEIP: "10.50.0.2"}, nil, nil)
	if err != nil || ok != DefaultVIP {
		t.Fatalf("default VIP should win: %s %v", ok, err)
	}
}

func TestValidatePorts(t *testing.T) {
	if err := ValidatePorts(Ports{ISP: "eth1", CPE: "eth2"}, "br-lan"); err != nil {
		t.Fatal(err)
	}
	if err := ValidatePorts(Ports{ISP: "eth1", CPE: "eth1"}, "br-lan"); err == nil {
		t.Fatal("same port")
	}
	if err := ValidatePorts(Ports{ISP: "br-lan", CPE: "eth2"}, "br-lan"); err == nil {
		t.Fatal("lan overlap")
	}
	if err := ValidatePorts(Ports{ISP: "gfctun", CPE: "eth2"}, "br-lan"); err == nil {
		t.Fatal("reserved")
	}
}

func TestCPEPeerARPDoesNotBecomeGW(t *testing.T) {
	st := &Learned{}
	hostA := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x0a}
	hostB := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x0b}
	a := net.IPv4(192, 168, 88, 191).To4()
	b := net.IPv4(192, 168, 88, 189).To4()
	gw := net.IPv4(192, 168, 88, 1).To4()

	ApplyFrame(RoleCPE, arpFrame(hostB, b, gw, arpOpRequest), st)
	// A asks for its neighbour B: a peer, never the next hop.
	ApplyFrame(RoleCPE, arpFrame(hostA, a, b, arpOpRequest), st)
	if st.GWIP != "192.168.88.1" {
		t.Fatalf("peer ARP hijacked GW: %+v", st)
	}
	if _, ok := st.Hosts["192.168.88.189"]; !ok {
		t.Fatalf("peer must stay a cable host: %+v", st.Hosts)
	}
}

func TestISPARPForCableHostConfirmsGW(t *testing.T) {
	st := &Learned{}
	host := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x0a}
	peMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x02}
	otherMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x77}
	ce := net.IPv4(192, 168, 88, 191).To4()
	gw := net.IPv4(192, 168, 88, 1).To4()
	neighbour := net.IPv4(192, 168, 88, 200).To4()

	ApplyFrame(RoleCPE, arpFrame(host, ce, gw, arpOpRequest), st)
	// A chatty neighbour on a shared segment must not be crowned gateway.
	ApplyFrame(RoleISP, arpFrame(otherMAC, neighbour, neighbour, arpOpRequest), st)
	if st.GWIP != "192.168.88.1" {
		t.Fatalf("shared-segment host became GW: %+v", st)
	}
	// The real next hop is the one ARPing for our side of the cable.
	ApplyFrame(RoleISP, arpFrame(peMAC, gw, ce, arpOpRequest), st)
	if st.GWIP != "192.168.88.1" || st.PEMAC != "02:00:00:00:00:02" {
		t.Fatalf("gw/pe %+v", st)
	}
}

func TestPEMACRelearnedAfterSegmentMove(t *testing.T) {
	st := &Learned{}
	hostMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x0a}
	oldPE := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x02}
	newPE := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x03}
	oldCE := net.IPv4(192, 168, 88, 191).To4()
	oldGW := net.IPv4(192, 168, 88, 1).To4()
	newCE := net.IPv4(192, 168, 33, 129).To4()
	newGW := net.IPv4(192, 168, 33, 2).To4()

	ApplyFrame(RoleCPE, arpFrame(hostMAC, oldCE, oldGW, arpOpRequest), st)
	ApplyFrame(RoleISP, arpFrame(oldPE, oldGW, oldCE, arpOpRequest), st)
	if st.PEMAC != "02:00:00:00:00:02" {
		t.Fatalf("first PE not learned: %+v", st)
	}
	// Same GW: a twin claiming the next hop must not rotate the MAC.
	ApplyFrame(RoleISP, arpFrame(newPE, oldGW, oldCE, arpOpRequest), st)
	if st.PEMAC != "02:00:00:00:00:02" {
		t.Fatalf("PE freeze broken within one GW: %+v", st)
	}
	// Cable moved to another segment: the old PE MAC is a black hole there.
	ApplyFrame(RoleCPE, arpFrame(hostMAC, newCE, newGW, arpOpRequest), st)
	ApplyFrame(RoleISP, arpFrame(newPE, newGW, newCE, arpOpRequest), st)
	if st.GWIP != "192.168.33.2" || st.PEMAC != "02:00:00:00:00:03" {
		t.Fatalf("PE not relearned after segment move: %+v", st)
	}
}

func TestDeadCEDemotedAfterUnansweredISPARP(t *testing.T) {
	st := &Learned{}
	deadMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x0a}
	liveMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x0b}
	peMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x02}
	dead := net.IPv4(192, 168, 88, 191).To4()
	live := net.IPv4(192, 168, 88, 189).To4()
	gw := net.IPv4(192, 168, 88, 1).To4()

	ApplyFrame(RoleCPE, arpFrame(deadMAC, dead, gw, arpOpRequest), st)
	ApplyFrame(RoleCPE, arpFrame(liveMAC, live, gw, arpOpRequest), st)
	if st.CEIP != "192.168.88.191" {
		t.Fatalf("first host should hold the hitch slot: %+v", st)
	}
	for i := 0; i < CEArpMissLimit; i++ {
		ApplyFrame(RoleISP, arpFrame(peMAC, gw, dead, arpOpRequest), st)
	}
	if st.CEIP != "192.168.88.189" {
		t.Fatalf("dead CE not replaced: %+v", st)
	}
	if st.CPEMAC != "02:00:00:00:00:0b" {
		t.Fatalf("primary MAC must follow the new CE: %+v", st)
	}
	if _, ok := st.Hosts["192.168.88.191"]; ok {
		t.Fatal("dead host must not keep a return rule")
	}
}

func TestLiveCEKeepsHitchWhenAnswering(t *testing.T) {
	st := &Learned{}
	ceMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x0a}
	peMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x02}
	ce := net.IPv4(192, 168, 88, 191).To4()
	other := net.IPv4(192, 168, 88, 189).To4()
	gw := net.IPv4(192, 168, 88, 1).To4()

	ApplyFrame(RoleCPE, arpFrame(ceMAC, ce, gw, arpOpRequest), st)
	ApplyFrame(RoleCPE, arpFrame([]byte{0x02, 0, 0, 0, 0, 0x0b}, other, gw, arpOpRequest), st)
	for i := 0; i < CEArpMissLimit*2; i++ {
		ApplyFrame(RoleISP, arpFrame(peMAC, gw, ce, arpOpRequest), st)
		// The CE answers, so the miss counter must never reach the limit.
		ApplyFrame(RoleCPE, arpFrame(ceMAC, ce, gw, arpOpReply), st)
	}
	if st.CEIP != "192.168.88.191" {
		t.Fatalf("live CE was demoted: %+v", st)
	}
}

func arpFrame(srcMAC, spa, tpa []byte, op uint16) []byte {
	buf := bytes.NewBuffer(nil)
	buf.Write([]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
	buf.Write(srcMAC)
	_ = binary.Write(buf, binary.BigEndian, uint16(etherARP))
	_ = binary.Write(buf, binary.BigEndian, uint16(1))
	_ = binary.Write(buf, binary.BigEndian, uint16(etherIPv4))
	buf.WriteByte(6)
	buf.WriteByte(4)
	_ = binary.Write(buf, binary.BigEndian, op)
	buf.Write(srcMAC)
	buf.Write(spa)
	buf.Write(make([]byte, 6))
	buf.Write(tpa)
	return buf.Bytes()
}
