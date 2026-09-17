package transparent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func portsPath(cfg *config.Config) string {
	return filepath.Join(cfg.Paths.Etc, FilePorts)
}

func learnedPath(cfg *config.Config) string {
	return filepath.Join(cfg.Paths.Etc, FileLearned)
}

func dnsPath(cfg *config.Config) string {
	return filepath.Join(cfg.Paths.Etc, FileDNS)
}

func sparePath(cfg *config.Config) string {
	return filepath.Join(cfg.Paths.Etc, FileSpare)
}

func hitchPath(cfg *config.Config) string {
	return filepath.Join(cfg.Paths.Etc, FileHitch)
}

func LoadPorts(cfg *config.Config) Ports {
	var p Ports
	raw, err := os.ReadFile(portsPath(cfg))
	if err != nil {
		return p
	}
	_ = json.Unmarshal(raw, &p)
	return p.Normalized()
}

func SavePorts(cfg *config.Config, p Ports) error {
	p = p.Normalized()
	return writeJSON(portsPath(cfg), p)
}

func LoadLearned(cfg *config.Config) Learned {
	var l Learned
	raw, err := os.ReadFile(learnedPath(cfg))
	if err != nil {
		l.State = StateIdle
		return l
	}
	if json.Unmarshal(raw, &l) != nil {
		l.State = StateIdle
		return l
	}
	l.State = NormalizeState(l.State)
	if !usableHitchIP(l.CEIP) {
		l.CEIP = ""
	}
	if !onLinkGW(l.CEIP, l.GWIP) {
		l.GWIP = ""
	}
	if l.Hosts != nil {
		for ip, h := range l.Hosts {
			if !usableHitchIP(ip) || strings.TrimSpace(h.MAC) == "" || ip == l.GWIP {
				delete(l.Hosts, ip)
			}
		}
		if len(l.Hosts) == 0 {
			l.Hosts = nil
		}
	}
	return l
}

func SaveLearned(cfg *config.Config, l Learned) error {
	l.State = NormalizeState(l.State)
	l.CECandidates = nil
	return writeJSON(learnedPath(cfg), l)
}

func LoadDNS(cfg *config.Config) DNSConfig {
	d := DefaultDNS()
	raw, err := os.ReadFile(dnsPath(cfg))
	if err != nil {
		return d
	}
	var got DNSConfig
	if json.Unmarshal(raw, &got) != nil {
		return d
	}
	if strings.TrimSpace(got.VIP) == "" {
		got.VIP = DefaultVIP
	}
	return got
}

func SaveDNS(cfg *config.Config, d DNSConfig) error {
	d = d.Normalized()
	return writeJSON(dnsPath(cfg), d)
}

func LoadSpare(cfg *config.Config) SpareConfig {
	var s SpareConfig
	if cfg == nil {
		return s
	}
	raw, err := os.ReadFile(sparePath(cfg))
	if err != nil {
		return s
	}
	if json.Unmarshal(raw, &s) != nil {
		return SpareConfig{}
	}
	return s.Normalized()
}

func SaveSpare(cfg *config.Config, s SpareConfig) error {
	return writeJSON(sparePath(cfg), s.Normalized())
}

func LoadHitch(cfg *config.Config) HitchIdentity {
	var h HitchIdentity
	if cfg == nil {
		return h
	}
	raw, err := os.ReadFile(hitchPath(cfg))
	if err != nil {
		return h
	}
	_ = json.Unmarshal(raw, &h)
	return h
}

func SaveHitch(cfg *config.Config, h HitchIdentity) error {
	if cfg == nil {
		return nil
	}
	return writeJSON(hitchPath(cfg), h)
}

func writeJSON(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o600)
}
