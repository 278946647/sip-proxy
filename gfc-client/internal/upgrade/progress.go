package upgrade

import (
	"sync"
	"time"
)

// Progress describes an in-flight or last-finished upgrade job for UI polling.
type Progress struct {
	Phase      string `json:"phase"` // idle|checking|downloading|extracting|installing|done|failed
	Percent    int    `json:"percent"`
	Message    string `json:"message"`
	Source     string `json:"source,omitempty"` // platform|local|upload
	Version    string `json:"version,omitempty"`
	Busy       bool   `json:"busy"`
	UpdatedAt  string `json:"updated_at,omitempty"`
	LastResult string `json:"last_result,omitempty"`
}

var (
	progMu sync.Mutex
	prog   = Progress{Phase: "idle", Percent: 0, Message: "idle"}
)

func GetProgress() Progress {
	progMu.Lock()
	defer progMu.Unlock()
	return prog
}

func setProgress(phase string, percent int, message, source, version string) {
	progMu.Lock()
	defer progMu.Unlock()
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	prog.Phase = phase
	prog.Percent = percent
	prog.Message = message
	if source != "" {
		prog.Source = source
	}
	if version != "" {
		prog.Version = version
	}
	prog.Busy = phase != "idle" && phase != "done" && phase != "failed"
	prog.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	if phase == "done" || phase == "failed" {
		prog.LastResult = message
		prog.Busy = false
	}
}

func TryBegin(source string) bool {
	progMu.Lock()
	defer progMu.Unlock()
	if prog.Busy {
		return false
	}
	prog = Progress{
		Phase:     "checking",
		Percent:   1,
		Message:   "starting",
		Source:    source,
		Busy:      true,
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	return true
}

func FinishOK(message, version string) {
	setProgress("done", 100, message, "", version)
}

func FinishFail(message string) {
	progMu.Lock()
	p := prog.Percent
	progMu.Unlock()
	setProgress("failed", p, message, "", "")
}
