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
