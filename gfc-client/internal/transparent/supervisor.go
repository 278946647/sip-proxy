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

const (
	refreshDebounce = 200 * time.Millisecond
	linkPoll        = 50 * time.Millisecond
)

// Supervisor runs passive learning while proxy_mode=transparent.
type Supervisor struct {
	cfg *config.Config

	mu                  sync.Mutex
	stop                func()
	last                string
	learned             Learned
	timer               *time.Timer
	refresh             bool
	refreshCmd          *exec.Cmd
	now                 func() time.Time
	cpeDown             bool
	holdSpareUntilFrame bool
	ifaceDown           func(name string) bool
	boxMAC              func(isp string) string
	debounce            time.Duration
}

func NewSupervisor(cfg *config.Config) *Supervisor {
	return &Supervisor{
		cfg:       cfg,
		now:       func() time.Time { return time.Now().UTC() },
		ifaceDown: defaultIfaceDown,
		boxMAC:    defaultBoxMAC,
		debounce:  refreshDebounce,
	}
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
			s.scheduleFlushLocked()
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
	s.holdSpareUntilFrame = false
	s.cpeDown = false
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (s *Supervisor) beginCapture(ports Ports, key string) {
	if ports.ISP == "" || ports.CPE == "" {
		log.Printf("transparent: capture skipped; isp/cpe not set")
		return
	}
	log.Printf("transparent: capture start isp=%s cpe=%s", ports.ISP, ports.CPE)
	st := LoadLearned(s.cfg)
	if st.CECandidates == nil {
		st.CECandidates = map[string]int{}
	}
	if err := SaveLearned(s.cfg, st); err != nil {
		log.Printf("transparent: sanitize learned: %v", err)
	}
	cancelCap := startCapture(ports, func(role Role, frame []byte) {
		s.onFrame(role, frame)
	})
	linkStop := make(chan struct{})
	var linkOnce sync.Once
	cancel := func() {
		cancelCap()
		linkOnce.Do(func() { close(linkStop) })
	}
	s.mu.Lock()
	if s.stop != nil {
		s.mu.Unlock()
		cancel()
		return
	}
	s.learned = st
	s.cpeDown = s.readDown(ports.CPE)
	s.holdSpareUntilFrame = s.cpeDown
	s.stop = cancel
	s.last = key
	id := s.currentHitchLocked(ports)
	s.mu.Unlock()
	go s.watchLink(linkStop, ports.CPE)
	if err := SaveHitch(s.cfg, id); err != nil {
		log.Printf("transparent: save hitch: %v", err)
	}
	s.runRefresh(s.cfg)
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
	ports := LoadPorts(s.cfg)
	before := cur.State + "|" + cur.CEIP + "|" + cur.CPEMAC + "|" + cur.PEMAC + "|" + cur.GWIP + "|" + cur.HostSig()
	beforeHitch := s.currentHitchLocked(ports).Sig()
	ApplyFrame(role, frame, &cur)
	ApplySpareARP(role, frame, &cur, LoadSpare(s.cfg))
	if role == RoleCPE && frameUsableHitchHost(frame, cur.GWIP) {
		s.holdSpareUntilFrame = false
	}
	after := cur.State + "|" + cur.CEIP + "|" + cur.CPEMAC + "|" + cur.PEMAC + "|" + cur.GWIP + "|" + cur.HostSig()
	s.learned = cur
	afterHitch := s.currentHitchLocked(ports).Sig()
	if before == after && beforeHitch == afterHitch {
		return
	}
	s.scheduleFlushLocked()
}

func (s *Supervisor) applyCPEDown(down bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stop == nil || s.cpeDown == down {
		return
	}
	s.cpeDown = down
	if down {
		s.holdSpareUntilFrame = true
	}
	s.scheduleFlushLocked()
}

func (s *Supervisor) watchLink(stop <-chan struct{}, cpe string) {
	s.applyCPEDown(s.readDown(cpe))
	ticker := time.NewTicker(linkPoll)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			s.applyCPEDown(s.readDown(cpe))
		}
	}
}

func (s *Supervisor) readDown(name string) bool {
	if s.ifaceDown != nil {
		return s.ifaceDown(name)
	}
	return defaultIfaceDown(name)
}

func (s *Supervisor) currentHitchLocked(ports Ports) HitchIdentity {
	box := ""
	if s.boxMAC != nil {
		box = s.boxMAC(ports.ISP)
	} else {
		box = defaultBoxMAC(ports.ISP)
	}
	return ComputeHitch(HitchInput{
		Learned:             s.learned,
		Spare:               LoadSpare(s.cfg),
		CPEDown:             s.cpeDown,
		HoldSpareUntilFrame: s.holdSpareUntilFrame,
		BoxMAC:              box,
	})
}

func (s *Supervisor) scheduleFlushLocked() {
	if s.timer != nil {
		return
	}
	d := s.debounce
	if d <= 0 {
		d = refreshDebounce
	}
	s.timer = time.AfterFunc(d, s.flush)
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
	ports := LoadPorts(s.cfg)
	id := s.currentHitchLocked(ports)
	s.refresh = true
	cfg := s.cfg
	s.mu.Unlock()

	log.Printf("transparent: learned state=%s ce=%s gw=%s cpe_mac=%s pe_mac=%s hitch=%s ip=%s mac=%s",
		snap.State, snap.CEIP, snap.GWIP, snap.CPEMAC, snap.PEMAC, id.Mode, id.IP, id.SrcMAC)
	if err := SaveLearned(cfg, snap); err != nil {
		log.Printf("transparent: save learned: %v", err)
	}
	if err := SaveHitch(cfg, id); err != nil {
		log.Printf("transparent: save hitch: %v", err)
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
	out, err := cmd.CombinedOutput()
	msg := strings.TrimSpace(string(out))
	if err != nil {
		log.Printf("transparent: refresh-trans: %v (%s)", err, msg)
		return
	}
	if msg != "" {
		log.Printf("transparent: refresh-trans: %s", msg)
	}
}

func proxyModeTransparent() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("GFC_PROXY_MODE")), "transparent")
}

func defaultIfaceDown(name string) bool {
	name = strings.TrimSpace(name)
	if name == "" {
		return true
	}
	b, err := os.ReadFile("/sys/class/net/" + name + "/carrier")
	if err == nil {
		return strings.TrimSpace(string(b)) != "1"
	}
	op, err := os.ReadFile("/sys/class/net/" + name + "/operstate")
	if err != nil {
		return true
	}
	switch strings.ToLower(strings.TrimSpace(string(op))) {
	case "up", "unknown":
		return false
	default:
		return true
	}
}

func defaultBoxMAC(isp string) string {
	for _, n := range []string{BridgeName, strings.TrimSpace(isp)} {
		if n == "" {
			continue
		}
		b, err := os.ReadFile("/sys/class/net/" + n + "/address")
		if err != nil {
			continue
		}
		mac := strings.ToLower(strings.TrimSpace(string(b)))
		if mac != "" && mac != "00:00:00:00:00:00" {
			return mac
		}
	}
	return ""
}
