package proxymode

import (
	"fmt"
	"net"
	"strings"
)

const (
	ModeGateway     = "gateway"
	ModeBypass      = "bypass"
	ModeTransparent = "transparent"

	DefaultConfirmTimeoutSec = 120
	MinConfirmTimeoutSec     = 30
	MaxConfirmTimeoutSec     = 600
)

// SwitchRequest is the device-Web payload to change proxy_mode.
type SwitchRequest struct {
	Mode              string
	WAN               WANConfig
	CustomerHosts     []string
	ConfirmTimeoutSec int
	LANCIDR           string
}

type WANConfig struct {
	Interface string
	Mode      string // dhcp | static | pppoe
	Address   string
	Netmask   string
	Gateway   string
}

func NormalizeMode(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case ModeBypass:
		return ModeBypass
	case ModeTransparent:
		return ModeTransparent
	default:
		return ModeGateway
	}
}

func ClampConfirmTimeout(sec int) int {
	if sec <= 0 {
		return DefaultConfirmTimeoutSec
	}
	if sec < MinConfirmTimeoutSec {
		return MinConfirmTimeoutSec
	}
	if sec > MaxConfirmTimeoutSec {
		return MaxConfirmTimeoutSec
	}
	return sec
}

// ValidateSwitch enforces commissioning rules before any WAN/mode apply.
func ValidateSwitch(req SwitchRequest) error {
	mode := NormalizeMode(req.Mode)
	switch mode {
	case ModeTransparent:
		return fmt.Errorf("transparent 模式尚未开放")
	case ModeGateway:
		return nil
	case ModeBypass:
		return validateBypass(req)
	default:
		return fmt.Errorf("unsupported proxy_mode %q", req.Mode)
	}
}

func validateBypass(req SwitchRequest) error {
	hosts, err := NormalizeHosts(req.CustomerHosts)
	if err != nil {
		return err
	}
	if len(hosts) == 0 {
		return fmt.Errorf("旁路模式必须填写 customer_hosts（使用本机为网关的客户源地址/网段）")
	}

	wanMode := strings.ToLower(strings.TrimSpace(req.WAN.Mode))
	if wanMode == "" {
		wanMode = "static"
	}
	if wanMode != "static" {
		return fmt.Errorf("旁路模式 WAN 必须为静态 IP/掩码/网关（当前 %s）", wanMode)
	}
	if strings.TrimSpace(req.WAN.Address) == "" || strings.TrimSpace(req.WAN.Netmask) == "" || strings.TrimSpace(req.WAN.Gateway) == "" {
		return fmt.Errorf("旁路模式必须填写 WAN IP、掩码和网关")
	}
	wanIP := net.ParseIP(strings.TrimSpace(req.WAN.Address))
	if wanIP == nil || wanIP.To4() == nil {
		return fmt.Errorf("WAN IP 无效: %s", req.WAN.Address)
	}
	mask := parseIPv4Mask(req.WAN.Netmask)
	if mask == nil {
		return fmt.Errorf("WAN 掩码无效: %s", req.WAN.Netmask)
	}
	gw := net.ParseIP(strings.TrimSpace(req.WAN.Gateway))
	if gw == nil || gw.To4() == nil {
		return fmt.Errorf("WAN 网关无效: %s", req.WAN.Gateway)
	}

	wanNet := &net.IPNet{IP: wanIP.To4().Mask(mask), Mask: mask}
	if !wanNet.Contains(gw) {
		return fmt.Errorf("WAN 网关 %s 不在 WAN 网段 %s 内", req.WAN.Gateway, wanNet.String())
	}

	lanCIDR := strings.TrimSpace(req.LANCIDR)
	if lanCIDR != "" {
		_, lanNet, err := net.ParseCIDR(lanCIDR)
		if err != nil {
			return fmt.Errorf("管理 LAN 网段无效: %s", lanCIDR)
		}
		if cidrsOverlap(wanNet, lanNet) {
			return fmt.Errorf("旁路 WAN 前缀 %s 与管理 LAN %s 冲突", wanNet.String(), lanNet.String())
		}
		if err := hostsOverlapLAN(hosts, lanNet); err != nil {
			return err
		}
	}
	return nil
}

func parseIPv4Mask(raw string) net.IPMask {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	if strings.Contains(raw, ".") {
		ip := net.ParseIP(raw)
		if ip == nil || ip.To4() == nil {
			return nil
		}
		m := ip.To4()
		return net.IPv4Mask(m[0], m[1], m[2], m[3])
	}
	var bits int
	if _, err := fmt.Sscanf(raw, "%d", &bits); err != nil || bits < 0 || bits > 32 {
		return nil
	}
	return net.CIDRMask(bits, 32)
}

func cidrsOverlap(a, b *net.IPNet) bool {
	if a == nil || b == nil {
		return false
	}
	return a.Contains(b.IP) || b.Contains(a.IP)
}
