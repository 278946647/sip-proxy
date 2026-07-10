package payload

import "testing"

func TestRoutingMode(t *testing.T) {
	tests := []struct {
		name string
		in   map[string]any
		want string
	}{
		{"nil", nil, "split"},
		{"empty", map[string]any{}, "split"},
		{"routingScheme global", map[string]any{"routingScheme": "global"}, "global"},
		{"routing_scheme global", map[string]any{"routing_scheme": "GLOBAL"}, "global"},
		{"routingScheme split", map[string]any{"routingScheme": "split"}, "split"},
		{"unknown", map[string]any{"routingScheme": "direct"}, "split"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := RoutingMode(tc.in); got != tc.want {
				t.Fatalf("RoutingMode() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestNormalizeRoutingMode(t *testing.T) {
	tests := []struct {
		raw  string
		want string
	}{
		{"global", "global"},
		{"GLOBAL", "global"},
		{"split", "split"},
		{"direct", "split"},
		{"", "split"},
	}
	for _, tc := range tests {
		if got := NormalizeRoutingMode(tc.raw); got != tc.want {
			t.Fatalf("NormalizeRoutingMode(%q) = %q, want %q", tc.raw, got, tc.want)
		}
	}
}
