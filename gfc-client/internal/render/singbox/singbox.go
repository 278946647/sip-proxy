package singbox

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

var domesticDNS = []string{
	"223.5.5.5/32", "223.6.6.6/32", "119.29.29.29/32", "114.114.114.114/32",
}

// Default international DNS IPs: always via proxy-prefer (VLESS).
var intlDNS = []string{
	"1.1.1.1/32", "1.0.0.1/32", "8.8.8.8/32", "8.8.4.4/32",
}

const preferProxyTag = "proxy-prefer"
const hy2ProxyTag = "proxy-hy2"
const liveModeStandard = "standard"
const liveModeAllHy2 = "live_all_hy2"

type Renderer struct {
	cfg *config.Config
}

func NewRenderer(cfg *config.Config) *Renderer {
	return &Renderer{cfg: cfg}
}

func (r *Renderer) LogLevel() string {
	level := strings.TrimSpace(os.Getenv("GFC_SINGBOX_LOG_LEVEL"))
	if level == "" {
		return "error"
	}
	return level
}

func (r *Renderer) RoutingMode() string {
	data, err := os.ReadFile(r.cfg.Paths.RoutingModeFile)
	if err != nil {
		return "split"
	}
	var m map[string]string
	if json.Unmarshal(data, &m) == nil {
		if mode := strings.ToLower(strings.TrimSpace(m["mode"])); mode != "" {
			return mode
		}
	}
	return "split"
}

func (r *Renderer) RoutingScheme() string {
	scheme := strings.ToLower(strings.TrimSpace(os.Getenv("GFC_ROUTING_SCHEME")))
	if scheme == "" {
		return "kernel-split"
	}
	return scheme
}

func (r *Renderer) SelectedOutbound() string {
	data, err := os.ReadFile(r.cfg.Paths.PolicySelFile)
	if err != nil {
		return "proxy"
	}
	var m map[string]string
	if json.Unmarshal(data, &m) == nil {
		if s := strings.TrimSpace(m["selected"]); s != "" {
			return s
		}
	}
	return "proxy"
}

func (r *Renderer) IdleConfig() map[string]any {
	logBlock := map[string]any{"level": r.LogLevel()}
	return map[string]any{
		"log":       logBlock,
		"inbounds":  []any{},
		"outbounds": []any{map[string]any{"type": "direct", "tag": "direct"}},
		"route":     map[string]any{"final": "direct"},
	}
}

