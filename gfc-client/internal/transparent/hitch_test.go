package transparent

import (
	"net"
	"testing"
)

func TestComputeHitchPlanAWhenCPEUp(t *testing.T) {
	got := ComputeHitch(HitchInput{
		Learned: Learned{
			LearnedCustomer: true,
			CEIP:            "192.168.33.129",
			CPEMAC:          "00:0c:29:3f:73:22",
			PEMAC:           "00:50:56:f0:a2:68",
			GWIP:            "192.168.33.2",
		},
		Spare:  SpareConfig{IP: "192.168.33.250", Prefix: 32, Gateway: "192.168.33.2"},
		BoxMAC: "00:e2:69:1b:31:60",
	})
	if got.Mode != HitchModeCE || got.IP != "192.168.33.129" || got.SrcMAC != "00:0c:29:3f:73:22" {
		t.Fatalf("Plan A identity: %+v", got)
	}
}

func TestComputeHitchPlanBWhenCPEDown(t *testing.T) {
	got := ComputeHitch(HitchInput{
		Learned: Learned{
			LearnedCustomer: true,
			CEIP:            "192.168.33.129",
			CPEMAC:          "00:0c:29:3f:73:22",
			PEMAC:           "00:50:56:f0:a2:68",
			GWIP:            "192.168.33.2",
		},
		Spare:   SpareConfig{IP: "192.168.33.250", Prefix: 32, Gateway: "192.168.33.2"},
		CPEDown: true,
		BoxMAC:  "00:e2:69:1b:31:60",
	})
	if got.Mode != HitchModeSpare || got.IP != "192.168.33.250" || got.SrcMAC != "00:e2:69:1b:31:60" {
		t.Fatalf("Plan B identity: %+v", got)
	}
	if got.GWIP != "192.168.33.2" || got.PEMAC != "00:50:56:f0:a2:68" {
		t.Fatalf("Plan B must keep learned GW/PE: %+v", got)
	}
}

func TestComputeHitchPlanBNeverLearned(t *testing.T) {
	got := ComputeHitch(HitchInput{
		Spare:  SpareConfig{IP: "192.168.33.250"},
		BoxMAC: "00:e2:69:1b:31:60",
	})
	if got.Mode != HitchModeSpare || got.IP != "192.168.33.250" {
		t.Fatalf("never-learned must use spare: %+v", got)
	}
}

func TestComputeHitchHoldUntilFirstFrame(t *testing.T) {
	in := HitchInput{
		Learned: Learned{
			LearnedCustomer: true,
			CEIP:            "192.168.33.129",
			CPEMAC:          "00:0c:29:3f:73:22",
		},
		Spare:               SpareConfig{IP: "192.168.33.250"},
		HoldSpareUntilFrame: true,
		BoxMAC:              "00:e2:69:1b:31:60",
	}
	got := ComputeHitch(in)
	if got.Mode != HitchModeSpare {
		t.Fatalf("hold after replug must stay B until first frame: %+v", got)
	}
	in.HoldSpareUntilFrame = false
	got = ComputeHitch(in)
	if got.Mode != HitchModeCE || got.IP != "192.168.33.129" {
		t.Fatalf("first frame must switch back to A: %+v", got)
	}
}

func TestComputeHitchNoSpareStaysCEWhenDown(t *testing.T) {
	got := ComputeHitch(HitchInput{
		Learned: Learned{LearnedCustomer: true, CEIP: "192.168.33.129", CPEMAC: "00:0c:29:3f:73:22"},
		CPEDown: true,
	})
	if got.Mode != HitchModeCE || got.IP != "192.168.33.129" {
		t.Fatalf("unconfigured spare must not invent B: %+v", got)
	}
}

func TestShouldAnswerCEARPWithSpareNeverGuesses(t *testing.T) {
	st := Learned{State: StateISPOnly, LearnedCustomer: false}
	if !ShouldAnswerCEARP(st) {
		t.Fatal("no spare: isp_only may still answer CE")
	}
	if ShouldAnswerCEARPWithSpare(st, SpareConfig{IP: "192.168.33.250"}) {
		t.Fatal("spare configured: must not answer a guessed CE")
	}
}

func TestValidateSpareRejectsLAN(t *testing.T) {
	if err := ValidateSpare(SpareConfig{IP: "192.168.68.9"}, "192.168.68.0/24"); err == nil {
		t.Fatal("spare on management LAN")
	}
	if err := ValidateSpare(SpareConfig{}, "192.168.68.0/24"); err != nil {
		t.Fatal(err)
	}
	if err := ValidateSpare(SpareConfig{IP: "192.168.33.250", Prefix: 32, Gateway: "192.168.33.2"}, "192.168.68.0/24"); err != nil {
		t.Fatal(err)
	}
}

func TestApplySpareARPLearnsPE(t *testing.T) {
	st := &Learned{}
	peMAC := []byte{0x00, 0x50, 0x56, 0xf0, 0xa2, 0x68}
	gw := net.IPv4(192, 168, 33, 2).To4()
	spare := net.IPv4(192, 168, 33, 250).To4()
	ApplySpareARP(RoleISP, arpFrame(peMAC, gw, spare, arpOpRequest), st, SpareConfig{IP: "192.168.33.250", Gateway: "192.168.33.2"})
	if st.GWIP != "192.168.33.2" || st.PEMAC != "00:50:56:f0:a2:68" {
		t.Fatalf("spare who-has must learn PE/GW: %+v", st)
	}
}

func TestFrameUsableHitchHost(t *testing.T) {
	cpeMAC := []byte{0x02, 0x00, 0x00, 0x00, 0x00, 0x01}
	ce := net.IPv4(10, 50, 0, 2).To4()
	gw := net.IPv4(10, 50, 0, 1).To4()
	if !frameUsableHitchHost(arpFrame(cpeMAC, ce, gw, arpOpRequest), "10.50.0.1") {
		t.Fatal("CE ARP must count as first frame")
	}
	if frameUsableHitchHost(arpFrame(cpeMAC, gw, ce, arpOpRequest), "10.50.0.1") {
		t.Fatal("GW source must not count as a hitch host")
	}
}
