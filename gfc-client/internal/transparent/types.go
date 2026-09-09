package transparent

import (
	"strings"
	"time"
)

const (
	StateIdle    = "idle"
	StateCPEOnly = "cpe_only"
	StateISPOnly = "isp_only"
	StateDual    = "dual"

	BridgeName    = "br-trans"
	DummyCE       = "gfc-ce"
	DummyDNS      = "gfc-dns"
	DefaultVIP    = "172.31.253.53"
	HitchBindIP   = "172.31.253.1"
	VIPPoolPrimary = "172.31.253.0/24"
	VIPPoolBackup  = "172.31.252.0/24"

	FilePorts   = "transparent-ports.json"
	FileLearned = "transparent-learned.json"
	FileDNS     = "dns-hijack.json"
)

// Ports is the device-Web isp/cpe role assignment.
type Ports struct {
	ISP string `json:"isp_port"`
	CPE string `json:"cpe_port"`
}

func (p Ports) Normalized() Ports {
	return Ports{
		ISP: strings.TrimSpace(p.ISP),
		CPE: strings.TrimSpace(p.CPE),
	}
}

// Learned is passive observation on the transparent cable.
type Learned struct {
	State            string    `json:"state"`
	CPEMAC           string    `json:"cpe_mac,omitempty"`
	CEIP             string    `json:"ce_ip,omitempty"`
	PEMAC            string    `json:"pe_mac,omitempty"`
	GWIP             string    `json:"gw_ip,omitempty"`
	LearnedCustomer  bool      `json:"learned_customer"`
	UpdatedAt        string    `json:"updated_at,omitempty"`
	CECandidates     map[string]int `json:"-"`
}

func (l Learned) Dual() bool {
	return NormalizeState(l.State) == StateDual && strings.TrimSpace(l.CEIP) != ""
}

func NormalizeState(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case StateCPEOnly:
		return StateCPEOnly
	case StateISPOnly:
		return StateISPOnly
	case StateDual:
		return StateDual
	default:
		return StateIdle
	}
}

// DNSConfig is the device-wide hijack switch + transparent VIP.
type DNSConfig struct {
	Enabled bool     `json:"enabled"`
	Exclude []string `json:"exclude,omitempty"`
	VIP     string   `json:"vip,omitempty"`
}

func DefaultDNS() DNSConfig {
	return DNSConfig{Enabled: true, VIP: DefaultVIP}
}

func (d DNSConfig) Normalized() DNSConfig {
	out := d
	if strings.TrimSpace(out.VIP) == "" {
		out.VIP = DefaultVIP
	}
	return out
}

type Snapshot struct {
	Ports   Ports     `json:"ports"`
	Learned Learned   `json:"learned"`
	DNS     DNSConfig `json:"dns"`
	At      time.Time `json:"-"`
}
