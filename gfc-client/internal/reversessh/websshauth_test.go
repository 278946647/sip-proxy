package reversessh

import "testing"

func TestKeyMaterialPresent(t *testing.T) {
	pub := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGabcdef gfc-webssh@control-plane"
	body := "ssh-rsa AAAA old\n" + pub + "\n"
	if !keyMaterialPresent(body, pub) {
		t.Fatal("expected exact key material to be present")
	}
	other := "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGotherkey gfc-webssh@control-plane"
	if keyMaterialPresent(body, other) {
		t.Fatal("different key material must not match")
	}
}

func TestRemoveStaleWebSSHKeys(t *testing.T) {
	body := "ssh-rsa AAAA keepme\nssh-ed25519 BBBB gfc-webssh@control-plane\n"
	got := removeStaleWebSSHKeys(body)
	if got != "ssh-rsa AAAA keepme" {
		t.Fatalf("got %q", got)
	}
}
