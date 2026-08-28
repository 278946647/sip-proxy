package upgrade

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

// OTAResult is persisted by upgrade-runtime.sh before restarting gfc-api/gfc-agent,
// so a killed parent can still observe success on the next process start.
type OTAResult struct {
	Status    string `json:"status"` // ok|failed
	Version   string `json:"version,omitempty"`
	RequestID string `json:"request_id,omitempty"`
	Message   string `json:"message,omitempty"`
	At        string `json:"at,omitempty"`
}

func stateDir() string {
	return filepath.Join(config.ResolveLib(), "state")
}

func logDir() string {
	if v := strings.TrimSpace(os.Getenv("GFC_LOG_DIR")); v != "" {
		return v
	}
	return "/var/log/gfc-client"
}

// ResultFilePath is the on-disk marker written by the install script.
func ResultFilePath() string {
	if v := strings.TrimSpace(os.Getenv("GFC_OTA_RESULT_FILE")); v != "" {
		return v
	}
	return filepath.Join(stateDir(), "ota-result.json")
}

func ClearOTAResult() {
	_ = os.Remove(ResultFilePath())
}

func ReadOTAResult() *OTAResult {
	data, err := os.ReadFile(ResultFilePath())
	if err != nil || len(data) == 0 {
		return nil
	}
	var r OTAResult
	if json.Unmarshal(data, &r) != nil {
		return nil
	}
	if strings.TrimSpace(r.Status) == "" {
		return nil
	}
	return &r
}

// AlreadyAtVersion reports whether local runtime already matches the target.
func AlreadyAtVersion(target string) bool {
	target = strings.TrimSpace(target)
	if target == "" {
		return false
	}
	return LocalVersion() == target
}

// ResultSatisfies returns true when a persisted OTA result covers this command.
func ResultSatisfies(targetVersion, requestID string) bool {
	r := ReadOTAResult()
	if r == nil || !strings.EqualFold(r.Status, "ok") {
		return false
	}
	req := strings.TrimSpace(requestID)
	if req != "" && strings.TrimSpace(r.RequestID) == req {
		return true
	}
	ver := strings.TrimSpace(targetVersion)
	if ver != "" && strings.TrimSpace(r.Version) == ver {
		return true
	}
	return false
}

// HydrateProgressFromDisk updates in-memory progress after api/agent restart.
func HydrateProgressFromDisk() {
	r := ReadOTAResult()
	if r == nil {
		return
	}
	progMu.Lock()
	busy := prog.Busy
	phase := prog.Phase
	progMu.Unlock()
	if busy || (phase != "idle" && phase != "") {
		return
	}
	msg := strings.TrimSpace(r.Message)
	if msg == "" {
		msg = "ota result from " + r.At
	}
	if strings.EqualFold(r.Status, "ok") {
		ver := r.Version
		if ver == "" {
			ver = LocalVersion()
		}
		setProgress("done", 100, msg, "platform", ver)
		return
	}
	setProgress("failed", 0, msg, "platform", r.Version)
}

func resultEnv(version, requestID string) []string {
	env := []string{
		"GFC_SAFE_INSTALL=1",
		"GFC_OTA_RESULT_FILE=" + ResultFilePath(),
	}
	if v := strings.TrimSpace(version); v != "" {
		env = append(env, "GFC_UPGRADE_VERSION="+v)
	}
	if id := strings.TrimSpace(requestID); id != "" {
		env = append(env, "GFC_OTA_REQUEST_ID="+id)
	}
	return env
}
