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