func (r *Renderer) RenderActive(payload map[string]any, ruleSets []map[string]any) (map[string]any, error) {
	node, _ := payload["node"].(map[string]any)
	vless, _ := payload["vless"].(map[string]any)
	if node == nil || vless == nil {
		return nil, fmt.Errorf("invalid config payload")
	}
	address, _ := node["address"].(string)
	address = strings.TrimSpace(address)
	if address == "" {
		return nil, fmt.Errorf("node address missing")
	}
	uuid, _ := vless["uuid"].(string)
	uuid = strings.TrimSpace(uuid)
	if uuid == "" {
		return nil, fmt.Errorf("vless uuid missing")
	}
	port := 8443
	if p, ok := node["port"].(float64); ok {
		port = int(p)
	}

	proxyMode := strings.ToLower(strings.TrimSpace(fmt.Sprint(payload["proxyMode"])))
	if proxyMode == "" {
		proxyMode = r.cfg.ProxyMode
	}
	scheme := r.RoutingScheme()

	wan := r.resolveWanIface()
	if wan == "" {
		return nil, fmt.Errorf("WAN interface unknown — set GFC_WAN_IFACE in gfc.env and run apply-network.sh")
	}
	directLocal := map[string]any{"type": "direct", "tag": "direct-local"}
	direct := map[string]any{"type": "direct", "tag": "direct", "bind_interface": wan}

	nodeTag := "proxy"
	var outbounds []any
	if scheme != "byst-redirect" {
		outbounds = append(outbounds, directLocal, direct)
	}
	proxyOutbound := nodeTag

	// optional extra nodes from payload
	nodeTags := []string{nodeTag}
	if nodes, ok := payload["nodes"].([]any); ok && len(nodes) > 0 {
		nodeTags = nil
		for i, n := range nodes {
			nm, ok := n.(map[string]any)
			if !ok {
				continue
			}
			tag := fmt.Sprintf("node-%v", nm["id"])
			if i == 0 {
				tag = nodeTag
			}
			ob := buildVLESSOutbound(nm, tag, wan)
			if ob != nil {
				outbounds = append(outbounds, ob)
				nodeTags = append(nodeTags, tag)
			}
		}
	} else {
		outbounds = append(outbounds, buildVLESSFromPayload(address, port, vless, nodeTag, wan))
	}

	if len(nodeTags) > 1 {
		selected := r.SelectedOutbound()
		if selected == "" {
			selected = nodeTag
		}
		outbounds = append(outbounds, map[string]any{
			"type": "selector", "tag": "proxy-group", "outbounds": nodeTags, "default": selected,
		})
		proxyOutbound = "proxy-group"
	}

	// TUN/international traffic: standard → proxy-prefer (VLESS urltest);
	// live_all_hy2 → proxy-hy2 directly (no urltest).
	preferTag := preferProxyTag
	liveMode := normalizeLiveMode(payload["liveMode"])
	hy2Payload, _ := payload["hysteria2"].(map[string]any)
	hy2Port := 18443
	if p, ok := node["hy2Port"].(float64); ok && int(p) > 0 {
		hy2Port = int(p)
	}
	// Insert proxy-hy2 before proxy-prefer (and before optional proxy-group already appended).
	hy2Outbound := buildHysteria2FromPayload(address, hy2Port, hy2Payload, wan)
	if hy2Outbound != nil {
		// Keep order: … proxy [| proxy-group] → proxy-hy2 → proxy-prefer
		outbounds = append(outbounds, hy2Outbound)
	}

	if scheme != "byst-redirect" {
		outbounds = append(outbounds, preferProxyGroup(proxyOutbound))
	} else {
		preferTag = proxyOutbound
	}

	intlTag := preferTag
	if liveMode == liveModeAllHy2 {
		if hy2Outbound == nil {
			return nil, fmt.Errorf("live_all_hy2 requires hysteria2 credentials in bundle")
		}
		intlTag = hy2ProxyTag
	}

	inbounds := r.buildInbounds(proxyMode)
	routingMode := r.RoutingMode()

	var routeRules []map[string]any
	var activeRuleSets []map[string]any
	finalOutbound := "direct"
	if scheme == "byst-redirect" {
		// BYST-compatible dataplane: nft decides split/redirect, sing-box only carries traffic out.
		routeRules = []map[string]any{}
		finalOutbound = proxyOutbound
		if liveMode == liveModeAllHy2 && hy2Outbound != nil {
			finalOutbound = hy2ProxyTag
		}
	} else if scheme == "kernel-split" {
		// CN/intl split is done in kernel nft. Inside TUN:
		// bypass_ip → direct; intl DNS + other → prefer/hy2; final → direct.
		routeRules = r.preferProxyRouteRules(address, payload, intlTag, true)
	} else {
		routeRules = r.preferProxyRouteRules(address, payload, intlTag, false)
		if routingMode != "global" {
			activeRuleSets = ruleSets
			r.appendSplitRules(&routeRules, len(ruleSets) > 0, intlTag)
		}
		// Other traffic uses selected international outbound.
		routeRules = append(routeRules, map[string]any{"outbound": intlTag})
	}

	route := map[string]any{
		"auto_detect_interface": false,
		"default_interface":     wan,
		"final":                 finalOutbound,
	}
	if len(routeRules) > 0 {
		route["rules"] = routeRules
	}
	if len(activeRuleSets) > 0 {
		route["rule_set"] = activeRuleSets
	}

	logBlock := map[string]any{"level": r.LogLevel()}
	if lvl := r.LogLevel(); lvl == "info" || lvl == "debug" || lvl == "warn" {
		logBlock["timestamp"] = true
	}

	rendered := map[string]any{
		"log":       logBlock,
		"inbounds":  inbounds,
		"outbounds": outbounds,
		"route":     route,
	}
	if scheme != "byst-redirect" {
		rendered["experimental"] = map[string]any{
			"cache_file": map[string]any{"enabled": false},
			"clash_api": map[string]any{
				"external_controller": "127.0.0.1:9090",
				"secret":              "",
			},
		}
	}
	return rendered, nil
}

