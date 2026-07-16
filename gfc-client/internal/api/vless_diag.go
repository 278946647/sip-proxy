package api

import (
	"fmt"
	"net"
	"os/exec"
	"regexp"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/stats"
)

var (
	reProbeIPLabeled = regexp.MustCompile(`(?i)IP:\s*([0-9]{1,3}(?:\.[0-9]{1,3}){3})`)
	reProbeIPv4      = regexp.MustCompile(`\b([0-9]{1,3}(?:\.[0-9]{1,3}){3})\b`)
)

type vlessExpect struct {
	NodeIP       string
	SocksHost    string
	SocksIP      string
	OutboundMode string // socks | direct | unknown
	ExpectedIP   string
	AcceptIPs    []string
}

func (s *Server) diagnoseVLESS() map[string]any {
	tun := stats.TunStatus(config.TunInterface)
	exp := s.resolveVLESSExpect()
	egress, egErr, egSrc := probeEgressIP()
	direct, dirErr, dirSrc := probeDirectIP(s.cfg.WanIface)
	tunUp, _ := tun["up"].(bool)

	matchExpected := egress != "" && ipInList(egress, exp.AcceptIPs)
	wanLeak := direct != "" && egress != "" && egress == direct
	ok := matchExpected && tunUp && !wanLeak && egErr == nil

	conclusion := vlessConclusion(exp, egress, direct, tunUp, egErr, dirErr, matchExpected, wanLeak)
	note := "直联 IP 用国内站（WAN 绑口）；出口 IP 用境外站（默认路由走隧道）。" +
		"有 SOCKS 时期望出口为 SOCKS 配置 IP，空线路期望为转发节点公网 IP；" +
		"出口等于直联视为隧道未接管。"

	return map[string]any{
		"tun":             tun,
		"node_server_ip":  exp.NodeIP,
		"socks_host":      exp.SocksHost,
		"socks_ip":        exp.SocksIP,
		"outbound_mode":   exp.OutboundMode,
		"expected_ip":     exp.ExpectedIP,
		"accept_ips":      exp.AcceptIPs,
		"egress_ip":       egress,
		"direct_ip":       direct,
		"egress_source":   egSrc,
		"direct_source":   dirSrc,
		"match":           matchExpected,
		"wan_leak":        wanLeak,
		"ok":              ok,
		"conclusion":      conclusion,
		"egress_error":    errString(egErr),
		"direct_error":    errString(dirErr),
		"note":            note,
	}
}

func (s *Server) resolveVLESSExpect() vlessExpect {
	exp := vlessExpect{OutboundMode: "unknown"}
	exp.NodeIP = s.activeNodeServerIP()

	payload := s.engine.LoadBundle()
	if payload != nil {
		if outbound, _ := payload["outbound"].(map[string]any); outbound != nil {
			mode := strings.ToLower(strings.TrimSpace(fmt.Sprint(outbound["mode"])))
			if mode == "" || mode == "<nil>" {
				mode = "direct"
			}
			exp.OutboundMode = mode
			if mode == "socks" {
				host := strings.TrimSpace(fmt.Sprint(outbound["host"]))
				if host != "" && host != "<nil>" {
					exp.SocksHost = strings.Split(host, ":")[0]
					exp.SocksIP = resolveHostToIP(exp.SocksHost)
				}
			}
		} else {
			exp.OutboundMode = "direct"
		}
	}

	switch exp.OutboundMode {
	case "socks":
		if exp.SocksIP != "" {
			exp.ExpectedIP = exp.SocksIP
		} else if exp.NodeIP != "" {
			exp.ExpectedIP = exp.NodeIP
		}
	default:
		exp.ExpectedIP = exp.NodeIP
	}

	seen := map[string]struct{}{}
	for _, ip := range []string{exp.ExpectedIP, exp.SocksIP, exp.NodeIP} {
		ip = strings.TrimSpace(ip)
		if ip == "" {
			continue
		}
		if _, ok := seen[ip]; ok {
			continue
		}
		seen[ip] = struct{}{}
		exp.AcceptIPs = append(exp.AcceptIPs, ip)
	}
	return exp
}

func resolveHostToIP(host string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		return ""
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.String()
	}
	ips, err := net.LookupIP(host)
	if err != nil {
		return ""
	}
	for _, ip := range ips {
		if v4 := ip.To4(); v4 != nil {
			return v4.String()
		}
	}
	return ""
}

func ipInList(ip string, list []string) bool {
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return false
	}
	for _, x := range list {
		if strings.TrimSpace(x) == ip {
			return true
		}
	}
	return false
}

