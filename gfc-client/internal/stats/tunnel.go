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

	out := map[string]any{
		"iface":           iface,
		"window_seconds":  windowSeconds,
		"bytes_in":        uint64(0),
		"bytes_out":       uint64(0),
		"active_conns":    0,
		"cumulative_rx":   rx,
		"cumulative_tx":   tx,
	}
	if tunnelSampler.hasLast {
		if rx >= tunnelSampler.lastRx {
			out["bytes_in"] = rx - tunnelSampler.lastRx
		}
		if tx >= tunnelSampler.lastTx {
			out["bytes_out"] = tx - tunnelSampler.lastTx
		}
	}
	tunnelSampler.lastRx = rx
	tunnelSampler.lastTx = tx
	tunnelSampler.lastAt = time.Now()
	tunnelSampler.hasLast = true
	return out
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
