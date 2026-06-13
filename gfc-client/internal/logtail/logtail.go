package logtail

import (
	"bufio"
	"os"
	"path/filepath"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

var logFiles = map[string]string{
	"agent":    "gfc-agent.log",
	"sing-box": "sing-box.log",
	"mosdns":   "mosdns.log",
	"api":      "gfc-api.log",
}

func Tail(cfg *config.Config, service string, lines int) map[string]any {
	if lines <= 0 {
		lines = 200
	}
	if lines > 2000 {
		lines = 2000
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
