package api

import "testing"

func TestHostsFromBody(t *testing.T) {
	hosts, err := hostsFromBody(map[string]any{
		"customer_hosts_text": "10.0.0.1\n10.0.1.0/24",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 2 {
		t.Fatalf("hosts=%v", hosts)
	}

	hosts, err = hostsFromBody(map[string]any{
		"customer_hosts": []any{"10.1.1.1", "10.1.1.0/24"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 2 {
		t.Fatalf("hosts=%v", hosts)
	}
}

func TestSwitchRequestFromBodyBypass(t *testing.T) {
	req, err := switchRequestFromBody(map[string]any{
		"proxy_mode": "bypass",
		"wan": map[string]any{
			"mode": "static", "address": "10.20.30.2",
			"netmask": "255.255.255.0", "gateway": "10.20.30.1",
		},
		"customer_hosts_text": "10.20.30.10",
		"confirm_timeout_sec": 90,
	}, "192.168.68.0/24")
	if err != nil {
		t.Fatal(err)
	}
	if req.Mode != "bypass" || req.WAN.Gateway != "10.20.30.1" || len(req.CustomerHosts) != 1 {
		t.Fatalf("req=%+v", req)
	}
	if req.ConfirmTimeoutSec != 90 {
		t.Fatalf("timeout=%d", req.ConfirmTimeoutSec)
	}
}
