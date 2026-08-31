package policyrouting

import (
	"fmt"
	"net"
	"strings"
)

func Probe(req ProbeRequest, groups []Group, policies []Policy, env Env, snap Snapshot) (ProbeResult, error) {
	src := strings.TrimSpace(req.ProbeSrc)
	dst := strings.TrimSpace(req.ProbeDst)
	domain := strings.TrimSpace(strings.ToLower(strings.TrimSuffix(req.ProbeDomain, ".")))
	resolved := append([]string{}, req.ResolvedIPs...)

	if dst == "" && domain == "" {
		return ProbeResult{}, fmt.Errorf("probe_dst 与 probe_domain 须填其一")
	}
	if dst != "" && domain != "" {
		return ProbeResult{}, fmt.Errorf("probe_dst 与 probe_domain 互斥")
	}
	if dst != "" {
		if ip := parseIPv4(dst); ip == nil {
			return ProbeResult{}, fmt.Errorf("probe_dst 必须是 IPv4: %s", dst)
		}
	}
	if src != "" {
		if ip := parseIPv4(src); ip == nil {
			return ProbeResult{}, fmt.Errorf("probe_src 必须是 IPv4: %s", src)
		}
	}
	if domain != "" {
		if _, err := normalizeProbeQName(domain); err != nil {
			return ProbeResult{}, err
		}
		if len(resolved) == 0 {
			// Phase A: logical probe may omit live DNS; treat domain as match key only.
			resolved = nil
		} else {
			norm := make([]string, 0, len(resolved))
			for _, r := range resolved {
				v, err := normalizeIPOrCIDR(r)
				if err != nil {
					return ProbeResult{}, fmt.Errorf("resolved_ips: %w", err)
				}
				norm = append(norm, v)
			}
			resolved = norm
		}
	}

	eligible, reason := ingressEligible(src, env)
	out := ProbeResult{
		IngressEligible: eligible,
		IngressReason:   reason,
		ProxyMode:       env.ProxyMode,
		ResolvedIPs:     resolved,
		DataplaneNote:   DataplanePending,
	}

	gm := groupMap(groups)
	dstIP := parseIPv4(dst)
	if dstIP == nil && len(resolved) > 0 {
		dstIP = parseIPv4(resolved[0])
	}

	// Domain set membership for display
	if domain != "" {
		for _, g := range groups {
			if g.Kind != KindDomain {
				continue
			}
			if domainMatches(domain, g.Members) {
				out.DomainSets = append(out.DomainSets, nftSetName(KindDomain, g.ID))
			}
		}
	}

	chain := make([]ProbeHop, 0, 8)

	// 1) Safety rail
	if dstIP != nil && ipInList(dstIP, snap.BypassIP) {
		hop := ProbeHop{
			Layer:   LayerSafety,
			ID:      "bypass_ip",
			Name:    "bypass_ip",
			Action:  ActionDirect,
			Matched: true,
			Reason:  "目的属于系统 bypass_ip（节点/控制器等），安全轨强制直连，不可进代理",
		}
		chain = append(chain, hop)
		out.Chain = chain
		out.WinnerID = hop.ID
		out.WinnerLayer = LayerSafety
		out.WinnerName = hop.Name
		out.Action = ActionDirect
		out.Reason = hop.Reason
		annotateBlockedBySafety(policies)
		return out, nil
	}
	if dstIP != nil && (ipInList(dstIP, defaultRFC1918()) || ipInList(dstIP, snap.RFC1918)) {
		hop := ProbeHop{
			Layer:   LayerSafety,
			ID:      "rfc1918",
			Name:    "RFC1918/本机",
			Action:  ActionDirect,
			Matched: true,
			Reason:  "目的为私网/本机类地址，架构强制不进代理",
		}
		chain = append(chain, hop)
		out.Chain = chain
		out.WinnerID = hop.ID
		out.WinnerLayer = LayerSafety
		out.WinnerName = hop.Name
		out.Action = ActionDirect
		out.Reason = hop.Reason
		return out, nil
	}
	chain = append(chain, ProbeHop{
		Layer:   LayerSafety,
		Matched: false,
		Reason:  "未命中 bypass_ip / 私网安全轨",
	})

	// 2) User overrides (UI order)
	sortPoliciesByRank(policies)
	for _, p := range policies {
		if !p.Enabled {
			chain = append(chain, ProbeHop{
				Layer: LayerUser, ID: p.ID, Name: p.Name, Matched: false,
				Reason: "已禁用",
			})
			continue
		}
		matched, why := policyMatches(p, src, dstIP, domain, resolved, gm)
		hop := ProbeHop{
			Layer: LayerUser, ID: p.ID, Name: p.Name, Action: p.Action, Matched: matched, Reason: why,
		}
		chain = append(chain, hop)
		if matched {
			out.Chain = chain
			out.WinnerID = p.ID
			out.WinnerLayer = LayerUser
			out.WinnerName = p.Name
			out.Action = p.Action
			out.Reason = fmt.Sprintf("命中用户 Override#%s（%s）→ %s", p.ID, p.Name, p.Action)
			return out, nil
		}
	}

	// 3) System default
	sys := systemDefault(dstIP, snap, env)
	chain = append(chain, sys)
	out.Chain = chain
	out.WinnerID = sys.ID
	out.WinnerLayer = LayerSystem
	out.WinnerName = sys.Name
	out.Action = sys.Action
	out.Reason = sys.Reason
	return out, nil
}

