package reversessh

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/platform"
)

const websshKeyComment = "gfc-webssh@control-plane"

// EnsureWebSSHAuthorizedKey installs control-plane WebSSH pubkey into device SSH authorized_keys.
// If an older gfc-webssh key is present with different material, it is replaced.
func EnsureWebSSHAuthorizedKey(pubkey string) error {
	pubkey = strings.TrimSpace(pubkey)
	if pubkey == "" {
		return nil
	}
	if !strings.Contains(pubkey, websshKeyComment) && !strings.HasPrefix(pubkey, "ssh-") {
		return fmt.Errorf("invalid webssh public key")
	}
	path := websshAuthorizedKeysPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	existing := string(data)
	if keyMaterialPresent(existing, pubkey) {
		return nil
	}
	cleaned := removeStaleWebSSHKeys(existing)
	var b strings.Builder
	b.WriteString(strings.TrimRight(cleaned, "\n"))
	if b.Len() > 0 {
		b.WriteByte('\n')
	}
	b.WriteString(pubkey)
	if !strings.HasSuffix(pubkey, "\n") {
		b.WriteByte('\n')
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		return err
	}
	return nil
}

func websshAuthorizedKeysPath() string {
	if platform.IsOpenWrt() {
		return "/etc/dropbear/authorized_keys"
	}
	return "/root/.ssh/authorized_keys"
}

func keyMaterialPresent(fileBody, pubkey string) bool {
	want := strings.Fields(pubkey)
	if len(want) < 2 {
		return false
	}
	for _, line := range strings.Split(fileBody, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == want[0] && fields[1] == want[1] {
			return true
		}
	}
	return false
}

func removeStaleWebSSHKeys(fileBody string) string {
	var keep []string
	for _, line := range strings.Split(fileBody, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.Contains(trimmed, websshKeyComment) {
			continue
		}
		keep = append(keep, line)
	}
	return strings.Join(keep, "\n")
}