func (r *Renderer) resolveWanIface() string {
	if w := strings.TrimSpace(r.cfg.ResolvedWanIface()); w != "" {
		return w
	}
	return detectDefaultInterface()
}

func detectDefaultInterface() string {
	if dev := ifaceFromRouteOutput(runIPRoute("ip", "-4", "route", "show", "default")); dev != "" {
		return dev
	}
	for _, dst := range []string{"1.1.1.1", "8.8.8.8"} {
		if dev := ifaceFromRouteOutput(runIPRoute("ip", "-4", "route", "get", dst)); dev != "" {
			return dev
		}
	}
	return ""
}

func runIPRoute(args ...string) string {
	out, err := exec.Command(args[0], args[1:]...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func ifaceFromRouteOutput(line string) string {
	if line == "" {
		return ""
	}
	fields := strings.Fields(line)
	for i := 0; i < len(fields)-1; i++ {
		if fields[i] == "dev" {
			return fields[i+1]
		}
	}
	return ""
}

func buildVLESSFromPayload(address string, port int, vless map[string]any, tag, wan string) map[string]any {
	flow, _ := vless["flow"].(string)
	if flow == "" {
		flow = "xtls-rprx-vision"
	}
	sni, _ := vless["serverName"].(string)
	if sni == "" {
		sni = "www.cloudflare.com"
	}
	pk, _ := vless["publicKey"].(string)
	sid, _ := vless["shortId"].(string)
	ob := map[string]any{
		"type":            "vless",
		"tag":             tag,
		"server":          address,
		"server_port":     port,
		"uuid":            vless["uuid"],
		"flow":            flow,
		"bind_interface":  wan,
		"tls": map[string]any{
			"enabled":     true,
			"server_name": sni,
			"utls":        map[string]any{"enabled": true, "fingerprint": "chrome"},
			"reality": map[string]any{
				"enabled":    true,
				"public_key": pk,
				"short_id":   sid,
			},
		},
	}
	return ob
}

func normalizeLiveMode(raw any) string {
	mode := strings.ToLower(strings.TrimSpace(fmt.Sprint(raw)))
	switch mode {
	case liveModeAllHy2, "live_catalog":
		return mode
	default:
		return liveModeStandard
	}
}

func buildHysteria2FromPayload(address string, port int, hy2 map[string]any, wan string) map[string]any {
	if hy2 == nil {
		return nil
	}
	password, _ := hy2["password"].(string)
	password = strings.TrimSpace(password)
	if password == "" || strings.TrimSpace(address) == "" {
		return nil
	}
	sni, _ := hy2["serverName"].(string)
	if sni == "" {
		sni = "www.cloudflare.com"
	}
	insecure := true
	if v, ok := hy2["insecure"].(bool); ok {
		insecure = v
	}
	up := 0
	down := 0
	if v, ok := hy2["upMbps"].(float64); ok {
		up = int(v)
	}
	if v, ok := hy2["downMbps"].(float64); ok {
		down = int(v)
	}
	ob := map[string]any{
		"type":           "hysteria2",
		"tag":            hy2ProxyTag,
		"server":         address,
		"server_port":    port,
		"password":       password,
		"bind_interface": wan,
		"tls": map[string]any{
			"enabled":     true,
			"server_name": sni,
			"insecure":    insecure,
		},
	}
	if up > 0 {
		ob["up_mbps"] = up
	}
	if down > 0 {
		ob["down_mbps"] = down
	}
	if sal, _ := hy2["salamander"].(bool); sal {
		salPass, _ := hy2["salamanderPassword"].(string)
		salPass = strings.TrimSpace(salPass)
		if salPass != "" {
			ob["obfs"] = map[string]any{"type": "salamander", "password": salPass}
		}
	}
	return ob
}

func buildVLESSOutbound(nm map[string]any, tag, wan string) map[string]any {
	vless, _ := nm["vless"].(map[string]any)
	if vless == nil {
		vless = nm
	}
	addr, _ := nm["server"].(string)
	port := 8443
	if p, ok := nm["port"].(float64); ok {
		port = int(p)
	}
	if addr == "" {
		return nil
	}
	return buildVLESSFromPayload(addr, port, vless, tag, wan)
}

func (r *Renderer) buildInbounds(proxyMode string) []any {
	_ = strings.ToLower(strings.TrimSpace(proxyMode))
	// Kernel policy routing (nft fwmark + ip rule) feeds gfctun.
	// sing-box is outbound-only: no auto_route / auto_redirect / strict_route.
	// gvisor avoids system-stack routing loops with kernel fwmark → gfctun policy.
	tun := map[string]any{
		"type":           "tun",
		"tag":            "tun-in",
		"interface_name": config.TunInterface,
		"address":        []string{"172.19.0.1/30"},
		"mtu":            1500,
		"auto_route":     false,
		"strict_route":   false,
		"stack":          "gvisor",
	}
	if r.RoutingScheme() != "byst-redirect" {
		return []any{tun}
	}
	redirectPort := 11800
	if p, err := strconv.Atoi(strings.TrimSpace(os.Getenv("GFC_REDIRECT_PORT"))); err == nil && p > 0 && p <= 65535 {
		redirectPort = p
	}
	redirect := map[string]any{
		"type":        "redirect",
		"tag":         "tcp-in",
		"listen":      "0.0.0.0",
		"listen_port": redirectPort,
		"sniff":       false,
	}
	return []any{redirect, tun}
}

// preferProxyGroup always selects VLESS for TUN/international traffic.
//
// sing-box urltest picks the lowest-latency *healthy* member. On open-WAN
// gateways (typical ImmortalWrt edge), direct reaches public health URLs faster
// than VLESS, so including "direct" makes now=direct permanently and leaks
// proxy-bound traffic to eth0. sing-box has no priority/fallback group, so the
// only correct config is proxy-only: kernel already decided this flow should be
// proxied (mark → gfctun); sing-box must not second-guess via WAN direct.
func preferProxyGroup(proxyTag string) map[string]any {
	url := strings.TrimSpace(os.Getenv("GFC_PROXY_HEALTH_URL"))
	if url == "" {
		url = "https://www.gstatic.com/generate_204"
	}
	interval := strings.TrimSpace(os.Getenv("GFC_PROXY_HEALTH_INTERVAL"))
	if interval == "" {
		interval = "1m"
	}
	return map[string]any{
		"type":      "urltest",
		"tag":       preferProxyTag,
		"outbounds": []any{proxyTag},
		"url":       url,
		"interval":  interval,
		"tolerance": 100,
	}
}

func intlDNSCidrs() []string {
	raw := strings.TrimSpace(os.Getenv("GFC_EXT_CONST_IPS"))
	if raw == "" {
		return append([]string(nil), intlDNS...)
	}
	seen := map[string]bool{}
	var out []string
	for _, token := range strings.Split(raw, ",") {
		ip := strings.TrimSpace(token)
		ip = strings.Split(ip, "/")[0]
		if net.ParseIP(ip) == nil {
			continue
		}
		cidr := ip + "/32"
		if seen[cidr] {
			continue
		}
		seen[cidr] = true
		out = append(out, cidr)
	}
	if len(out) == 0 {
		return append([]string(nil), intlDNS...)
	}
	return out
}

// preferProxyRouteRules builds:
//
//	bypass_ip / node / control-plane → direct
//	private → direct
//	intl DNS IPs → proxy-prefer
//	(optional catch-all) → proxy-prefer
//
// route.final should be "direct".
func (r *Renderer) preferProxyRouteRules(nodeAddr string, payload map[string]any, preferTag string, catchAll bool) []map[string]any {
	var rules []map[string]any
	if bypass := r.bypassIPCidrs(payload, nodeAddr); len(bypass) > 0 {
		rules = append(rules, map[string]any{"ip_cidr": bypass, "outbound": "direct"})
	}
	rules = append(rules,
		map[string]any{"ip_is_private": true, "outbound": "direct"},
		map[string]any{"ip_cidr": domesticDNS, "port": []int{53}, "outbound": "direct"},
		map[string]any{"ip_cidr": intlDNSCidrs(), "outbound": preferTag},
	)
	if catchAll {
		rules = append(rules, map[string]any{"outbound": preferTag})
	}
	return rules
}

func (r *Renderer) bypassIPCidrs(payload map[string]any, nodeAddr string) []string {
	seen := map[string]bool{}
	var out []string
	addHost := func(host string) {
		host = strings.TrimSpace(host)
		if host == "" {
			return
		}
		if strings.Contains(host, "://") {
			if u, err := url.Parse(host); err == nil && u.Hostname() != "" {
				host = u.Hostname()
			}
		}
		host = strings.Split(host, "/")[0]
		if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
			host = host[1 : len(host)-1]
		}
		ip := net.ParseIP(host)
		if ip == nil || ip.To4() == nil {
			return
		}
		cidr := ip.String() + "/32"
		if seen[cidr] {
			return
		}
		seen[cidr] = true
		out = append(out, cidr)
	}
	addHost(nodeAddr)
	if servers, ok := payload["controlPlaneServers"].([]any); ok {
		for _, s := range servers {
			addHost(fmt.Sprint(s))
		}
	}
	for _, key := range []string{
		"GFC_POLICY_BYPASS_IPS", "GFC_NODE_BYPASS", "GFC_CP_BYPASS",
		"SERVER_URL", "SERVER_URL_FALLBACK",
	} {
		for _, token := range strings.Split(os.Getenv(key), ",") {
			addHost(token)
		}
	}
	return out
}

func (r *Renderer) appendSplitRules(rules *[]map[string]any, useMeta bool, proxyTag string) {
	if useMeta {
		*rules = append(*rules,
			map[string]any{"rule_set": "geoip-cn", "outbound": "direct"},
			map[string]any{"rule_set": "geosite-cn", "outbound": "direct"},
			map[string]any{"rule_set": "geosite-geolocation-!cn", "outbound": proxyTag},
		)
		return
	}
	*rules = append(*rules, map[string]any{"domain_suffix": []string{".cn", ".中国"}, "outbound": "direct"})
}

func directIPRule(host string) map[string]any {
	host = strings.TrimSpace(host)
	if host == "" {
		return nil
	}
	if strings.Contains(host, "://") {
		if u, err := url.Parse(host); err == nil && u.Hostname() != "" {
			host = u.Hostname()
		}
	}
	host = strings.Split(host, "/")[0]
	if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
		host = host[1 : len(host)-1]
	}
	if ip := net.ParseIP(host); ip != nil {
		return map[string]any{"ip_cidr": []string{host + "/32"}, "outbound": "direct"}
	}
	return nil
}

func WriteConfig(path string, data map[string]any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, raw, 0o640); err != nil {
		return err
	}
	fixSingboxConfigOwner(path)
	return nil
}

func fixSingboxConfigOwner(path string) {
	name := strings.TrimSpace(os.Getenv("GFC_SINGBOX_USER"))
	if name == "" {
		name = "singbox"
	}
	grp, err := user.LookupGroup(name)
	if err != nil {
		return
	}
	gid, err := strconv.Atoi(grp.Gid)
	if err != nil {
		return
	}
	_ = os.Chown(path, 0, gid)
	_ = os.Chmod(path, 0o640)
}

func CheckConfig(path string) error {
	cmd := exec.Command("sing-box", "check", "-c", path)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return nil
}
