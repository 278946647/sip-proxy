package payload

import "strings"

func IsDirect(payload map[string]any) bool {
	if payload == nil {
		return true
	}
	if mode, ok := payload["dataplaneMode"].(string); ok {
		return strings.EqualFold(strings.TrimSpace(mode), "direct")
	}
	node, _ := payload["node"].(map[string]any)
	if node == nil {
		return true
	}
	addr, _ := node["address"].(string)
	return strings.TrimSpace(addr) == ""
}

// RoutingMode reads control-plane routingScheme from bundle payload.
// Local file /etc/gfc-client/routing-mode.json uses the same values: split | global.
func RoutingMode(payload map[string]any) string {
	if payload == nil {
		return "split"
	}
	for _, key := range []string{"routingScheme", "routing_scheme"} {
		raw, ok := payload[key].(string)
		if !ok {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(raw)) {
		case "global":
			return "global"
		}
	}
	return "split"
}
