package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveLibOpenWrtRemapsVolatile(t *testing.T) {
	t.Setenv("GFC_PLATFORM", "immortalwrt")
	t.Setenv("GFC_LIB", DefaultLib)
	if got := ResolveLib(); got != DefaultLibOpenWrt {
		t.Fatalf("volatile default: got %s want %s", got, DefaultLibOpenWrt)
	}
	t.Setenv("GFC_LIB", "")
	if got := ResolveLib(); got != DefaultLibOpenWrt {
		t.Fatalf("unset: got %s want %s", got, DefaultLibOpenWrt)
	}
	t.Setenv("GFC_LIB", "/tmp/lib/gfc-client")
	if got := ResolveLib(); got != DefaultLibOpenWrt {
		t.Fatalf("tmpfs realpath: got %s want %s", got, DefaultLibOpenWrt)
	}
}

func TestResolveLibCustomKeptOnOpenWrt(t *testing.T) {
	t.Setenv("GFC_PLATFORM", "immortalwrt")
	t.Setenv("GFC_LIB", "/tmp/gfc-test-lib")
	if got := ResolveLib(); got != "/tmp/gfc-test-lib" {
		t.Fatalf("custom GFC_LIB remapped: got %s", got)
	}
}

func TestResolveLibLinuxDefault(t *testing.T) {
	t.Setenv("GFC_PLATFORM", "linux")
	t.Setenv("GFC_LIB", "")
	if got := ResolveLib(); got != DefaultLib {
		t.Fatalf("linux default: got %s want %s", got, DefaultLib)
	}
}

func TestMigrateVolatileLibCopiesState(t *testing.T) {
	root := t.TempDir()
	src := filepath.Join(root, "var-lib")
	dest := filepath.Join(root, "etc-lib")
	if err := os.MkdirAll(filepath.Join(src, "state"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "state", "config_bundle.json"), []byte(`{"ok":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "state", "client_state.json"), []byte(`{"token":"t"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	migrateLibTree(src, dest)
	bundle, err := os.ReadFile(filepath.Join(dest, "state", "config_bundle.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(bundle) != `{"ok":true}` {
		t.Fatalf("bundle: %s", bundle)
	}
	if _, err := os.Stat(filepath.Join(dest, "state", "client_state.json")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "state", "config_bundle.json"), []byte(`{"kept":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "state", "config_bundle.json"), []byte(`{"newer":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	migrateLibTree(src, dest)
	kept, err := os.ReadFile(filepath.Join(dest, "state", "config_bundle.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(kept) != `{"kept":true}` {
		t.Fatalf("should not overwrite existing dest: %s", kept)
	}
}
