package proxymode

import "testing"

func TestValidateBypassRequiresHostsAndStaticWAN(t *testing.T) {
	err := ValidateSwitch(SwitchRequest{
		Mode: ModeBypass,
		WAN:  WANConfig{Mode: "static", Address: "10.20.30.2", Netmask: "255.255.255.0", Gateway: "10.20.30.1"},
	})
	if err == nil {
		t.Fatal("expected empty customer_hosts to fail")
	}

	err = ValidateSwitch(SwitchRequest{
		Mode:          ModeBypass,
		CustomerHosts: []string{"10.20.30.10"},
		WAN:           WANConfig{Mode: "dhcp"},
		LANCIDR:       "192.168.68.0/24",
	})
	if err == nil {
		t.Fatal("expected dhcp WAN to fail")
	}

	err = ValidateSwitch(SwitchRequest{
		Mode:          ModeBypass,
		CustomerHosts: []string{"10.20.30.10"},
		WAN:           WANConfig{Mode: "static", Address: "10.20.30.2", Netmask: "255.255.255.0", Gateway: "10.20.30.1"},
		LANCIDR:       "192.168.68.0/24",
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestValidateBypassRejectsLANOverlap(t *testing.T) {
	err := ValidateSwitch(SwitchRequest{
		Mode:          ModeBypass,
		CustomerHosts: []string{"192.168.68.10"},
		WAN:           WANConfig{Mode: "static", Address: "10.20.30.2", Netmask: "255.255.255.0", Gateway: "10.20.30.1"},
		LANCIDR:       "192.168.68.0/24",
	})
	if err == nil {
		t.Fatal("expected customer_hosts vs LAN overlap to fail")
	}

	err = ValidateSwitch(SwitchRequest{
		Mode:          ModeBypass,
		CustomerHosts: []string{"10.20.30.10"},
		WAN:           WANConfig{Mode: "static", Address: "192.168.68.2", Netmask: "255.255.255.0", Gateway: "192.168.68.1"},
		LANCIDR:       "192.168.68.0/24",
	})
	if err == nil {
		t.Fatal("expected WAN vs LAN overlap to fail")
	}
}

func TestValidateGatewayOK(t *testing.T) {
	if err := ValidateSwitch(SwitchRequest{Mode: ModeGateway}); err != nil {
		t.Fatal(err)
	}
}

func TestValidateTransparentRejected(t *testing.T) {
	if err := ValidateSwitch(SwitchRequest{Mode: ModeTransparent}); err == nil {
		t.Fatal("expected transparent to fail")
	}
}

func TestNormalizeHosts(t *testing.T) {
	hosts, err := ParseHostsText("10.0.0.1, 10.0.1.0/24\n10.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 2 || hosts[0] != "10.0.0.1" || hosts[1] != "10.0.1.0/24" {
		t.Fatalf("hosts=%v", hosts)
	}
}

func TestClampConfirmTimeout(t *testing.T) {
	if ClampConfirmTimeout(0) != DefaultConfirmTimeoutSec {
		t.Fatal("default")
	}
	if ClampConfirmTimeout(10) != MinConfirmTimeoutSec {
		t.Fatal("min")
	}
	if ClampConfirmTimeout(9999) != MaxConfirmTimeoutSec {
		t.Fatal("max")
	}
}
