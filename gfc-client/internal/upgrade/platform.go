package upgrade

import (
	"fmt"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/controlplane"
)

// Artifact is a control-plane runtime package available for OTA.
type Artifact struct {
	ID        int    `json:"id"`
	Version   string `json:"version"`
	Arch      string `json:"arch"`
	Filename  string `json:"filename"`
	SHA256    string `json:"sha256"`
	SizeBytes int64  `json:"size_bytes"`
	Notes     string `json:"notes,omitempty"`
}

func RuntimeArch() string {
	switch runtime.GOARCH {
	case "amd64", "x86_64":
		return "amd64"
	case "arm64", "aarch64":
		return "arm64"
	default:
		return runtime.GOARCH
	}
}

var (
	cacheMu       sync.Mutex
	cachedLatest  string
	cachedAvail   bool
	cachedChecked string
	cachedArts    []Artifact
)

func cachePlatform(st Status, arts []Artifact) {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	cachedLatest = st.Latest
	cachedAvail = st.UpdateAvail
	cachedChecked = st.CheckedAt
	cachedArts = arts
}

func CachedPlatform() (latest string, avail bool, checked string, arts []Artifact) {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	return cachedLatest, cachedAvail, cachedChecked, append([]Artifact(nil), cachedArts...)
}

// CheckFromPlatform lists enabled artifacts matching this device arch.
func CheckFromPlatform(client *controlplane.Client) (Status, []Artifact, error) {
	cur := LocalVersion()
	st := Status{
		Current:   cur,
		CheckedAt: time.Now().UTC().Format(time.RFC3339),
		Source:    "platform",
	}
	raw, err := client.ListArtifacts(RuntimeArch())
	if err != nil {
		st.Error = err.Error()
		return st, nil, err
	}
	arts := make([]Artifact, 0, len(raw))
	for _, a := range raw {
		arts = append(arts, Artifact{
			ID: a.ID, Version: a.Version, Arch: a.Arch,
			Filename: a.Filename, SHA256: a.SHA256, SizeBytes: a.SizeBytes, Notes: a.Notes,
		})
	}
	if len(arts) > 0 {
		st.Latest = arts[0].Version
		st.UpdateAvail = st.Latest != "" && st.Latest != cur
	}
	cachePlatform(st, arts)
	return st, arts, nil
}

func applyFromPlatform(client *controlplane.Client, artifactID int) (string, error) {
	setProgress("checking", 5, "fetching artifact list", "platform", "")
	arts, err := client.ListArtifacts(RuntimeArch())
	if err != nil {
		return "", err
	}
	var art *controlplane.Artifact
	for i := range arts {
		if arts[i].ID == artifactID {
			art = &arts[i]
			break
		}
	}
	if art == nil {
		return "", fmt.Errorf("artifact %d not found or wrong arch", artifactID)
	}
	base := strings.TrimRight(client.ActiveServer(), "/")
	url := fmt.Sprintf("%s/clients/artifacts/%d/download", base, art.ID)
	setProgress("downloading", 15, "downloading "+art.Filename, "platform", art.Version)
	return DownloadAndApply(url, client.Token(), art.SHA256, art.Filename)
}

// StartApplyRemote downloads and installs artifact asynchronously.
func StartApplyRemote(client *controlplane.Client, artifactID int) error {
	if client == nil {
		return fmt.Errorf("control plane client required")
	}
	if !TryBegin("platform") {
		return fmt.Errorf("upgrade already in progress")
	}
	go func() {
		msg, err := applyFromPlatform(client, artifactID)
		if err != nil {
			FinishFail(strings.TrimSpace(err.Error() + " " + msg))
			return
		}
		FinishOK(msg, LocalVersion())
	}()
	return nil
}

// StartApplyLocal extracts and installs a local tar.gz asynchronously.
func StartApplyLocal(path, source string) error {
	if !TryBegin(source) {
		return fmt.Errorf("upgrade already in progress")
	}
	go func() {
		setProgress("extracting", 20, "extracting package", source, "")
		msg, err := ApplyLocalPackage(path)
		if err != nil {
			FinishFail(strings.TrimSpace(err.Error() + " " + msg))
			return
		}
		FinishOK(msg, LocalVersion())
	}()
	return nil
}
