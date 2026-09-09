package transparent

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

const refreshDebounce = 2 * time.Second

// Supervisor runs passive learning while proxy_mode=transparent.
type Supervisor struct {
	cfg *config.Config

	mu       sync.Mutex
	stop     func()
	last     string
	learned  Learned
	timer    *time.Timer
	refresh  bool
	now      func() time.Time
}

func NewSupervisor(cfg *config.Config) *Supervisor {
	return &Supervisor{cfg: cfg, now: func() time.Time { return time.Now().UTC() }}
}

func (s *Supervisor) Notify(mode string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if mode != "transparent" {
		s.stopLocked()
		return
	}
	ports := LoadPorts(s.cfg)
	key := ports.ISP + "|" + ports.CPE
	if s.stop != nil && s.last == key {
		return
	}
	s.stopLocked()
	if ports.ISP == "" || ports.CPE == "" {
		return
	}
	st := LoadLearned(s.cfg)
	if st.CECandidates == nil {
		st.CECandidates = map[string]int{}
	}
	s.learned = st
	cancel := startCapture(ports, func(role Role, frame []byte) {
		s.onFrame(role, frame)
	})
	s.stop = cancel
	s.last = key
}

func (s *Supervisor) stopLocked() {
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	if s.stop != nil {
		s.stop()
		s.stop = nil
	}
	s.last = ""
	s.refresh = false
}

func (s *Supervisor) onFrame(role Role, frame []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stop == nil {
		return
	}
	cur := s.learned
	if cur.CECandidates == nil {
		cur.CECandidates = map[string]int{}
	}
	before := cur.State + "|" + cur.CEIP + "|" + cur.CPEMAC + "|" + cur.PEMAC + "|" + cur.GWIP
	ApplyFrame(role, frame, &cur)
	after := cur.State + "|" + cur.CEIP + "|" + cur.CPEMAC + "|" + cur.PEMAC + "|" + cur.GWIP
	s.learned = cur
	if before == after {
		return
	}
	s.scheduleFlushLocked()
}

func (s *Supervisor) scheduleFlushLocked() {
	if s.timer != nil {
		return
	}
	s.timer = time.AfterFunc(refreshDebounce, s.flush)
}

func (s *Supervisor) flush() {
	s.mu.Lock()
	s.timer = nil
	if s.stop == nil {
		s.mu.Unlock()
		return
	}
	if s.refresh {
		s.scheduleFlushLocked()
		s.mu.Unlock()
		return
	}
	snap := s.learned
	s.refresh = true
	cfg := s.cfg
	s.mu.Unlock()

	if err := SaveLearned(cfg, snap); err != nil {
		log.Printf("transparent: save learned: %v", err)
	}
	refreshDataplane(cfg)

	s.mu.Lock()
	s.refresh = false
	s.mu.Unlock()
}

func refreshDataplane(cfg *config.Config) {
	script := filepath.Join(cfg.Paths.Root, "deploy", "gfc-routing.sh")
	if platform.IsOpenWrt() {
		ow := filepath.Join(cfg.Paths.Root, "deploy", "immortalwrt", "gfc-routing.sh")
		if _, err := os.Stat(ow); err == nil {
			script = ow
		}
	}
	if _, err := os.Stat(script); err != nil {
		return
	}
	cmd := exec.Command("sh", script, "refresh-trans")
	cmd.Env = os.Environ()
	_ = cmd.Run()
}
