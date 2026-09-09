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

// Supervisor runs passive learning while proxy_mode=transparent.
type Supervisor struct {
	cfg *config.Config

	mu     sync.Mutex
	stop   func()
	last   string
	now    func() time.Time
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
	cancel := startCapture(ports, func(role Role, frame []byte) {
		s.onFrame(role, frame)
	})
	s.stop = cancel
	s.last = key
}

func (s *Supervisor) stopLocked() {
	if s.stop != nil {
		s.stop()
		s.stop = nil
	}
	s.last = ""
}

func (s *Supervisor) onFrame(role Role, frame []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur := LoadLearned(s.cfg)
	if cur.CECandidates == nil {
		cur.CECandidates = map[string]int{}
	}
	before := cur.State + "|" + cur.CEIP + "|" + cur.CPEMAC + "|" + cur.PEMAC + "|" + cur.GWIP
	ApplyFrame(role, frame, &cur)
	after := cur.State + "|" + cur.CEIP + "|" + cur.CPEMAC + "|" + cur.PEMAC + "|" + cur.GWIP
	if before == after {
		return
	}
	if err := SaveLearned(s.cfg, cur); err != nil {
		log.Printf("transparent: save learned: %v", err)
		return
	}
	go refreshDataplane(s.cfg)
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
