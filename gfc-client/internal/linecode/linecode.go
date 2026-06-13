package linecode

import (
	"encoding/base32"
	"encoding/json"
	"fmt"
	"strings"
)

func Decode(code string) (map[string]any, error) {
	normalized := strings.ToUpper(strings.ReplaceAll(strings.ReplaceAll(strings.TrimSpace(code), " ", ""), "-", ""))
	pad := (8 - len(normalized)%8) % 8
	raw, err := base32.StdEncoding.DecodeString(normalized + strings.Repeat("=", pad))
	if err != nil {
		return nil, fmt.Errorf("invalid base32: %w", err)
	}
	var data map[string]any
	if err := json.Unmarshal(raw, &data); err != nil {
		return nil, fmt.Errorf("invalid json: %w", err)
	}
	return data, nil
}

func Encode(payload map[string]any) (string, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return strings.TrimRight(base32.StdEncoding.EncodeToString(raw), "="), nil
}

func Kind(payload map[string]any) string {
	if k, ok := payload["kind"].(string); ok {
		k = strings.ToLower(strings.TrimSpace(k))
		if k == "platform" || k == "line" {
			return k
		}
	}
	if payload["lineId"] != nil {
		return "line"
	}
	if payload["server"] != nil && payload["lineId"] == nil {
		return "platform"
	}
	return "line"
}

func IsLine(payload map[string]any) bool {
	return Kind(payload) == "line"
}

func ServerURLs(payload map[string]any) []string {
	var urls []string
	seen := map[string]bool{}
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" || seen[s] {
			return
		}
		seen[s] = true
		urls = append(urls, s)
	}
	if v, ok := payload["server"].(string); ok {
		add(v)
	}
	if v, ok := payload["serverFallback"].(string); ok {
		add(v)
	}
	if arr, ok := payload["servers"].([]any); ok {
		for _, item := range arr {
			if s, ok := item.(string); ok {
				add(s)
			}
		}
	}
	return urls
}
