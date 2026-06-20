package stats

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func System() map[string]any {
	return map[string]any{
		"cpu_percent": cpuPercent(),
		"memory":      memoryStats(),
		"disk":        diskStats("/"),
		"go_routines": runtime.NumGoroutine(),
		"uptime_sec":  uptimeSeconds(),
	}
}

func TunStatus(iface string) map[string]any {
	if iface == "" {
		iface = config.TunInterface
	}
	ifaceObj, err := net.InterfaceByName(iface)
	if err != nil {
		return map[string]any{"name": iface, "up": false, "error": err.Error()}
	}
	addrs, _ := ifaceObj.Addrs()
	var ips []string
	for _, a := range addrs {
		ips = append(ips, a.String())
	}
	return map[string]any{
		"name":  iface,
		"up":    ifaceObj.Flags&net.FlagUp != 0,
		"mtu":   ifaceObj.MTU,
		"addrs": ips,
	}
}

func DNSProbe(host string, port int) map[string]any {
	if host == "" {
		host = "127.0.0.1"
	}
	if port == 0 {
		port = config.DefaultMosDNS
	}
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	conn, err := net.DialTimeout("udp", addr, 2*time.Second)
	if err != nil {
		return map[string]any{"addr": addr, "ok": false, "error": err.Error()}
	}
	_ = conn.Close()
	return map[string]any{"addr": addr, "ok": true}
}

func Singbox(clashURL string) map[string]any {
	if clashURL == "" {
		clashURL = "http://127.0.0.1:9090"
	}
	client := &http.Client{Timeout: 3 * time.Second}
	out := map[string]any{"controller": clashURL, "ok": false}

	resp, err := client.Get(clashURL + "/")
	if err != nil {
		out["error"] = err.Error()
		return out
	}
	defer resp.Body.Close()
	out["ok"] = resp.StatusCode == 200

	if traffic, err := fetchJSON(client, clashURL+"/traffic"); err == nil {
		out["traffic"] = traffic
	}
	if conns, err := fetchJSON(client, clashURL+"/connections"); err == nil {
		out["connections"] = conns
	}
	if mem, err := fetchJSON(client, clashURL+"/memory"); err == nil {
		out["memory"] = mem
	}
	return out
}

func MosDNS(logPath string, tailLines int) map[string]any {
	if logPath == "" {
		logPath = "/var/log/gfc-client/mosdns.log"
	}
	if tailLines <= 0 {
		tailLines = 500
	}
	lines, err := tailFile(logPath, tailLines)
	if err != nil {
		return map[string]any{"ok": false, "path": logPath, "error": err.Error()}
	}
	queries := 0
	var recent []string
	for _, line := range lines {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "query") || strings.Contains(lower, "question") {
			queries++
			recent = append(recent, line)
			if len(recent) > 20 {
				recent = recent[1:]
			}
		}
	}
	return map[string]any{
		"ok":            true,
		"path":          logPath,
		"recent_lines":  len(lines),
		"query_lines":   queries,
		"recent_sample": recent,
	}
}

func AgentStatus(cfg *config.Config) map[string]any {
	state := readJSON(cfg.Paths.StateFile)
	bundleVer := ""
	if data, err := os.ReadFile(cfg.Paths.ConfigBundle); err == nil {
		var b map[string]any
		if json.Unmarshal(data, &b) == nil {
			bundleVer = "present"
		}
	}
	applied := ""
	if v, ok := state["applied_version"].(string); ok {
		applied = v
	}
	status := readJSON(cfg.Paths.StatusFile)
	metrics, _ := status["metrics"].(map[string]any)
	return map[string]any{
		"version":          config.Version,
		"applied_version":  applied,
		"bundle":           bundleVer,
		"agent_state":      metrics["agent_state"],
		"control_plane":    metrics["control_plane_url"],
		"cp_reachable":     metrics["control_plane_reachable"],
		"proxy_mode":       cfg.ProxyMode,
		"poll_seconds":     cfg.PollSeconds,
		"backup_generations": config.BackupGenerations,
	}
}

