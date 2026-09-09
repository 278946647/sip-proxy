package transparent

import (
	"testing"
	"time"
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
