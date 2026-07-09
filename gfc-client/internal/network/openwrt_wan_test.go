package network

import (
	"reflect"
	"testing"
)

func TestBuildWANApplyPlanStatic(t *testing.T) {
	plan, err := buildWANApplyPlan(map[string]any{
		"interface": "eth0",
		"mode":      "static",
		"address":   "103.78.41.17",
		"netmask":   "255.255.255.224",
		"gateway":   "103.78.41.1",
		"dns1":      "1.1.1.1",
	}, "")
	if err != nil {
		t.Fatal(err)
	}
	if plan.proto != "static" || plan.device != "eth0" {
		t.Fatalf("plan=%+v", plan)
	}
	if plan.sets["ipaddr"] != "103.78.41.17" {
		t.Fatalf("sets=%v", plan.sets)
	}
	if !reflect.DeepEqual(plan.deletes, []string{"password", "username"}) {
		t.Fatalf("deletes=%v", plan.deletes)
	}
}

func TestBuildWANApplyPlanPPPoE(t *testing.T) {
	plan, err := buildWANApplyPlan(map[string]any{
		"interface": "eth0",
		"mode":      "pppoe",
		"username":  "user@isp",
		"password":  "secret",
	}, "")
	if err != nil {
		t.Fatal(err)
	}
	if plan.proto != "pppoe" {
		t.Fatalf("proto=%q", plan.proto)
	}
	if plan.sets["username"] != "user@isp" || plan.sets["password"] != "secret" {
		t.Fatalf("sets=%v", plan.sets)
	}
	wantDeletes := []string{"dns", "gateway", "ipaddr", "netmask"}
	if !reflect.DeepEqual(plan.deletes, wantDeletes) {
		t.Fatalf("deletes=%v", plan.deletes)
	}
}

func TestBuildWANApplyPlanDHCP(t *testing.T) {
	plan, err := buildWANApplyPlan(map[string]any{
		"interface": "eth0",
		"mode":      "dhcp",
	}, "eth1")
	if err != nil {
		t.Fatal(err)
	}
	if plan.device != "eth0" {
		t.Fatalf("device=%q", plan.device)
	}
	wantDeletes := []string{"dns", "gateway", "ipaddr", "netmask", "password", "username"}
	if !reflect.DeepEqual(plan.deletes, wantDeletes) {
		t.Fatalf("deletes=%v", plan.deletes)
	}
	if len(plan.sets) != 0 {
		t.Fatalf("sets=%v", plan.sets)
	}
}

func TestBuildWANApplyPlanDefaultIface(t *testing.T) {
	plan, err := buildWANApplyPlan(map[string]any{"mode": "dhcp"}, "eth2")
	if err != nil {
		t.Fatal(err)
	}
	if plan.device != "eth2" {
		t.Fatalf("device=%q", plan.device)
	}
}
