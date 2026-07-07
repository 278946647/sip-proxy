package traffic

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

var tunnelIfaces = map[string]struct{}{
	config.TunInterface: {},
	"ifb-gfc":           {},
}

// DiscoverMonitorIfaces returns interface names to sample each minute.
// When includeTunnel is false (direct mode), gfctun/ifb-gfc are skipped.
func DiscoverMonitorIfaces(includeTunnel bool) []string {
	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		if includeTunnel {
			return []string{config.TunInterface}
		}
		return nil
	}
	seen := map[string]struct{}{}
	var names []string
	for _, entry := range entries {
		name := entry.Name()
		if skipMonitorIface(name) {
			continue
		}
		if _, tunnel := tunnelIfaces[name]; tunnel && !includeTunnel {
			continue
		}
		if !hasIfaceStats(name) {
			continue
		}
		if _, ok := seen[name]; ok {
			continue
		}
		seen[name] = struct{}{}
		names = append(names, name)
	}
	sort.Strings(names)
	if len(names) == 0 && includeTunnel {
		return []string{config.TunInterface}
	}
	return names
}

func skipMonitorIface(name string) bool {
	if name == "lo" {
		return true
	}
	prefixes := []string{"docker", "veth", "dummy", "erspan", "gre", "gretap", "ip6tnl", "ip6gre", "sit"}
	for _, p := range prefixes {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	if strings.HasPrefix(name, "tun") && name != config.TunInterface {
		return true
	}
	return false
}

func hasIfaceStats(name string) bool {
	_, err := os.Stat(filepath.Join("/sys/class/net", name, "statistics", "rx_bytes"))
	return err == nil
}

// MergeIfaceNames returns sorted unique interface names.
func MergeIfaceNames(parts ...[]string) []string {
	seen := map[string]struct{}{}
	var out []string
	for _, list := range parts {
		for _, name := range list {
			name = strings.TrimSpace(name)
			if name == "" {
				continue
			}
			if _, ok := seen[name]; ok {
				continue
			}
			seen[name] = struct{}{}
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}
