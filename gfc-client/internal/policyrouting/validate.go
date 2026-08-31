package policyrouting

import (
	"fmt"
	"strings"
)

// NormalizeAndValidateGroups normalizes members and assigns missing IDs.
func NormalizeAndValidateGroups(groups []Group) ([]Group, error) {
	out := make([]Group, 0, len(groups))
	seenID := map[string]struct{}{}
	seenName := map[string]struct{}{}
	for i, g := range groups {
		g.ID = trimID(g.ID)
		g.Name = strings.TrimSpace(g.Name)
		g.Kind = strings.TrimSpace(strings.ToLower(g.Kind))
		g.Description = strings.TrimSpace(g.Description)
		if g.Name == "" {
			return nil, fmt.Errorf("组 #%d 名称不能为空", i+1)
		}
		if _, ok := seenName[strings.ToLower(g.Name)]; ok {
			return nil, fmt.Errorf("组名称重复: %s", g.Name)
		}
		seenName[strings.ToLower(g.Name)] = struct{}{}
		switch g.Kind {
		case KindSrcCIDR, KindDstCIDR, KindDomain:
		default:
			return nil, fmt.Errorf("组 %q 类型无效: %s（允许 src_cidr|dst_cidr|domain）", g.Name, g.Kind)
		}
		members, err := normalizeMembers(g.Kind, g.Members)
		if err != nil {
			return nil, fmt.Errorf("组 %q: %w", g.Name, err)
		}
		g.Members = members
		if g.ID == "" {
			g.ID = newID("g_")
		}
		if _, ok := seenID[g.ID]; ok {
			return nil, fmt.Errorf("组 id 重复: %s", g.ID)
		}
		seenID[g.ID] = struct{}{}
		out = append(out, g)
	}
	return out, nil
}

