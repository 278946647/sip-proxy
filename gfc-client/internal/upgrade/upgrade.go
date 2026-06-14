package upgrade

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

type Status struct {
	Current     string `json:"current"`
	Latest      string `json:"latest,omitempty"`
	UpdateAvail bool   `json:"update_available"`
	CheckedAt   string `json:"checked_at,omitempty"`
	Source      string `json:"source,omitempty"`
	Error       string `json:"error,omitempty"`
}

func LocalVersion() string {
	paths := []string{
		os.Getenv("GFC_ROOT") + "/VERSION",
		"/opt/gfc-client/VERSION",
	}
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err == nil {
			if v := strings.TrimSpace(string(data)); v != "" {
				return v
			}
		}
	}
	return config.Version
}

func Check(manifestURL string) Status {
	cur := LocalVersion()
	st := Status{Current: cur, CheckedAt: time.Now().UTC().Format(time.RFC3339)}
	url := strings.TrimSpace(manifestURL)
	if url == "" {
		url = strings.TrimSpace(os.Getenv("GFC_UPGRADE_MANIFEST_URL"))
	}
	if url == "" {
		st.Source = "local"
		return st
	}
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		st.Error = err.Error()
		return st
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		st.Error = err.Error()
		return st
	}
	var manifest struct {
		Version string `json:"version"`
		URL     string `json:"url"`
	}
	if err := json.Unmarshal(body, &manifest); err != nil {
		st.Error = fmt.Sprintf("parse manifest: %v", err)
		return st
	}
	st.Source = url
	st.Latest = strings.TrimSpace(manifest.Version)
	st.UpdateAvail = st.Latest != "" && st.Latest != cur
	return st
}
