package transparent

import (
	"sort"
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
	PuntFwdCE     = "gfc-ce-fwd"
	DummyDNS      = "gfc-dns"
	DefaultVIP    = "172.31.253.53"
	HitchBindIP   = "172.31.253.1"
	VIPPoolPrimary = "172.31.253.0/24"
	VIPPoolBackup  = "172.31.252.0/24"

	FilePorts   = "transparent-ports.json"
	FileLearned = "transparent-learned.json"
	FileDNS     = "dns-hijack.json"
	FileSpare   = "transparent-spare.json"
	FileHitch   = "transparent-hitch.json"

	HitchModeCE    = "ce"
	HitchModeSpare = "spare"
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
	Hosts            map[string]HostEntry `json:"hosts,omitempty"`
	CECandidates     map[string]int `json:"-"`
	// CEMiss counts ISP-side ARP requests for CEIP that the hitch host never
	// answered. GWStrong marks a next hop confirmed from the PE side.
	CEMiss           int  `json:"-"`
	GWStrong         bool `json:"-"`
}

// HostEntry is one cable host learned on cpe (not the hitch primary fields).
type HostEntry struct {
	MAC string `json:"mac"`
	At  string `json:"at,omitempty"`
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

const HostTTL = 30 * time.Minute

// CEStaleAfter is how long a hitch host may stay silent before a fresher cable
// host may take the primary slot. CEArpMissLimit unanswered PE who-has for the
// primary CE retires it only when another host is fresh in that window (Plan A:
// a sole CE keeps hitch through shutdown/standby).
const (
	CEStaleAfter   = 5 * time.Minute
	CEArpMissLimit = 5
)

func (l Learned) HostSig() string {
	if len(l.Hosts) == 0 {
		return ""
	}
	parts := make([]string, 0, len(l.Hosts))
	for ip, h := range l.Hosts {
		parts = append(parts, ip+"="+h.MAC)
	}
	sort.Strings(parts)
	return strings.Join(parts, ",")
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

// SpareConfig is the device-Web Plan B management address (TRANSPARENT_MODE.md §4.3).
type SpareConfig struct {
	IP      string `json:"ip,omitempty"`
	Prefix  int    `json:"prefix,omitempty"`
	Gateway string `json:"gateway,omitempty"`
}

func (s SpareConfig) Normalized() SpareConfig {
	out := s
	out.IP = strings.TrimSpace(out.IP)
	out.Gateway = strings.TrimSpace(out.Gateway)
	if out.IP == "" {
		out.Prefix = 0
		return out
	}
	if out.Prefix <= 0 || out.Prefix > 32 {
		out.Prefix = 32
	}
	return out
}

func (s SpareConfig) Usable() bool {
	return usableHitchIP(s.Normalized().IP)
}

// HitchIdentity is the current internet SNAT/TX MAC (Plan A CE or Plan B spare).
type HitchIdentity struct {
	Mode   string `json:"mode"`
	IP     string `json:"hitch_ip,omitempty"`
	SrcMAC string `json:"hitch_src_mac,omitempty"`
	PEMAC  string `json:"pe_mac,omitempty"`
	GWIP   string `json:"gw_ip,omitempty"`
}

func (h HitchIdentity) Sig() string {
	return strings.Join([]string{h.Mode, h.IP, h.SrcMAC, h.PEMAC, h.GWIP}, "|")
}

type Snapshot struct {
	Ports   Ports     `json:"ports"`
	Learned Learned   `json:"learned"`
	DNS     DNSConfig `json:"dns"`
	At      time.Time `json:"-"`
}
