package network

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

type wanApplyPlan struct {
	device  string
	proto   string
	mtu     int
	sets    map[string]string
	deletes []string
}

func buildWANApplyPlan(cfg map[string]any, defaultIface string) (wanApplyPlan, error) {
	device := strings.TrimSpace(text(cfg["interface"]))
	if device == "" {
		device = strings.TrimSpace(defaultIface)
	}
	if device == "" {
		return wanApplyPlan{}, fmt.Errorf("wan interface missing")
	}
	mode := strings.ToLower(strings.TrimSpace(text(cfg["mode"])))
	if mode == "" {
		mode = "dhcp"
	}
	plan := wanApplyPlan{
		device: device,
		proto:  mode,
		mtu:    intValue(cfg["mtu"], 0),
		sets:   map[string]string{},
	}
	switch mode {
	case "static":
		plan.deletes = append(plan.deletes, wanPPPoEOptions()...)
		for jsonKey, uciKey := range map[string]string{
			"address": "ipaddr", "netmask": "netmask", "gateway": "gateway",
		} {
			if val := strings.TrimSpace(text(cfg[jsonKey])); val != "" {
				plan.sets[uciKey] = val
			} else {
				plan.deletes = append(plan.deletes, uciKey)
			}
		}
		dns := compact([]string{text(cfg["dns1"]), text(cfg["dns2"])})
		if len(dns) > 0 {
			plan.sets["dns"] = strings.Join(dns, " ")
		} else {
			plan.deletes = append(plan.deletes, "dns")
		}
	case "pppoe":
		plan.deletes = append(plan.deletes, wanStaticOptions()...)
		if user := strings.TrimSpace(text(cfg["username"])); user != "" {
			plan.sets["username"] = user
		} else {
			plan.deletes = append(plan.deletes, "username")
		}
		if pass := text(cfg["password"]); strings.TrimSpace(pass) != "" {
			plan.sets["password"] = pass
		} else {
			plan.deletes = append(plan.deletes, "password")
		}
	case "dhcp":
		plan.deletes = append(plan.deletes, wanStaticOptions()...)
		plan.deletes = append(plan.deletes, wanPPPoEOptions()...)
	default:
		return wanApplyPlan{}, fmt.Errorf("unsupported wan mode %q", mode)
	}
	sort.Strings(plan.deletes)
	return plan, nil
}

func wanStaticOptions() []string {
	return []string{"ipaddr", "netmask", "gateway", "dns"}
}

func wanPPPoEOptions() []string {
	return []string{"username", "password"}
}

func (m *Manager) applyOpenWrtWAN(cfg map[string]any) error {
	plan, err := buildWANApplyPlan(cfg, m.cfg.WanIface)
	if err != nil {
		return err
	}
	_, _ = uci("set", "network.wan=interface")
	_, _ = uci("set", "network.wan.device="+plan.device)
	_, _ = uci("set", "network.wan.proto="+plan.proto)
	if plan.mtu > 0 {
		_, _ = uci("set", "network.wan.mtu="+strconv.Itoa(plan.mtu))
	} else {
		_, _ = uci("delete", "network.wan.mtu")
	}
	keys := make([]string, 0, len(plan.sets))
	for key := range plan.sets {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		_, _ = uci("set", "network.wan."+key+"="+plan.sets[key])
	}
	for _, key := range plan.deletes {
		_, _ = uci("delete", "network.wan."+key)
	}
	return nil
}