// NormalizeAndValidatePolicies validates Override rules against groups.
// existingPolicies supplies prior danger_ack for same-id updates when body omits ack.
func NormalizeAndValidatePolicies(policies []Policy, groups []Group, existing []Policy) ([]Policy, error) {
	gm := groupMap(groups)
	existingByID := map[string]Policy{}
	for _, p := range existing {
		existingByID[p.ID] = p
	}

	out := make([]Policy, 0, len(policies))
	seenID := map[string]struct{}{}
	seenName := map[string]struct{}{}

	for i, p := range policies {
		p.ID = trimID(p.ID)
		p.Name = strings.TrimSpace(p.Name)
		p.MatchSrcGroupID = trimID(p.MatchSrcGroupID)
		p.MatchDstGroupID = trimID(p.MatchDstGroupID)
		p.MatchDomainGroupID = trimID(p.MatchDomainGroupID)
		p.Action = strings.TrimSpace(strings.ToLower(p.Action))
		p.Notes = strings.TrimSpace(p.Notes)
		p.Rank = i // UI list order is authoritative: first row = highest priority

		if p.Name == "" {
			return nil, fmt.Errorf("策略 #%d 名称不能为空", i+1)
		}
		if _, ok := seenName[strings.ToLower(p.Name)]; ok {
			return nil, fmt.Errorf("策略名称重复: %s", p.Name)
		}
		seenName[strings.ToLower(p.Name)] = struct{}{}

		switch p.Action {
		case ActionDirect, ActionProxy:
		default:
			return nil, fmt.Errorf("策略 %q 动作无效: %s（允许 direct|proxy）", p.Name, p.Action)
		}

		hasSrc := p.MatchSrcGroupID != ""
		hasDst := p.MatchDstGroupID != ""
		hasDom := p.MatchDomainGroupID != ""
		if !hasSrc && !hasDst && !hasDom {
			return nil, fmt.Errorf("策略 %q 源与目的/域名不能同时为空", p.Name)
		}
		if hasDst && hasDom {
			return nil, fmt.Errorf("策略 %q 目的组与域名组互斥", p.Name)
		}

		if hasSrc {
			g, ok := gm[p.MatchSrcGroupID]
			if !ok {
				return nil, fmt.Errorf("策略 %q 源组不存在: %s", p.Name, p.MatchSrcGroupID)
			}
			if g.Kind != KindSrcCIDR {
				return nil, fmt.Errorf("策略 %q 源组必须是 src_cidr", p.Name)
			}
		}
		if hasDst {
			g, ok := gm[p.MatchDstGroupID]
			if !ok {
				return nil, fmt.Errorf("策略 %q 目的组不存在: %s", p.Name, p.MatchDstGroupID)
			}
			if g.Kind != KindDstCIDR {
				return nil, fmt.Errorf("策略 %q 目的组必须是 dst_cidr", p.Name)
			}
		}
		if hasDom {
			g, ok := gm[p.MatchDomainGroupID]
			if !ok {
				return nil, fmt.Errorf("策略 %q 域名组不存在: %s", p.Name, p.MatchDomainGroupID)
			}
			if g.Kind != KindDomain {
				return nil, fmt.Errorf("策略 %q 域名组必须是 domain", p.Name)
			}
		}

		srcOnly := hasSrc && !hasDst && !hasDom
		overrides := actionOverridesSystem(p.Action, hasDst || hasDom)
		p.OverridesSystem = overrides || srcOnly

		var danger []string
		if srcOnly {
			label := "直连"
			if p.Action == ActionProxy {
				label = "进代理"
			}
			danger = append(danger, fmt.Sprintf(DangerSrcOnly, label))
		} else if overrides {
			danger = append(danger, DangerOverride)
		}
		p.DangerTexts = danger

		needAck := len(danger) > 0
		if needAck {
			prev, hadPrev := existingByID[p.ID]
			acked := p.DangerAck || (hadPrev && prev.DangerAck && sameMatchAndAction(prev, p))
			if !acked {
				return nil, fmt.Errorf("策略 %q 须勾选 danger_ack：%s", p.Name, strings.Join(danger, " "))
			}
			p.DangerAck = true
		} else {
			p.DangerAck = false
		}

		if p.ID == "" {
			p.ID = newID("ovr_")
		}
		if _, ok := seenID[p.ID]; ok {
			return nil, fmt.Errorf("策略 id 重复: %s", p.ID)
		}
		seenID[p.ID] = struct{}{}
		out = append(out, p)
	}

	if err := rejectConflictingPolicies(out, groups); err != nil {
		return nil, err
	}
	annotateStatuses(out, groups)
	return out, nil
}

func sameMatchAndAction(a, b Policy) bool {
	return a.MatchSrcGroupID == b.MatchSrcGroupID &&
		a.MatchDstGroupID == b.MatchDstGroupID &&
		a.MatchDomainGroupID == b.MatchDomainGroupID &&
		a.Action == b.Action
}

// actionOverridesSystem marks CN→proxy / international→direct style overrides.
// Without live IP classification we treat any explicit dst/domain + opposite-of-common-default as needing ack:
// proxy with destination match, or direct with destination match.
func actionOverridesSystem(action string, hasDestMatch bool) bool {
	if !hasDestMatch {
		return false
	}
	return action == ActionProxy || action == ActionDirect
}

func rejectConflictingPolicies(policies []Policy, groups []Group) error {
	gm := groupMap(groups)
	enabled := make([]Policy, 0, len(policies))
	for _, p := range policies {
		if p.Enabled {
			enabled = append(enabled, p)
		}
	}
	for i := 0; i < len(enabled); i++ {
		for j := i + 1; j < len(enabled); j++ {
			a, b := enabled[i], enabled[j]
			if a.Action == b.Action {
				continue
			}
			if !policiesMayConflict(a, b, gm) {
				continue
			}
			if a.Rank == b.Rank {
				return fmt.Errorf("策略 %q 与 %q 同优先级且动作相反，请调整顺序或合并", a.Name, b.Name)
			}
		}
	}
	return nil
}

