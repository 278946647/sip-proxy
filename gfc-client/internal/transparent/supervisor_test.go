package transparent

import (
	"net"
	"testing"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func TestNotifyGatewayDoesNotHoldLockDuringStop(t *testing.T) {
	s := NewSupervisor(nil)
	s.mu.Lock()
	s.stop = func() {
		s.mu.Lock()
		s.mu.Unlock()
	}
	s.last = "eth1|eth2"
	s.mu.Unlock()

	done := make(chan struct{})
	go func() {
		s.Notify("gateway")
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Notify deadlocked: capture stop ran while supervisor lock was held")
	}
}

func TestRefreshDebounceIs200ms(t *testing.T) {
	if refreshDebounce > 200*time.Millisecond {
		t.Fatalf("identity apply debounce must be ≤200ms, got %s", refreshDebounce)
	}
}

func TestSupervisorHoldSpareUntilFirstFrame(t *testing.T) {
	dir := t.TempDir()
	cfg := &config.Config{Paths: config.Paths{Etc: dir}}
	if err := SaveSpare(cfg, SpareConfig{IP: "192.168.33.250", Prefix: 32}); err != nil {
		t.Fatal(err)
	}
	s := NewSupervisor(cfg)
	s.boxMAC = func(string) string { return "00:e2:69:1b:31:60" }
	s.debounce = time.Hour
	s.mu.Lock()
	s.stop = func() {}
	s.last = "eth0|eth1"
	s.learned = Learned{LearnedCustomer: true, CEIP: "192.168.33.129", CPEMAC: "00:0c:29:3f:73:22", GWIP: "192.168.33.2"}
	s.cpeDown = true
	s.holdSpareUntilFrame = true
	ports := Ports{ISP: "eth0", CPE: "eth1"}
	if got := s.currentHitchLocked(ports); got.Mode != HitchModeSpare {
		s.mu.Unlock()
		t.Fatalf("down must be B: %+v", got)
	}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		if s.timer != nil {
			s.timer.Stop()
			s.timer = nil
		}
		s.stop = nil
		s.mu.Unlock()
	}()

	s.applyCPEDown(false)
	s.mu.Lock()
	if !s.holdSpareUntilFrame {
		s.mu.Unlock()
		t.Fatal("replug must hold spare until first frame")
	}
	if got := s.currentHitchLocked(ports); got.Mode != HitchModeSpare {
		s.mu.Unlock()
		t.Fatalf("hold until frame: %+v", got)
	}
	s.mu.Unlock()

	ceMAC := []byte{0x00, 0x0c, 0x29, 0x3f, 0x73, 0x22}
	ce := net.IPv4(192, 168, 33, 129).To4()
	gw := net.IPv4(192, 168, 33, 2).To4()
	s.onFrame(RoleCPE, arpFrame(ceMAC, ce, gw, arpOpRequest))
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.holdSpareUntilFrame {
		t.Fatal("first frame must clear hold")
	}
	if got := s.currentHitchLocked(ports); got.Mode != HitchModeCE || got.IP != "192.168.33.129" {
		t.Fatalf("switchback A: %+v", got)
	}
}