func ingressEligible(src string, env Env) (bool, string) {
	mode := strings.ToLower(strings.TrimSpace(env.ProxyMode))
	if mode == "" {
		mode = "gateway"
	}
	switch mode {
	case "gateway":
		if src == "" {
			return true, "网关模式：未指定源时按 LAN 入向假设可进入分类链"
		}
		ip := parseIPv4(src)
		if ip == nil {
			return false, "源地址无效"
		}
		if env.LANCIDR != "" {
			n, err := hostToNet(env.LANCIDR)
			if err == nil && n.Contains(ip) {
				return true, "源在管理 LAN，网关模式可入向分类"
			}
		}
		return true, "网关模式：源不在已知 LAN CIDR，仍按可入向处理（请确认实际从 LAN 进入）"
	case "bypass":
		if src == "" {
			return false, "旁路模式：须指定 probe_src；仅 @customer_hosts 可从 WAN 入向分类"
		}
		ip := parseIPv4(src)
		if ip == nil {
			return false, "源地址无效"
		}
		if len(env.CustomerHosts) == 0 {
			return false, "旁路模式 customer_hosts 为空，无客户可入向"
		}
		if ipInList(ip, env.CustomerHosts) {
			return true, "源属于 @customer_hosts，旁路 WAN 入向可分类"
		}
		if env.LANCIDR != "" {
			n, err := hostToNet(env.LANCIDR)
			if err == nil && n.Contains(ip) {
				return true, "源在管理 LAN（旁路下 LAN 仍保留 mini-gateway 入向）"
			}
		}
		return false, "旁路模式：源不在 @customer_hosts（也非管理 LAN），不可入向分类"
	case "transparent":
		return false, "transparent 模式尚未开放"
	default:
		return false, "未知 proxy_mode: " + mode
	}
}

func policyMatches(p Policy, src string, dstIP net.IP, domain string, resolved []string, gm map[string]Group) (bool, string) {
	if p.MatchSrcGroupID != "" {
		g, ok := gm[p.MatchSrcGroupID]
		if !ok {
			return false, "源组缺失"
		}
		if src == "" {
			return false, "规则要求源组，但 probe_src 为空"
		}
		if !ipInList(parseIPv4(src), g.Members) {
			return false, "源未命中组 " + g.Name
		}
	}
	if p.MatchDstGroupID != "" {
		g, ok := gm[p.MatchDstGroupID]
		if !ok {
			return false, "目的组缺失"
		}
		if dstIP == nil {
			return false, "规则要求目的组，但无目的 IP"
		}
		if !ipInList(dstIP, g.Members) {
			return false, "目的未命中组 " + g.Name
		}
	}
	if p.MatchDomainGroupID != "" {
		g, ok := gm[p.MatchDomainGroupID]
		if !ok {
			return false, "域名组缺失"
		}
		if domain == "" {
			// Allow IP probe against domain group via resolved membership later (phase B).
			if len(resolved) == 0 {
				return false, "规则要求域名组，但未提供 probe_domain"
			}
			return false, "IP 试算无法匹配域名组（请用 probe_domain）"
		}
		if !domainMatches(domain, g.Members) {
			return false, "域名未命中组 " + g.Name
		}
	}
	return true, "匹配"
}

func systemDefault(dstIP net.IP, snap Snapshot, env Env) ProbeHop {
	if dstIP != nil && ipInList(dstIP, snap.ExtConst) {
		return ProbeHop{
			Layer: LayerSystem, ID: "ext_const", Name: "ext_const", Action: ActionProxy, Matched: true,
			Reason: "系统默认：目的 ∈ ext_const → 打标进代理",
		}
	}
	if dstIP != nil && ipInList(dstIP, snap.Ext) {
		return ProbeHop{
			Layer: LayerSystem, ID: "ext", Name: "ext", Action: ActionProxy, Matched: true,
			Reason: "系统默认：目的 ∈ ext（动态国际）→ 打标进代理",
		}
	}
	routing := strings.ToLower(strings.TrimSpace(env.RoutingMode))
	if routing == "" {
		routing = "split"
	}
	if routing != "global" && dstIP != nil && ipInList(dstIP, snap.TOCN) {
		return ProbeHop{
			Layer: LayerSystem, ID: "TO_CN", Name: "TO_CN", Action: ActionDirect, Matched: true,
			Reason: "系统默认：目的 ∈ TO_CN → 直连 WAN",
		}
	}
	if routing == "global" {
		return ProbeHop{
			Layer: LayerSystem, ID: "catch_all", Name: "global", Action: ActionProxy, Matched: true,
			Reason: "系统默认：全局模式 catch-all → 打标进代理",
		}
	}
	return ProbeHop{
		Layer: LayerSystem, ID: "catch_all", Name: "non-CN", Action: ActionProxy, Matched: true,
		Reason: "系统默认：非 TO_CN / 未命中已知集合 → 打标进代理（与网关分流一致）",
	}
}

func defaultRFC1918() []string {
	return []string{"10.0.0.0/8", "127.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"}
}

func annotateBlockedBySafety(policies []Policy) {
	_ = policies
}
