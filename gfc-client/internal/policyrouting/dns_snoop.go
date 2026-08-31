package policyrouting

import (
	"sync"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

type snoopTarget struct {
	GroupID string
	SetName string
	Members []string
}

var (
	snoopOnce sync.Once
	snoopKick = make(chan struct{}, 1)
)

// NotifySnoopReload asks the gfc-api snoop loop to reload domain-group patterns.
func NotifySnoopReload() {
	select {
	case snoopKick <- struct{}{}:
	default:
	}
}

// StartDNSSnoop starts a process-wide UDP/53 observer (Linux AF_PACKET). No-op elsewhere.
func StartDNSSnoop(cfg *config.Config, envFn func() Env) {
	if cfg == nil {
		return
	}
	if envFn == nil {
		envFn = DefaultEnv
	}
	snoopOnce.Do(func() {
		go startDNSSnoopImpl(cfg, envFn)
	})
}

func loadSnoopTargets(cfg *config.Config) []snoopTarget {
	if cfg == nil {
		return nil
	}
	st := NewStore(cfg)
	groups, policies, err := st.LoadAll()
	if err != nil {
		return nil
	}
	needed := collectNeededGroups(policies, groupMap(groups))
	var out []snoopTarget
	for _, g := range needed {
		if g.Kind != KindDomain {
			continue
		}
		out = append(out, snoopTarget{
			GroupID: g.ID,
			SetName: setNameFor(g),
			Members: append([]string{}, g.Members...),
		})
	}
	return out
}
