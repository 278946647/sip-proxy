package network

import "testing"

func TestParseUCIShowStaticWAN(t *testing.T) {
	out := `network.wan=interface
network.wan.device='eth0'
network.wan.proto='static'
network.wan.ipaddr='103.78.41.17'
network.wan.netmask='255.255.255.224'
network.wan.gateway='103.78.41.1'
network.wan.dns='1.1.1.1'`
	values := parseUCIShow(out)
	if values["proto"] != "static" {
		t.Fatalf("proto=%q", values["proto"])
	}
	if values["ipaddr"] != "103.78.41.17" {
		t.Fatalf("ipaddr=%q", values["ipaddr"])
	}
}

func TestParseUCIShowDHCPWAN(t *testing.T) {
	out := `network.wan=interface
network.wan.device='eth0'
network.wan.proto='dhcp'`
	values := parseUCIShow(out)
	if values["proto"] != "dhcp" {
		t.Fatalf("proto=%q", values["proto"])
	}
}

func TestParseUCIShowPPPoEWAN(t *testing.T) {
	out := `network.wan=interface
network.wan.device='eth0'
network.wan.proto='pppoe'
network.wan.username='user@isp'
network.wan.password='secret'`
	values := parseUCIShow(out)
	if values["proto"] != "pppoe" || values["username"] != "user@isp" {
		t.Fatalf("values=%v", values)
	}
}
