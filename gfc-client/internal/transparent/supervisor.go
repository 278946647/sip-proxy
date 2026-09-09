package transparent

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

const refreshDebounce = 2 * time.Second

// Supervisor runs passive learning while proxy_mode=transparent.
type Supervisor struct {
	cfg *config.Config

	mu         sync.Mutex
	stop       func()
	last       string
	learned    Learned
	timer      *time.Timer
	refresh    bool
	refreshCmd *exec.Cmd
	now        func() time.Time
}

func NewSupervisor(cfg *config.Config) *Supervisor {
	return &Supervisor{cfg: cfg, now: func() time.Time { return time.Now().UTC() }}
}

func (s *Supervisor) Notify(mode string) {
	var cancel func()
	s.mu.Lock()
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	s.killRefreshLocked()
	if mode == "transparent" {
		ports := LoadPorts(s.cfg)
		key := ports.ISP + "|" + ports.CPE
		if s.stop != nil && s.last == key {
			s.mu.Unlock()
			return
		}
		cancel = s.stop
		s.stop = nil
		s.last = ""
		s.refresh = false
		s.mu.Unlock()
		if cancel != nil {
			cancel()
		}
		s.beginCapture(ports, key)
		return
	}
	cancel = s.stop
	s.stop = nil
	s.last = ""
	s.refresh = false
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (s *Supervisor) beginCapture(ports Ports, key string) {
	if ports.ISP == "" || ports.CPE == "" {
		return
	}
	st := LoadLearned(s.cfg)
	if st.CECandidates == nil {
		st.CECandidates = map[string]int{}
	}
	cancel := startCapture(ports, func(role Role, frame []byte) {
		s.onFrame(role, frame)
	})
	s.mu.Lock()
	if s.stop != nil {
		s.mu.Unlock()
		cancel()
		return
	}
	s.learned = st
	s.stop = cancel
	s.last = key
	s.mu.Unlock()
}

func (s *Supervisor) killRefreshLocked() {
	if s.refreshCmd != nil && s.refreshCmd.Process != nil {
		_ = s.refreshCmd.Process.Kill()
	}
	s.refreshCmd = nil
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
	s.runRefresh(cfg)

	s.mu.Lock()
	s.refresh = false
	s.refreshCmd = nil
	s.mu.Unlock()
}

func (s *Supervisor) runRefresh(cfg *config.Config) {
	if !proxyModeTransparent() {
		return
	}
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
	s.mu.Lock()
	if s.stop == nil || !proxyModeTransparent() {
		s.mu.Unlock()
		return
	}
	s.refreshCmd = cmd
	s.mu.Unlock()
	_ = cmd.Run()
}

func proxyModeTransparent() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("GFC_PROXY_MODE")), "transparent")
}
