package upgrade

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResultSatisfies(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("GFC_LIB", dir)
	path := ResultFilePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	payload := `{"status":"ok","version":"1.1.0-r16","request_id":"req-1","message":"done","at":"2026-01-01T00:00:00Z"}`
	if err := os.WriteFile(path, []byte(payload), 0o644); err != nil {
		t.Fatal(err)
	}
	if !ResultSatisfies("1.1.0-r16", "") {
		t.Fatal("expected version match")
	}
	if !ResultSatisfies("other", "req-1") {
		t.Fatal("expected request id match")
	}
	if ResultSatisfies("nope", "nope") {
		t.Fatal("expected no match")
	}
	ClearOTAResult()
	if ResultSatisfies("1.1.0-r16", "req-1") {
		t.Fatal("expected clear")
	}
}
