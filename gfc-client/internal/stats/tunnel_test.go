package stats

import (
	"testing"
	"time"
)

func TestTunnelSampleDeltaFirstSample(t *testing.T) {
	in, out, sec, reset := tunnelSampleDelta(0, 0, time.Time{}, false, 100, 200, time.Now(), 2*time.Minute)
	if in != 0 || out != 0 || sec != 0 || reset {
		t.Fatalf("first sample: in=%d out=%d sec=%d reset=%v", in, out, sec, reset)
	}
}

func TestTunnelSampleDeltaNormalWindow(t *testing.T) {
	lastAt := time.Now().Add(-5 * time.Second)
	in, out, sec, reset := tunnelSampleDelta(1000, 2000, lastAt, true, 1600, 2500, time.Now(), 2*time.Minute)
	if reset {
		t.Fatal("expected no gap reset")
	}
	if in != 600 || out != 500 {
		t.Fatalf("delta: in=%d out=%d", in, out)
	}
	if sec < 4 || sec > 6 {
		t.Fatalf("window sec=%d want ~5", sec)
	}
}

func TestTunnelSampleDeltaGapReset(t *testing.T) {
	lastAt := time.Now().Add(-10 * time.Minute)
	in, out, sec, reset := tunnelSampleDelta(1000, 2000, lastAt, true, 1_000_000, 2_000_000, time.Now(), 2*time.Minute)
	if !reset {
		t.Fatal("expected gap reset")
	}
	if in != 0 || out != 0 {
		t.Fatalf("gap reset should drop delta: in=%d out=%d", in, out)
	}
	if sec < 500 {
		t.Fatalf("window sec=%d", sec)
	}
}

func TestTunnelSampleDeltaCounterRegression(t *testing.T) {
	lastAt := time.Now().Add(-3 * time.Second)
	in, out, _, reset := tunnelSampleDelta(5000, 5000, lastAt, true, 1000, 1000, time.Now(), 2*time.Minute)
	if reset {
		t.Fatal("unexpected gap reset")
	}
	if in != 0 || out != 0 {
		t.Fatalf("counter regression should yield zero delta: in=%d out=%d", in, out)
	}
}