func policiesMayConflict(a, b Policy, gm map[string]Group) bool {
	if !srcCompatible(a, b, gm) {
		return false
	}
	return destCompatible(a, b, gm)
}

func srcCompatible(a, b Policy, gm map[string]Group) bool {
	if a.MatchSrcGroupID == "" || b.MatchSrcGroupID == "" {
		return true
	}
	if a.MatchSrcGroupID == b.MatchSrcGroupID {
		return true
	}
	ga, oka := gm[a.MatchSrcGroupID]
	gb, okb := gm[b.MatchSrcGroupID]
	if !oka || !okb {
		return false
	}
	return listsIntersect(ga.Members, gb.Members)
}

func destCompatible(a, b Policy, gm map[string]Group) bool {
	aAny := a.MatchDstGroupID == "" && a.MatchDomainGroupID == ""
	bAny := b.MatchDstGroupID == "" && b.MatchDomainGroupID == ""
	if aAny || bAny {
		return true
	}
	if a.MatchDstGroupID != "" && b.MatchDstGroupID != "" {
		if a.MatchDstGroupID == b.MatchDstGroupID {
			return true
		}
		ga, oka := gm[a.MatchDstGroupID]
		gb, okb := gm[b.MatchDstGroupID]
		if !oka || !okb {
			return false
		}
		return listsIntersect(ga.Members, gb.Members)
	}
	if a.MatchDomainGroupID != "" && b.MatchDomainGroupID != "" {
		if a.MatchDomainGroupID == b.MatchDomainGroupID {
			return true
		}
		ga, oka := gm[a.MatchDomainGroupID]
		gb, okb := gm[b.MatchDomainGroupID]
		if !oka || !okb {
			return false
		}
		for _, da := range ga.Members {
			for _, db := range gb.Members {
				if membersMayMatchSameQName(da, db) {
					return true
				}
			}
		}
		return false
	}
	// dst vs domain: cannot prove intersection without resolution — allow save; probe resolves.
	return false
}

func annotateStatuses(policies []Policy, groups []Group) {
	gm := groupMap(groups)
	for i := range policies {
		p := &policies[i]
		if !p.Enabled {
			p.Status = StatusShadowed
			p.Reason = "已禁用"
			continue
		}
		p.Status = StatusActive
		p.Reason = "将按用户 Override 优先级参与合成"
		for j := 0; j < i; j++ {
			prev := policies[j]
			if !prev.Enabled {
				continue
			}
			if policiesMayConflict(prev, *p, gm) {
				p.Status = StatusShadowed
				p.Reason = fmt.Sprintf("可能被更高优先级 Override#%s（%s）遮蔽", prev.ID, prev.Name)
				break
			}
		}
	}
}

func withRefCounts(groups []Group, policies []Policy) []Group {
	counts := map[string]int{}
	for _, p := range policies {
		if p.MatchSrcGroupID != "" {
			counts[p.MatchSrcGroupID]++
		}
		if p.MatchDstGroupID != "" {
			counts[p.MatchDstGroupID]++
		}
		if p.MatchDomainGroupID != "" {
			counts[p.MatchDomainGroupID]++
		}
	}
	out := cloneGroups(groups)
	for i := range out {
		out[i].RefCount = counts[out[i].ID]
	}
	return out
}

func ensureGroupsNotOrphanDeleted(prev, next []Group, policies []Policy) error {
	nextIDs := map[string]struct{}{}
	for _, g := range next {
		nextIDs[g.ID] = struct{}{}
	}
	for _, g := range prev {
		if _, ok := nextIDs[g.ID]; ok {
			continue
		}
		for _, p := range policies {
			if p.MatchSrcGroupID == g.ID || p.MatchDstGroupID == g.ID || p.MatchDomainGroupID == g.ID {
				return fmt.Errorf("组 %q 仍被策略 %q 引用，不能删除", g.Name, p.Name)
			}
		}
	}
	return nil
}
