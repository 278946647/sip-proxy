package logtail

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

var logFiles = map[string]string{
	"agent":    "gfc-agent.log",
	"sing-box": "sing-box.log",
	"mosdns":   "mosdns.log",
	"api":      "gfc-api.log",
	"web":      "gfc-api.log",
}

func Tail(cfg *config.Config, service string, lines int) map[string]any {
	if lines <= 0 {
		lines = 200
	}
	if lines > 2000 {
		lines = 2000
	}
	if platform.IsOpenWrt() {
		return tailLogread(service, lines)
	}
	name, ok := logFiles[service]
	if !ok {
		return map[string]any{"error": "unknown service", "lines": []string{}}
	}
	path := filepath.Join(cfg.Paths.Log, name)
	content, err := tailFile(path, lines)
	if err != nil {
		return map[string]any{"service": service, "path": path, "error": err.Error(), "lines": []string{}}
	}
	return map[string]any{"service": service, "path": path, "lines": content}
}

func tailLogread(service string, lines int) map[string]any {
	args := []string{"-l", intString(lines)}
	out, err := exec.Command("logread", args...).CombinedOutput()
	if err != nil {
		return map[string]any{"service": service, "source": "logread", "error": strings.TrimSpace(string(out)), "lines": []string{}}
	}
	all := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	unit, _ := platform.LogicalService(service)
	unit = strings.TrimSuffix(unit, ".service")
	if unit != "" {
		filtered := make([]string, 0, len(all))
		for _, line := range all {
			if strings.Contains(line, unit) || strings.Contains(line, service) {
				filtered = append(filtered, line)
			}
		}
		if len(filtered) > 0 {
			all = filtered
		}
	}
	return map[string]any{"service": service, "source": "logread", "lines": all}
}

func intString(n int) string {
	if n <= 0 {
		return "200"
	}
	return strconv.Itoa(n)
}

func tailFile(path string, n int) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var ring []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		ring = append(ring, sc.Text())
		if len(ring) > n {
			ring = ring[1:]
		}
	}
	return ring, sc.Err()
}
