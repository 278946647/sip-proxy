package envfile

import (
	"bufio"
	"os"
	"strings"
)

// Set updates or appends key=value in a shell env file.
func Set(path, key, value string) error {
	lines, err := readLines(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	found := false
	prefix := key + "="
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), prefix) {
			lines[i] = key + "=" + value
			found = true
			break
		}
	}
	if !found {
		lines = append(lines, key+"="+value)
	}
	return writeLines(path, lines)
}

func readLines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	return lines, sc.Err()
}

func writeLines(path string, lines []string) error {
	if err := os.MkdirAll(dirOf(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	for _, line := range lines {
		if _, err := f.WriteString(line + "\n"); err != nil {
			return err
		}
	}
	return nil
}

func dirOf(path string) string {
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[:i]
	}
	return "."
}