func vlessConclusion(
	exp vlessExpect,
	egress, direct string,
	tunUp bool,
	egErr, dirErr error,
	matchExpected, wanLeak bool,
) string {
	if len(exp.AcceptIPs) == 0 {
		return "未通过：未配置可用转发节点/SOCKS 出口 IP，无法比对"
	}
	if egErr != nil {
		return "未通过：隧道出口 IP 探测失败（" + egErr.Error() + "），代理开启时通常表示 VLESS/路由未就绪"
	}
	if !tunUp {
		return "未通过：gfctun 未就绪，请先启动 gfc-sing-box 与 gfc-routing"
	}
	if wanLeak {
		return "未通过：出口仍为 WAN 直连 IP（" + egress + "），国际流量未走 VLESS 隧道"
	}
	if matchExpected {
		why := "期望出口 " + exp.ExpectedIP
		if exp.OutboundMode == "socks" && exp.SocksIP != "" {
			why = "SOCKS " + exp.SocksIP
			if egress == exp.NodeIP && exp.NodeIP != exp.SocksIP {
				why = "转发节点 " + exp.NodeIP + "（SOCKS 配置 " + exp.SocksIP + "）"
			} else if egress == exp.SocksIP {
				why = "SOCKS " + exp.SocksIP
			}
		} else if egress == exp.NodeIP {
			why = "转发节点 " + exp.NodeIP
		}
		return "通过：出口 IP（" + egress + "）与 " + why + " 一致，VLESS 隧道已生效"
	}
	if egress != "" {
		msg := "未通过：出口 IP（" + egress + "）既非直联"
		if direct != "" {
			msg += "（" + direct + "）"
		}
		msg += "，也不匹配期望出口（" + strings.Join(exp.AcceptIPs, "/") + "）"
		if dirErr != nil {
			msg += "；直联探测失败：" + dirErr.Error()
		}
		return msg
	}
	if dirErr != nil {
		return "未通过：无法确认 WAN 直连 IP（" + dirErr.Error() + "）"
	}
	return "未通过：隧道状态异常，请查看 sing-box 日志"
}

func (s *Server) activeNodeServerIP() string {
	nodes, _ := s.store.ListNodes()
	for _, n := range nodes {
		if enabled, ok := n["enabled"].(bool); ok && !enabled {
			continue
		}
		for _, key := range []string{"server", "host", "address"} {
			if v := strings.TrimSpace(fmt.Sprint(n[key])); v != "" && v != "<nil>" {
				return resolveHostToIP(strings.Split(v, ":")[0])
			}
		}
	}
	if payload := s.engine.LoadBundle(); payload != nil {
		if node, _ := payload["node"].(map[string]any); node != nil {
			if addr := strings.TrimSpace(fmt.Sprint(node["address"])); addr != "" && addr != "<nil>" {
				return resolveHostToIP(strings.Split(addr, ":")[0])
			}
		}
	}
	return ""
}

// probeEgressIP uses international endpoints via default routing (proxy path).
func probeEgressIP() (ip string, err error, source string) {
	urls := []string{
		"https://ip.gs",
		"https://api.ipify.org",
		"https://ifconfig.me/ip",
	}
	return probePublicIP(urls, "", false)
}

// probeDirectIP uses China-reachable endpoints bound to WAN (must not traverse gfctun).
func probeDirectIP(wanIface string) (ip string, err error, source string) {
	wan := strings.TrimSpace(wanIface)
	if wan == "" {
		wan = "eth0"
	}
	urls := []string{
		"http://ip.3322.net",
		"http://members.3322.org/dyndns/getip",
		"http://ip.plus",
	}
	return probePublicIP(urls, wan, true)
}

func probePublicIP(urls []string, bindIface string, parseLabeled bool) (string, error, string) {
	var lastErr error
	for _, u := range urls {
		args := []string{"-fsS", "--max-time", "12", "-4"}
		if bindIface != "" {
			args = append(args, "--interface", bindIface)
		}
		args = append(args, u)
		out, err := exec.Command("curl", args...).CombinedOutput()
		if err != nil {
			lastErr = fmt.Errorf("%s: %w (%s)", u, err, strings.TrimSpace(string(out)))
			continue
		}
		ip := parsePublicIPBody(string(out), parseLabeled || strings.Contains(u, "ip.plus"))
		if ip == "" {
			lastErr = fmt.Errorf("%s: no public ip in response", u)
			continue
		}
		return ip, nil, u
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("all probes failed")
	}
	return "", lastErr, ""
}

func parsePublicIPBody(body string, allowLabeled bool) string {
	body = strings.TrimSpace(body)
	if body == "" {
		return ""
	}
	// Plain IP response (3322 etc.)
	if ip := net.ParseIP(strings.TrimSpace(strings.Split(body, "\n")[0])); ip != nil {
		if v4 := ip.To4(); v4 != nil && !v4.IsPrivate() && !v4.IsLoopback() {
			return v4.String()
		}
	}
	if allowLabeled {
		if m := reProbeIPLabeled.FindStringSubmatch(body); len(m) > 1 {
			if ip := net.ParseIP(m[1]); ip != nil {
				if v4 := ip.To4(); v4 != nil && !v4.IsPrivate() && !v4.IsLoopback() {
					return v4.String()
				}
			}
		}
	}
	// Fallback: first public IPv4 in body
	for _, m := range reProbeIPv4.FindAllStringSubmatch(body, -1) {
		if len(m) < 2 {
			continue
		}
		if ip := net.ParseIP(m[1]); ip != nil {
			if v4 := ip.To4(); v4 != nil && !v4.IsPrivate() && !v4.IsLoopback() {
				return v4.String()
			}
		}
	}
	return ""
}