func CollectExtended(cfg *config.Config, controlPlaneURL string, reachable bool) map[string]any {
	hostname, _ := os.Hostname()
	m := map[string]any{
		"ts":                      time.Now().UTC().Format(time.RFC3339),
		"hostname":                hostname,
		"agent_version":           config.Version,
		"control_plane_url":       controlPlaneURL,
		"control_plane_reachable": reachable,
		"proxy_mode":              cfg.ProxyMode,
		"system":                  System(),
		"tun":                     TunStatus(config.TunInterface),
		"dns":                     DNSProbe("127.0.0.1", config.DefaultMosDNS),
	}
	if addrs, err := net.InterfaceAddrs(); err == nil {
		var ips []string
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok && ipnet.IP.To4() != nil {
				ips = append(ips, ipnet.IP.String())
			}
		}
		m["ips"] = ips
	}
	return m
}

func fetchJSON(client *http.Client, url string) (map[string]any, error) {
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return map[string]any{"raw": string(body)}, nil
	}
	return out, nil
}

func readJSON(path string) map[string]any {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]any{}
	}
	var m map[string]any
	if json.Unmarshal(data, &m) != nil {
		return map[string]any{}
	}
	return m
}

func tailFile(path string, n int) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		// easymosdns may log beside config
		alt := filepath.Join(filepath.Dir(path), "mosdns.log")
		if alt != path {
			return tailFile(alt, n)
		}
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

func cpuPercent() float64 {
	idle0, total0 := readCPUStat()
	time.Sleep(200 * time.Millisecond)
	idle1, total1 := readCPUStat()
	if total1 <= total0 {
		return 0
	}
	idle := float64(idle1 - idle0)
	total := float64(total1 - total0)
	return (1 - idle/total) * 100
}

func readCPUStat() (idle, total uint64) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0
	}
	line := strings.Split(string(data), "\n")[0]
	fields := strings.Fields(line)
	if len(fields) < 5 || fields[0] != "cpu" {
		return 0, 0
	}
	for i := 1; i < len(fields); i++ {
		v, _ := strconv.ParseUint(fields[i], 10, 64)
		total += v
		if i == 4 {
			idle = v
		}
	}
	return idle, total
}

func memoryStats() map[string]any {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	vals := map[string]uint64{}
	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}
		key := strings.TrimSuffix(parts[0], ":")
		v, _ := strconv.ParseUint(parts[1], 10, 64)
		vals[key] = v * 1024
	}
	total := vals["MemTotal"]
	avail := vals["MemAvailable"]
	used := total - avail
	pct := 0.0
	if total > 0 {
		pct = float64(used) / float64(total) * 100
	}
	return map[string]any{
		"total_bytes": total, "used_bytes": used, "available_bytes": avail,
		"used_percent": pct,
	}
}

func diskStats(mount string) map[string]any {
	out, err := exec.Command("df", "-B1", mount).Output()
	if err != nil {
		return diskStatsKiB(mount, err.Error())
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) < 2 {
		return map[string]any{"mount": mount}
	}
	fields := strings.Fields(lines[1])
	if len(fields) < 6 {
		return map[string]any{"mount": mount}
	}
	total, _ := strconv.ParseUint(fields[1], 10, 64)
	used, _ := strconv.ParseUint(fields[2], 10, 64)
	pctStr := strings.TrimSuffix(fields[4], "%")
	pct, _ := strconv.ParseFloat(pctStr, 64)
	return map[string]any{
		"mount": mount, "total_bytes": total, "used_bytes": used, "used_percent": pct,
	}
}

func diskStatsKiB(mount string, fallbackErr string) map[string]any {
	out, err := exec.Command("df", "-k", mount).Output()
	if err != nil {
		return map[string]any{"mount": mount, "error": fallbackErr}
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) < 2 {
		return map[string]any{"mount": mount}
	}
	fields := strings.Fields(lines[1])
	if len(fields) < 5 {
		return map[string]any{"mount": mount}
	}
	totalKiB, _ := strconv.ParseUint(fields[1], 10, 64)
	usedKiB, _ := strconv.ParseUint(fields[2], 10, 64)
	pctStr := strings.TrimSuffix(fields[4], "%")
	pct, _ := strconv.ParseFloat(pctStr, 64)
	return map[string]any{
		"mount": mount, "total_bytes": totalKiB * 1024, "used_bytes": usedKiB * 1024, "used_percent": pct,
	}
}

func uptimeSeconds() float64 {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(fields[0], 64)
	return v
}
