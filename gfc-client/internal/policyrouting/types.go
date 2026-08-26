package policyrouting

const (
	KindSrcCIDR = "src_cidr"
	KindDstCIDR = "dst_cidr"
	KindDomain  = "domain"

	ActionDirect = "direct"
	ActionProxy  = "proxy"

	StatusActive   = "active"
	StatusShadowed = "shadowed"
	StatusBlocked  = "blocked_by_safety"

	LayerSafety = "safety_rail"
	LayerUser   = "user_override"
	LayerSystem = "system_default"

	DirName       = "policy-routing"
	GroupsFile    = "groups.json"
	PoliciesFile  = "policies.json"
	SetPrefixSrc  = "usr_src_"
	SetPrefixDst  = "usr_dst_"
	SetPrefixDom  = "usr_dom_"

	DangerSrcOnly   = "该源访问任意目的将强制 %s，可能影响该主机全部上网路径。"
	DangerOverride  = "此规则将覆盖系统默认分流（例如国内走代理或国际走直连）。"
	DataplanePending = "nft usr_* overlay 尚未应用到数据面（存盘成功，或上次 apply 失败）。"
)

type Group struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Kind        string   `json:"kind"`
	Members     []string `json:"members"`
	Description string   `json:"description,omitempty"`
	RefCount    int      `json:"ref_count"`
}

type Policy struct {
	ID                 string   `json:"id"`
	Enabled            bool     `json:"enabled"`
	Name               string   `json:"name"`
	Rank               int      `json:"rank"`
	MatchSrcGroupID    string   `json:"match_src_group_id,omitempty"`
	MatchDstGroupID    string   `json:"match_dst_group_id,omitempty"`
	MatchDomainGroupID string   `json:"match_domain_group_id,omitempty"`
	Action             string   `json:"action"`
	OverridesSystem    bool     `json:"overrides_system"`
	DangerAck          bool     `json:"danger_ack"`
	Notes              string   `json:"notes,omitempty"`
	Status             string   `json:"status,omitempty"`
	Reason             string   `json:"reason,omitempty"`
	DangerTexts        []string `json:"danger_texts,omitempty"`
}

type groupsFile struct {
	Groups []Group `json:"groups"`
}

type policiesFile struct {
	Policies []Policy `json:"policies"`
}

type Env struct {
	ProxyMode      string
	RoutingMode    string
	LANCIDR        string
	CustomerHosts  []string
	Mark           string
	Table          string
	Tun            string
}

func DefaultEnv() Env {
	return Env{
		ProxyMode:   "gateway",
		RoutingMode: "split",
		Mark:        "0x2023",
		Table:       "2022",
		Tun:         "gfctun",
	}
}

type Snapshot struct {
	BypassIP     []string
	TOCN         []string
	ExtConst     []string
	Ext          []string
	RFC1918      []string
	IPRules      string
	Table2022    string
	Source       string
	BypassCount  int
	TOCNCount    int
	ExtConstCount int
	ExtCount     int
}

type ProbeRequest struct {
	ProbeSrc    string   `json:"probe_src"`
	ProbeDst    string   `json:"probe_dst"`
	ProbeDomain string   `json:"probe_domain"`
	ResolvedIPs []string `json:"resolved_ips,omitempty"`
}

type ProbeHop struct {
	Layer    string `json:"layer"`
	ID       string `json:"id,omitempty"`
	Name     string `json:"name,omitempty"`
	Action   string `json:"action,omitempty"`
	Matched  bool   `json:"matched"`
	Reason   string `json:"reason"`
}

type ProbeResult struct {
	IngressEligible bool       `json:"ingress_eligible"`
	IngressReason   string     `json:"ingress_reason"`
	ProxyMode       string     `json:"proxy_mode"`
	ResolvedIPs     []string   `json:"resolved_ips,omitempty"`
	DomainSets      []string   `json:"usr_dom_sets,omitempty"`
	ResolveSource   string     `json:"resolve_source,omitempty"`
	Chain           []ProbeHop `json:"chain"`
	WinnerID        string     `json:"winner_id"`
	WinnerLayer     string     `json:"winner_layer"`
	WinnerName      string     `json:"winner_name,omitempty"`
	Action          string     `json:"action"`
	Reason          string     `json:"reason"`
	DataplaneNote   string     `json:"dataplane_note,omitempty"`
}

type ApplyInput struct {
	Groups   []Group  `json:"groups"`
	Policies []Policy `json:"policies"`
}

type ApplyResult struct {
	Groups           []Group   `json:"groups"`
	Policies         []Policy  `json:"policies"`
	DataplaneApplied bool      `json:"dataplane_applied"`
	DataplaneNote    string    `json:"dataplane_note"`
	DomainMap        DomainMap `json:"domain_map"`
}

type SystemRule struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Action        string `json:"action"`
	Layer         string `json:"layer"`
	CoveredBy     string `json:"covered_by,omitempty"`
	CoveredByName string `json:"covered_by_name,omitempty"`
}

type SetView struct {
	Name     string   `json:"name"`
	Count    int      `json:"count"`
	Sample   []string `json:"sample"`
	Writable string   `json:"writable"`
}

type SystemRules struct {
	ProxyMode         string          `json:"proxy_mode"`
	RoutingMode       string          `json:"routing_mode"`
	MarkPath          string          `json:"mark_path"`
	SafetyRailHealth  map[string]any  `json:"safety_rail_health"`
	Sets              map[string]SetView `json:"sets"`
	CustomerHostsHint string          `json:"customer_hosts_hint"`
	DefaultRules      []SystemRule    `json:"default_rules"`
	UserOverrides     []Policy        `json:"user_overrides"`
	IPRules           string          `json:"ip_rules"`
	Table2022         string          `json:"table_2022"`
	DataplaneApplied  bool            `json:"dataplane_applied"`
	DataplaneNote     string          `json:"dataplane_note"`
	SnapshotSource    string          `json:"snapshot_source"`
	DomainMap         DomainMap       `json:"domain_map"`
}

type Effective struct {
	Groups           []Group   `json:"groups"`
	Policies         []Policy  `json:"policies"`
	ProxyMode        string    `json:"proxy_mode"`
	MarkPath         string    `json:"mark_path"`
	DataplaneApplied bool      `json:"dataplane_applied"`
	DataplaneNote    string    `json:"dataplane_note"`
	DomainMap        DomainMap `json:"domain_map"`
}
