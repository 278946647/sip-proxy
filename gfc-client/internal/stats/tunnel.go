package stats

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

// tunnelGapResetSeconds ignores deltas after long heartbeat gaps (offline/restart).
const tunnelGapResetSeconds = 120

var tunnelSampler = &tunnelCounter{}

type tunnelCounter struct {
	mu      sync.Mutex
	lastRx  uint64
	lastTx  uint64
	lastAt  time.Time
	hasLast bool
}

func SampleTunnel(iface string, windowSeconds int) map[string]any {
	if iface == "" {
		iface = config.TunInterface
	}
	if windowSeconds <= 0 {
		windowSeconds = 10
	}
	rx, tx, ok := ifaceBytes(iface)
	if !ok {
		return nil
	}

	tunnelSampler.mu.Lock()
	defer tunnelSampler.mu.Unlock()

	now := time.Now()
	bytesIn, bytesOut, windowSec, gapReset := tunnelSampleDelta(
		tunnelSampler.lastRx, tunnelSampler.lastTx, tunnelSampler.lastAt, tunnelSampler.hasLast,
		rx, tx, now, time.Duration(tunnelGapResetSeconds)*time.Second,
	)
	if gapReset {
		tunnelSampler.lastRx = rx
		tunnelSampler.lastTx = tx
		tunnelSampler.lastAt = now
		tunnelSampler.hasLast = true
	} else if tunnelSampler.hasLast {
		tunnelSampler.lastRx = rx
		tunnelSampler.lastTx = tx
		tunnelSampler.lastAt = now
	} else {
		tunnelSampler.lastRx = rx
		tunnelSampler.lastTx = tx
		tunnelSampler.lastAt = now
		tunnelSampler.hasLast = true
	}

	if windowSec <= 0 {
		windowSec = windowSeconds
	}

	return map[string]any{
		"iface":          iface,
		"window_seconds": windowSec,
		"bytes_in":       bytesIn,
		"bytes_out":      bytesOut,
		"active_conns":   0,
		"cumulative_rx":  rx,
		"cumulative_tx":  tx,
	}
}

// tunnelSampleDelta computes byte deltas and the real sampling window.
// After gapReset is true the caller should refresh baselines without recording traffic.
func tunnelSampleDelta(
	lastRx, lastTx uint64,
	lastAt time.Time,
	hasLast bool,
	rx, tx uint64,
	now time.Time,
	gapResetAfter time.Duration,
) (bytesIn, bytesOut uint64, windowSec int, gapReset bool) {
	if !hasLast {
		return 0, 0, 0, false
	}

	elapsed := now.Sub(lastAt)
	if elapsed < time.Second {
		elapsed = time.Second
	}
	if gapResetAfter > 0 && elapsed > gapResetAfter {
		return 0, 0, int(elapsed.Seconds()), true
	}

	windowSec = int(elapsed.Seconds())
	if windowSec < 1 {
		windowSec = 1
	}
	if rx >= lastRx {
		bytesIn = rx - lastRx
	}
	if tx >= lastTx {
		bytesOut = tx - lastTx
	}
	return bytesIn, bytesOut, windowSec, false
}

func ResetTunnelSampler() {
	tunnelSampler.mu.Lock()
	defer tunnelSampler.mu.Unlock()
	tunnelSampler.hasLast = false
	tunnelSampler.lastRx = 0
	tunnelSampler.lastTx = 0
	tunnelSampler.lastAt = time.Time{}
}

func ifaceBytes(iface string) (rx, tx uint64, ok bool) {
	return IfaceBytes(iface)
}

// IfaceBytes reads cumulative rx/tx byte counters from sysfs.
func IfaceBytes(iface string) (rx, tx uint64, ok bool) {
	read := func(name string) (uint64, bool) {
		data, err := os.ReadFile(filepath.Join("/sys/class/net", iface, "statistics", name))
		if err != nil {
			return 0, false
		}
		v, err := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
		if err != nil {
			return 0, false
		}
		return v, true
	}
	rx, ok1 := read("rx_bytes")
	tx, ok2 := read("tx_bytes")
	return rx, tx, ok1 && ok2
}
