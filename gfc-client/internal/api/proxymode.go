package api

import (
	"fmt"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/proxymode"
)

func (s *Server) lanCIDR() string {
	st := s.network.Status()
	if v, ok := st["lanNetwork"].(string); ok && strings.TrimSpace(v) != "" {
		return strings.TrimSpace(v)
	}
	return s.cfg.LanCIDR
}

func switchRequestFromBody(body map[string]any, lanCIDR string) (proxymode.SwitchRequest, error) {
	req := proxymode.SwitchRequest{
		Mode:    textValue(body["proxy_mode"]),
		LANCIDR: lanCIDR,
	}
	if req.Mode == "" {
		req.Mode = textValue(body["mode"])
	}
	if n, ok := intValue(body["confirm_timeout_sec"]); ok {
		req.ConfirmTimeoutSec = n
	}

	hosts, err := hostsFromBody(body)
	if err != nil {
		return req, err
	}
	req.CustomerHosts = hosts
	req.WAN = wanFromBody(body)
	req.IspPort = firstText(body["isp_port"], body["ispPort"])
	req.CpePort = firstText(body["cpe_port"], body["cpePort"])
	if nested, ok := body["ports"].(map[string]any); ok {
		if req.IspPort == "" {
			req.IspPort = firstText(nested["isp_port"], nested["isp"])
		}
		if req.CpePort == "" {
			req.CpePort = firstText(nested["cpe_port"], nested["cpe"])
		}
	}
	if v, ok := body["dns_hijack"]; ok {
		b := boolValue(v)
		req.DNSHijack = &b
	}
	if raw, ok := body["dns_hijack_exclude"]; ok && raw != nil {
		ex, err := hostsFromRaw(raw)
		if err != nil {
			return req, err
		}
		req.DNSHijackExclude = ex
	}
	if text := textValue(body["dns_hijack_exclude_text"]); text != "" {
		ex, err := proxymode.ParseHostsText(text)
		if err != nil {
			return req, err
		}
		req.DNSHijackExclude = ex
	}
	req.DNSVIP = firstText(body["dns_vip"], body["dnsVip"])
	return req, nil
}

func hostsFromRaw(raw any) ([]string, error) {
	switch v := raw.(type) {
	case string:
		return proxymode.ParseHostsText(v)
	case []any:
		out := make([]string, 0, len(v))
		for _, item := range v {
			out = append(out, fmt.Sprint(item))
		}
		return proxymode.NormalizeHosts(out)
	case []string:
		return proxymode.NormalizeHosts(v)
	default:
		return nil, nil
	}
}

func boolValue(v any) bool {
	switch b := v.(type) {
	case bool:
		return b
	case string:
		s := strings.ToLower(strings.TrimSpace(b))
		return s == "1" || s == "true" || s == "on" || s == "yes"
	case float64:
		return b != 0
	default:
		return false
	}
}

func hostsFromBody(body map[string]any) ([]string, error) {
	if raw, ok := body["customer_hosts"]; ok && raw != nil {
		switch v := raw.(type) {
		case string:
			return proxymode.ParseHostsText(v)
		case []any:
			out := make([]string, 0, len(v))
			for _, item := range v {
				out = append(out, fmt.Sprint(item))
			}
			return proxymode.NormalizeHosts(out)
		case []string:
			return proxymode.NormalizeHosts(v)
		}
	}
	if text := textValue(body["customer_hosts_text"]); text != "" {
		return proxymode.ParseHostsText(text)
	}
	return nil, nil
}

func wanFromBody(body map[string]any) proxymode.WANConfig {
	wan := map[string]any{}
	if nested, ok := body["wan"].(map[string]any); ok {
		wan = nested
	}
	cfg := proxymode.WANConfig{
		Interface: firstText(wan["interface"], body["wan_interface"], body["interface"]),
		Mode:      firstText(wan["mode"], body["wan_mode"]),
		Address:   firstText(wan["address"], body["address"], body["wan_address"]),
		Netmask:   firstText(wan["netmask"], body["netmask"], body["wan_netmask"]),
		Gateway:   firstText(wan["gateway"], body["gateway"], body["wan_gateway"]),
	}
	if cfg.Mode == "" && cfg.Address != "" {
		cfg.Mode = "static"
	}
	return cfg
}

func textValue(v any) string {
	if v == nil {
		return ""
	}
	s, ok := v.(string)
	if !ok {
		return strings.TrimSpace(fmt.Sprint(v))
	}
	return strings.TrimSpace(s)
}

func firstText(vals ...any) string {
	for _, v := range vals {
		if s := textValue(v); s != "" {
			return s
		}
	}
	return ""
}

func intValue(v any) (int, bool) {
	switch n := v.(type) {
	case float64:
		return int(n), true
	case int:
		return n, true
	case int64:
		return int(n), true
	case string:
		n = strings.TrimSpace(n)
		if n == "" {
			return 0, false
		}
		var out int
		_, err := fmt.Sscanf(n, "%d", &out)
		return out, err == nil
	default:
		return 0, false
	}
}
