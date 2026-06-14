package singbox

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

var domesticDNS = []string{
	"223.5.5.5/32", "223.6.6.6/32", "119.29.29.29/32", "114.114.114.114/32",
}

var intlDOH = []string{
	"1.1.1.1/32", "1.0.0.1/32", "8.8.8.8/32", "8.8.4.4/32",
}

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
	port := 443
	if p, ok := node["port"].(float64); ok {
		port = int(p)
	}

	proxyMode := strings.ToLower(strings.TrimSpace(fmt.Sprint(payload["proxyMode"])))
	if proxyMode == "" {
		proxyMode = r.cfg.ProxyMode
	}

	directLocal := map[string]any{"type": "direct", "tag": "direct-local"}
	direct := map[string]any{"type": "direct", "tag": "direct"}
	if wan := r.cfg.WanIface; wan != "" {
		direct["bind_interface"] = wan
	}

	nodeTag := "proxy"
	outbounds := []any{directLocal, direct}
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
			ob := buildVLESSOutbound(nm, tag)
			if ob != nil {
				outbounds = append(outbounds, ob)
				nodeTags = append(nodeTags, tag)
			}
		}
	} else {
		outbounds = append(outbounds, buildVLESSFromPayload(address, port, vless, nodeTag))
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

	inbounds := r.buildInbounds(proxyMode)
	routeRules := r.dnsRouteRules(address, payload, proxyOutbound)
	routingMode := r.RoutingMode()
	if routingMode != "global" {
		r.appendSplitRules(&routeRules, len(ruleSets) > 0, proxyOutbound)
	}
	routeRules = append(routeRules, map[string]any{"outbound": proxyOutbound})

	route := map[string]any{
		"auto_detect_interface": true,
		"final":                 proxyOutbound,
		"rules":                 routeRules,
	}
	if len(ruleSets) > 0 {
		route["rule_set"] = ruleSets
	}

	logBlock := map[string]any{"level": r.LogLevel()}
	if lvl := r.LogLevel(); lvl == "info" || lvl == "debug" || lvl == "warn" {
		logBlock["timestamp"] = true
	}

	return map[string]any{
		"log":       logBlock,
		"inbounds":  inbounds,
		"outbounds": outbounds,
		"route":     route,
		"experimental": map[string]any{
			"cache_file": map[string]any{"enabled": false},
			"clash_api": map[string]any{
				"external_controller": "127.0.0.1:9090",
				"secret":              "",
			},
		},
	}, nil
}

func buildVLESSFromPayload(address string, port int, vless map[string]any, tag string) map[string]any {
	flow, _ := vless["flow"].(string)
	if flow == "" {
		flow = "xtls-rprx-vision"
	}
	sni, _ := vless["serverName"].(string)
	if sni == "" {
		sni = "www.microsoft.com"
	}
	pk, _ := vless["publicKey"].(string)
	sid, _ := vless["shortId"].(string)
	return map[string]any{
		"type":        "vless",
		"tag":         tag,
		"server":      address,
		"server_port": port,
		"uuid":        vless["uuid"],
		"flow":        flow,
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
}

func buildVLESSOutbound(nm map[string]any, tag string) map[string]any {
	vless, _ := nm["vless"].(map[string]any)
	if vless == nil {
		vless = nm
	}
	addr, _ := nm["server"].(string)
	port := 443
	if p, ok := nm["port"].(float64); ok {
		port = int(p)
	}
	if addr == "" {
		return nil
	}
	return buildVLESSFromPayload(addr, port, vless, tag)
}

func (r *Renderer) buildInbounds(proxyMode string) []any {
	mode := strings.ToLower(strings.TrimSpace(proxyMode))
	autoRoute := mode == "gateway" || mode == "transparent"
	strictRoute := mode == "gateway" || mode == "transparent"

	tun := map[string]any{
		"type":           "tun",
		"tag":            "tun-in",
		"interface_name": config.TunInterface,
		"address":        []string{"172.19.0.1/30"},
		"mtu":            1500,
		"auto_route":     autoRoute,
		"strict_route":   strictRoute,
		"stack":          "system",
	}
	if autoRoute {
		tun["auto_redirect"] = true
		tun["route_address"] = []string{"0.0.0.0/1", "128.0.0.0/1"}
		tun["route_exclude_address"] = r.routeExclude()
	}
	// bypass: TUN up without auto_route; traffic enters via gateway/FORWARD path
	return []any{tun}
}

func (r *Renderer) routeExclude() []string {
	ex := []string{
		"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
		"127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4",
	}
	ex = append(ex, domesticDNS...)
	if r.cfg.LanCIDR != "" {
		ex = append(ex, r.cfg.LanCIDR)
	}
	return ex
}

func (r *Renderer) dnsRouteRules(nodeAddr string, payload map[string]any, proxyTag string) []map[string]any {
	rules := []map[string]any{
		{"ip_cidr": domesticDNS, "port": []int{53}, "outbound": "direct"},
		{"ip_cidr": intlDOH, "port": []int{443}, "outbound": proxyTag},
		{"ip_cidr": []string{"127.0.0.1/32"}, "port": []int{config.DefaultMosDNS}, "outbound": "direct-local"},
	}
	if dr := directIPRule(nodeAddr); dr != nil {
		rules = append(rules, dr)
	}
	if servers, ok := payload["controlPlaneServers"].([]any); ok {
		for _, s := range servers {
			if dr := directIPRule(fmt.Sprint(s)); dr != nil {
				rules = append(rules, dr)
			}
		}
	}
	rules = append(rules, map[string]any{"ip_is_private": true, "outbound": "direct"})
	return rules
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
	return os.WriteFile(path, raw, 0o644)
}

func CheckConfig(path string) error {
	cmd := exec.Command("sing-box", "check", "-c", path)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return nil
}
