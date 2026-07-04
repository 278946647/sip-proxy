package singbox

import (
	"os"
	"testing"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func TestPreferProxyGroup(t *testing.T) {
	g := preferProxyGroup("proxy")
	if g["type"] != "urltest" || g["tag"] != preferProxyTag {
		t.Fatalf("unexpected group: %#v", g)
	}
	outs, ok := g["outbounds"].([]any)
	if !ok || len(outs) != 2 || outs[0] != "proxy" || outs[1] != "direct" {
		t.Fatalf("outbounds want [proxy, direct], got %#v", g["outbounds"])
	}
}

func TestPreferProxyRouteRulesOrder(t *testing.T) {
	r := NewRenderer(&config.Config{})
	payload := map[string]any{
		"controlPlaneServers": []any{"http://103.78.41.16:8080"},
	}
	rules := r.preferProxyRouteRules("103.78.41.15", payload, preferProxyTag, true)
	if len(rules) < 4 {
		t.Fatalf("too few rules: %d", len(rules))
	}
	// First rule must be bypass (node + control plane) → direct.
	first := rules[0]
	if first["outbound"] != "direct" {
		t.Fatalf("first rule outbound=%v want direct", first["outbound"])
	}
	cidrs, _ := first["ip_cidr"].([]string)
	want := map[string]bool{"103.78.41.15/32": true, "103.78.41.16/32": true}
	for _, c := range cidrs {
		delete(want, c)
	}
	if len(want) != 0 {
		t.Fatalf("missing bypass cidrs: %v (got %v)", want, cidrs)
	}
	// Last rule is catch-all prefer proxy.
	last := rules[len(rules)-1]
	if last["outbound"] != preferProxyTag {
		t.Fatalf("last rule outbound=%v want %s", last["outbound"], preferProxyTag)
	}
	if _, hasCIDR := last["ip_cidr"]; hasCIDR {
		t.Fatal("catch-all must not set ip_cidr")
	}
	// Intl DNS rule present.
	foundIntl := false
	for _, rule := range rules {
		if rule["outbound"] != preferProxyTag {
			continue
		}
		ic, ok := rule["ip_cidr"].([]string)
		if !ok {
			continue
		}
		for _, c := range ic {
			if c == "1.1.1.1/32" {
				foundIntl = true
			}
		}
	}
	if !foundIntl {
		t.Fatal("missing intl DNS prefer-proxy rule")
	}
}

func TestIntlDNSCidrsFromEnv(t *testing.T) {
	t.Setenv("GFC_EXT_CONST_IPS", "1.1.1.1,8.8.8.8")
	got := intlDNSCidrs()
	if len(got) != 2 || got[0] != "1.1.1.1/32" || got[1] != "8.8.8.8/32" {
		t.Fatalf("got %v", got)
	}
	_ = os.Unsetenv("GFC_EXT_CONST_IPS")
}
