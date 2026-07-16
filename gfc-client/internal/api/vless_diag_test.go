package api

import "testing"

func TestParsePublicIPBody(t *testing.T) {
	cases := []struct {
		body   string
		label  bool
		want   string
	}{
		{"103.78.41.17\n", false, "103.78.41.17"},
		{"IP: 103.78.41.17 来自: 中国, 香港", true, "103.78.41.17"},
		{"【IP: 103.78.41.17 来自: 中国电信】", true, "103.78.41.17"},
		{"当前 IP：1.2.3.4 归属", false, "1.2.3.4"},
		{"192.168.1.1", false, ""}, // private rejected
		{"", true, ""},
	}
	for _, tc := range cases {
		got := parsePublicIPBody(tc.body, tc.label)
		if got != tc.want {
			t.Fatalf("body=%q label=%v got=%q want=%q", tc.body, tc.label, got, tc.want)
		}
	}
}

func TestIPInList(t *testing.T) {
	if !ipInList("1.2.3.4", []string{"9.9.9.9", "1.2.3.4"}) {
		t.Fatal("expected hit")
	}
	if ipInList("1.2.3.4", []string{"9.9.9.9"}) {
		t.Fatal("expected miss")
	}
}
