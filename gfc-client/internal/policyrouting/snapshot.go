package policyrouting

import (
	"fmt"
	"os/exec"
	"regexp"
	"strings"
)

var reElement = regexp.MustCompile(`(?m)^\s*([0-9./]+)\s*$`)

// CollectSnapshot reads live nft/ip when possible; falls back to empty with source note.
func CollectSnapshot() Snapshot {
	snap := Snapshot{
		RFC1918: defaultRFC1918(),
		Source:  "empty",
	}
	if out, err := exec.Command("nft", "list", "set", "inet", "gfc", "bypass_ip").CombinedOutput(); err == nil {
		snap.BypassIP = parseNFTSetElements(string(out))
		snap.BypassCount = len(snap.BypassIP)
		snap.Source = "nft"
	}
	if out, err := exec.Command("nft", "list", "set", "inet", "gfc", "TO_CN").CombinedOutput(); err == nil {
		elems := parseNFTSetElements(string(out))
		snap.TOCNCount = estimateElementCount(string(out), elems)
		// Keep only a sample for probe membership of huge CN sets — membership check uses nft get when needed.
		snap.TOCN = sample(elems, 64)
		if snap.Source == "empty" {
			snap.Source = "nft"
		}
	}
	if out, err := exec.Command("nft", "list", "set", "inet", "gfc", "ext_const").CombinedOutput(); err == nil {
		snap.ExtConst = parseNFTSetElements(string(out))
		snap.ExtConstCount = len(snap.ExtConst)
		if snap.Source == "empty" {
			snap.Source = "nft"
		}
	}
	if out, err := exec.Command("nft", "list", "set", "inet", "gfc", "ext").CombinedOutput(); err == nil {
		elems := parseNFTSetElements(string(out))
		snap.Ext = sample(elems, 64)
		snap.ExtCount = estimateElementCount(string(out), elems)
		if snap.Source == "empty" {
			snap.Source = "nft"
		}
	}
	if out, err := exec.Command("ip", "-4", "rule", "list").CombinedOutput(); err == nil {
		snap.IPRules = filterMarkRules(string(out))
	}
	if out, err := exec.Command("ip", "-4", "route", "show", "table", "2022").CombinedOutput(); err == nil {
		snap.Table2022 = strings.TrimSpace(string(out))
	}
	return snap
}

func parseNFTSetElements(raw string) []string {
	// Prefer brace content: elements = { a, b }
	if i := strings.Index(raw, "elements"); i >= 0 {
		rest := raw[i:]
		lb := strings.Index(rest, "{")
		rb := strings.LastIndex(rest, "}")
		if lb >= 0 && rb > lb {
			inner := rest[lb+1 : rb]
			parts := strings.FieldsFunc(inner, func(r rune) bool {
				return r == ',' || r == '\n' || r == '\r'
			})
			var out []string
			for _, p := range parts {
				p = strings.TrimSpace(p)
				if p == "" || strings.HasPrefix(p, "#") {
					continue
				}
				// drop trailing comments
				if idx := strings.Index(p, "#"); idx >= 0 {
					p = strings.TrimSpace(p[:idx])
				}
				if p == "" {
					continue
				}
				if v, err := normalizeIPOrCIDR(p); err == nil {
					out = append(out, v)
				}
			}
			return out
		}
	}
	var out []string
	for _, m := range reElement.FindAllStringSubmatch(raw, -1) {
		if len(m) > 1 {
			if v, err := normalizeIPOrCIDR(m[1]); err == nil {
				out = append(out, v)
			}
		}
	}
	return out
}

func estimateElementCount(raw string, parsed []string) int {
	if n := strings.Count(raw, ","); n > 0 {
		return n + 1
	}
	return len(parsed)
}

func sample(in []string, n int) []string {
	if len(in) <= n {
		return append([]string{}, in...)
	}
	return append([]string{}, in[:n]...)
}

func filterMarkRules(raw string) string {
	var lines []string
	for _, line := range strings.Split(raw, "\n") {
		l := strings.ToLower(line)
		if strings.Contains(l, "2023") || strings.Contains(l, "2022") || strings.Contains(l, "fwmark") {
			lines = append(lines, strings.TrimSpace(line))
		}
	}
	if len(lines) == 0 {
		return strings.TrimSpace(raw)
	}
	return strings.Join(lines, "\n")
}

// DstInTOCN checks membership via nft get element when set is too large for full parse.
func DstInTOCN(ip string) bool {
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return false
	}
	out, err := exec.Command("nft", "get", "element", "inet", "gfc", "TO_CN", fmt.Sprintf("{ %s }", ip)).CombinedOutput()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), ip) || strings.Contains(string(out), "element")
}

func enrichSnapshotForProbe(snap *Snapshot, dst string) {
	if dst == "" || parseIPv4(dst) == nil {
		return
	}
	if DstInTOCN(dst) {
		found := false
		for _, e := range snap.TOCN {
			if e == dst {
				found = true
				break
			}
		}
		if !found {
			snap.TOCN = append(snap.TOCN, dst)
		}
	}
}
