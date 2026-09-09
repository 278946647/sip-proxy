package transparent

import (
	"fmt"
	"regexp"
	"strings"
)

var ifaceNameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,14}$`)

var reservedIfaces = map[string]struct{}{
	"lo": {}, "gfctun": {}, DummyCE: {}, DummyDNS: {}, BridgeName: {},
}

// ValidatePorts enforces device-Web isp/cpe roles. lanIface is br-lan / management.
func ValidatePorts(p Ports, lanIface string) error {
	p = p.Normalized()
	if p.ISP == "" || p.CPE == "" {
		return fmt.Errorf("透明模式必须指定 isp_port 与 cpe_port")
	}
	if p.ISP == p.CPE {
		return fmt.Errorf("isp_port 与 cpe_port 不能是同一网卡")
	}
	for _, name := range []string{p.ISP, p.CPE} {
		if !ifaceNameRe.MatchString(name) {
			return fmt.Errorf("非法网卡名 %q", name)
		}
		if _, ok := reservedIfaces[name]; ok {
			return fmt.Errorf("网卡 %s 不能作为 isp/cpe", name)
		}
	}
	lan := strings.TrimSpace(lanIface)
	if lan == "" {
		lan = "br-lan"
	}
	if p.ISP == lan || p.CPE == lan {
		return fmt.Errorf("isp/cpe 不能占用管理 LAN 口 %s", lan)
	}
	return nil
}
