package policyrouting

import (
	"fmt"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

type Service struct {
	cfg   *config.Config
	store *Store
	envFn func() Env
}

func NewService(cfg *config.Config, envFn func() Env) *Service {
	if envFn == nil {
		envFn = DefaultEnv
	}
	return &Service{cfg: cfg, store: NewStore(cfg), envFn: envFn}
}

func (s *Service) Store() *Store { return s.store }

func (s *Service) GetGroups() ([]Group, error) {
	groups, policies, err := s.store.LoadAll()
	if err != nil {
		return nil, err
	}
	return withRefCounts(groups, policies), nil
}

func (s *Service) GetPolicies() ([]Policy, error) {
	groups, policies, err := s.store.LoadAll()
	if err != nil {
		return nil, err
	}
	out, err := NormalizeAndValidatePolicies(clonePolicies(policies), groups, policies)
	if err != nil {
		annotateStatuses(policies, groups)
		return policies, nil
	}
	return out, nil
}

func (s *Service) PutGroups(groups []Group) ([]Group, error) {
	prevGroups, policies, err := s.store.LoadAll()
	if err != nil {
		return nil, err
	}
	norm, err := NormalizeAndValidateGroups(groups)
	if err != nil {
		return nil, err
	}
	if err := ensureGroupsNotOrphanDeleted(prevGroups, norm, policies); err != nil {
		return nil, err
	}
	// Re-validate policies against new groups
	if _, err := NormalizeAndValidatePolicies(clonePolicies(policies), norm, policies); err != nil {
		return nil, fmt.Errorf("更新组后策略校验失败: %w", err)
	}
	if err := s.store.SaveAll(norm, policies); err != nil {
		return nil, err
	}
	return withRefCounts(norm, policies), nil
}

func (s *Service) PutPolicies(policies []Policy) ([]Policy, error) {
	groups, prev, err := s.store.LoadAll()
	if err != nil {
		return nil, err
	}
	norm, err := NormalizeAndValidatePolicies(policies, groups, prev)
	if err != nil {
		return nil, err
	}
	if err := s.store.SaveAll(groups, norm); err != nil {
		return nil, err
	}
	return norm, nil
}

func (s *Service) Apply(in ApplyInput) (ApplyResult, error) {
	prevGroups, prevPolicies, err := s.store.LoadAll()
	if err != nil {
		return ApplyResult{}, err
	}
	groups := in.Groups
	if groups == nil {
		groups = prevGroups
	}
	policies := in.Policies
	if policies == nil {
		policies = prevPolicies
	}
	normGroups, err := NormalizeAndValidateGroups(groups)
	if err != nil {
		return ApplyResult{}, err
	}
	if err := ensureGroupsNotOrphanDeleted(prevGroups, normGroups, policies); err != nil {
		return ApplyResult{}, err
	}
	normPolicies, err := NormalizeAndValidatePolicies(policies, normGroups, prevPolicies)
	if err != nil {
		return ApplyResult{}, err
	}
	if err := s.store.SaveAll(normGroups, normPolicies); err != nil {
		return ApplyResult{}, err
	}
	env := s.envFn()
	if err := s.ApplyDataplane(normGroups, normPolicies, env); err != nil {
		writeOverlayMeta(s.overlayMetaPath(), false, err.Error())
		return ApplyResult{
			Groups:           withRefCounts(normGroups, normPolicies),
			Policies:         normPolicies,
			DataplaneApplied: false,
			DataplaneNote:    "配置已存盘，但数据面 apply 失败: " + err.Error(),
			DomainMap:        s.LoadDomainMap(),
		}, nil
	}
	_, note := readOverlayMeta(s.overlayMetaPath())
	return ApplyResult{
		Groups:           withRefCounts(normGroups, normPolicies),
		Policies:         normPolicies,
		DataplaneApplied: true,
		DataplaneNote:    note,
		DomainMap:        s.LoadDomainMap(),
	}, nil
}

func (s *Service) Probe(req ProbeRequest) (ProbeResult, error) {
	groups, policies, err := s.store.LoadAll()
	if err != nil {
		return ProbeResult{}, err
	}
	env := s.envFn()
	domain := strings.TrimSpace(req.ProbeDomain)
	if domain != "" && len(req.ResolvedIPs) == 0 {
		if ips, err := ResolveDomainForProbe(domain); err == nil {
			req.ResolvedIPs = ips
		}
	}
	snap := CollectSnapshot()
	dst := strings.TrimSpace(req.ProbeDst)
	if dst == "" && len(req.ResolvedIPs) > 0 {
		dst = req.ResolvedIPs[0]
	}
	enrichSnapshotForProbe(&snap, dst)
	res, err := Probe(req, groups, policies, env, snap)
	if err != nil {
		return ProbeResult{}, err
	}
	if domain != "" {
		res.ResolveSource = ResolveViaUnbound
	}
	applied, note := readOverlayMeta(s.overlayMetaPath())
	if applied {
		res.DataplaneNote = note
	}
	return res, nil
}

func (s *Service) SystemRules() (SystemRules, error) {
	groups, policies, err := s.store.LoadAll()
	if err != nil {
		return SystemRules{}, err
	}
	env := s.envFn()
	snap := CollectSnapshot()
	markPath := fmt.Sprintf("%s → table %s → %s", env.Mark, env.Table, env.Tun)

	sets := map[string]SetView{
		"TO_CN": {
			Name: "TO_CN", Count: snap.TOCNCount, Sample: snap.TOCN, Writable: "readonly",
		},
		"bypass_ip": {
			Name: "bypass_ip", Count: snap.BypassCount, Sample: snap.BypassIP, Writable: "system_merge_only",
		},
		"ext_const": {
			Name: "ext_const", Count: snap.ExtConstCount, Sample: snap.ExtConst, Writable: "readonly",
		},
		"ext": {
			Name: "ext", Count: snap.ExtCount, Sample: snap.Ext, Writable: "readonly",
		},
	}

	defaults := []SystemRule{
		{ID: "safety_bypass", Name: "bypass_ip 安全轨", Action: ActionDirect, Layer: LayerSafety},
		{ID: "safety_rfc1918", Name: "RFC1918 / 本机", Action: ActionDirect, Layer: LayerSafety},
		{ID: "sys_ext_const", Name: "ext_const → 代理", Action: ActionProxy, Layer: LayerSystem},
		{ID: "sys_to_cn", Name: "TO_CN → 直连", Action: ActionDirect, Layer: LayerSystem},
		{ID: "sys_catch_all", Name: "其余 → 打标进代理", Action: ActionProxy, Layer: LayerSystem},
	}
	for i := range defaults {
		for _, p := range policies {
			if !p.Enabled {
				continue
			}
			if p.OverridesSystem {
				defaults[i].CoveredBy = p.ID
				defaults[i].CoveredByName = p.Name
				break
			}
		}
	}

	annotated, _ := NormalizeAndValidatePolicies(clonePolicies(policies), groups, policies)
	if annotated == nil {
		annotated = policies
		annotateStatuses(annotated, groups)
	}

	applied, note := readOverlayMeta(s.overlayMetaPath())

	return SystemRules{
		ProxyMode:   env.ProxyMode,
		RoutingMode: env.RoutingMode,
		MarkPath:    markPath,
		SafetyRailHealth: map[string]any{
			"bypass_ip_count": snap.BypassCount,
			"mark_path_ok":    strings.Contains(snap.IPRules, "2022") || strings.Contains(snap.Table2022, env.Tun),
			"table_2022":      snap.Table2022 != "",
		},
		Sets:              sets,
		CustomerHostsHint: "旁路 @customer_hosts 在「设备运行模式」页维护，不在本页改写",
		DefaultRules:      defaults,
		UserOverrides:     annotated,
		IPRules:           snap.IPRules,
		Table2022:         snap.Table2022,
		DataplaneApplied:  applied,
		DataplaneNote:     note,
		SnapshotSource:    snap.Source,
		DomainMap:         s.LoadDomainMap(),
	}, nil
}

func (s *Service) Effective() (Effective, error) {
	groups, err := s.GetGroups()
	if err != nil {
		return Effective{}, err
	}
	policies, err := s.GetPolicies()
	if err != nil {
		return Effective{}, err
	}
	env := s.envFn()
	applied, note := readOverlayMeta(s.overlayMetaPath())
	return Effective{
		Groups:           groups,
		Policies:         policies,
		ProxyMode:        env.ProxyMode,
		MarkPath:         fmt.Sprintf("%s → table %s → %s", env.Mark, env.Table, env.Tun),
		DataplaneApplied: applied,
		DataplaneNote:    note,
		DomainMap:        s.LoadDomainMap(),
	}, nil
}

func (s *Service) DomainMapView() DomainMap {
	return s.LoadDomainMap()
}
