package upgrade

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
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
	LastResult  string `json:"last_result,omitempty"`
}

func LocalVersion() string {
	paths := []string{
		os.Getenv("GFC_ROOT") + "/VERSION",
		"/usr/lib/gfc-client/VERSION",
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

// ApplyLocalPackage extracts and runs install.sh / upgrade-runtime.sh for a local tar.gz.
func ApplyLocalPackage(tarPath string) (string, error) {
	tarPath = strings.TrimSpace(tarPath)
	if tarPath == "" {
		return "", fmt.Errorf("empty package path")
	}
	if _, err := os.Stat(tarPath); err != nil {
		return "", err
	}
	work, err := os.MkdirTemp("", "gfc-upgrade-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(work)

	cmd := exec.Command("tar", "xzf", tarPath, "-C", work)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("tar extract: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	install := findInstallScript(work)
	if install == "" {
		return "", fmt.Errorf("install.sh not found in package")
	}
	c := exec.Command("sh", install)
	c.Dir = filepath.Dir(install)
	c.Env = append(os.Environ(), "GFC_SAFE_INSTALL=1")
	out2, err := c.CombinedOutput()
	msg := strings.TrimSpace(string(out2))
	if err != nil {
		return msg, fmt.Errorf("install failed: %w (%s)", err, msg)
	}
	return msg, nil
}

func findInstallScript(root string) string {
	var found string
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		if info.Name() == "install.sh" {
			found = path
			return io.EOF
		}
		return nil
	})
	return found
}

// DownloadAndApply downloads package with bearer token, verifies sha256, then applies.
func DownloadAndApply(downloadURL, token, expectSHA, filename string) (string, error) {
	if strings.TrimSpace(downloadURL) == "" {
		return "", fmt.Errorf("empty download url")
	}
	tmpDir, err := os.MkdirTemp("", "gfc-ota-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmpDir)
	if filename == "" {
		filename = "runtime.tar.gz"
	}
	dest := filepath.Join(tmpDir, filepath.Base(filename))

	req, err := http.NewRequest("GET", downloadURL, nil)
	if err != nil {
		return "", err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	client := &http.Client{Timeout: 10 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return "", fmt.Errorf("download %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	f, err := os.Create(dest)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(f, h), resp.Body); err != nil {
		f.Close()
		return "", err
	}
	f.Close()
	got := hex.EncodeToString(h.Sum(nil))
	if expectSHA != "" && !strings.EqualFold(got, expectSHA) {
		return "", fmt.Errorf("sha256 mismatch: got %s want %s", got, expectSHA)
	}
	return ApplyLocalPackage(dest)
}
