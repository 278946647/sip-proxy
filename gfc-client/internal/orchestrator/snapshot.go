package orchestrator

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type Snapshot struct {
	ID        string
	Dir       string
	CreatedAt time.Time
}

// Save copies tracked config files into backups/<id>/ and prunes old generations.
func Save(backupsDir string, id string, files map[string]string) error {
	if id == "" {
		id = time.Now().UTC().Format("20060102-150405")
	}
	dest := filepath.Join(backupsDir, id)
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return err
	}
	for name, src := range files {
		if src == "" {
			continue
		}
		data, err := os.ReadFile(src)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return fmt.Errorf("snapshot read %s: %w", src, err)
		}
		if err := os.WriteFile(filepath.Join(dest, name), data, 0o600); err != nil {
			return err
		}
	}
	return Prune(backupsDir, BackupGenerations)
}

// Latest returns the most recent snapshot directory name (by mtime).
func Latest(backupsDir string) (string, error) {
	entries, err := os.ReadDir(backupsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	var latest string
	var latestTime time.Time
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if latest == "" || info.ModTime().After(latestTime) {
			latest = e.Name()
			latestTime = info.ModTime()
		}
	}
	return latest, nil
}

// Restore copies files from the latest snapshot back to live paths.
func Restore(backupsDir string, mapping map[string]string) (string, error) {
	id, err := Latest(backupsDir)
	if err != nil {
		return "", err
	}
	if id == "" {
		return "", fmt.Errorf("no snapshot to restore")
	}
	srcDir := filepath.Join(backupsDir, id)
	for name, dst := range mapping {
		src := filepath.Join(srcDir, name)
		data, err := os.ReadFile(src)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return "", err
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return "", err
		}
		if err := os.WriteFile(dst, data, fileMode(name)); err != nil {
			return "", err
		}
	}
	return id, nil
}

// Prune keeps only the newest n snapshot directories.
func Prune(backupsDir string, keep int) error {
	if keep <= 0 {
		return nil
	}
	entries, err := os.ReadDir(backupsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	if len(names) <= keep {
		return nil
	}
	sort.Strings(names)
	for _, name := range names[:len(names)-keep] {
		_ = os.RemoveAll(filepath.Join(backupsDir, name))
	}
	return nil
}

func fileMode(name string) os.FileMode {
	if strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".yaml") {
		return 0o644
	}
	return 0o600
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp := path + ".new"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}
