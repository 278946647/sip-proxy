package traffic

import (
	"log"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/dataplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/stats"
	"github.com/278946647/sip-proxy/gfc-client/internal/store"
)

type ifaceState struct {
	lastRx, lastTx uint64
	hasLast        bool
}

type Recorder struct {
	store  *store.Store
	states map[string]*ifaceState
}

func NewRecorder(st *store.Store) *Recorder {
	return &Recorder{
		store:  st,
		states: map[string]*ifaceState{},
	}
}

func (r *Recorder) Run(engine *dataplane.Engine) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		ifaces := DiscoverMonitorIfaces(!engine.IsDirectMode())
		active := map[string]struct{}{}
		for _, iface := range ifaces {
			active[iface] = struct{}{}
			if err := r.tick(iface); err != nil {
				log.Printf("traffic recorder %s: %v", iface, err)
			}
		}
		r.pruneStates(active)
	}
}

func (r *Recorder) pruneStates(active map[string]struct{}) {
	for name := range r.states {
		if _, ok := active[name]; !ok {
			delete(r.states, name)
		}
	}
}

func (r *Recorder) state(iface string) *ifaceState {
	st, ok := r.states[iface]
	if !ok {
		st = &ifaceState{}
		r.states[iface] = st
	}
	return st
}

func (r *Recorder) tick(iface string) error {
	rx, tx, ok := stats.IfaceBytes(iface)
	if !ok {
		return nil
	}
	st := r.state(iface)
	if !st.hasLast {
		st.lastRx = rx
		st.lastTx = tx
		st.hasLast = true
		return nil
	}
	var bytesIn, bytesOut uint64
	if rx >= st.lastRx {
		bytesIn = rx - st.lastRx
	}
	if tx >= st.lastTx {
		bytesOut = tx - st.lastTx
	}
	st.lastRx = rx
	st.lastTx = tx
	return r.store.InsertTrafficSample(iface, bytesIn, bytesOut, time.Now().UTC())
}
