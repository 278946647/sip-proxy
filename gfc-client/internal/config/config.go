package config

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	Version = "2.1.0"

	DefaultRoot      = "/opt/gfc-client"
	DefaultEtc       = "/etc/gfc-client"
	DefaultLib       = "/var/lib/gfc-client"
	// DefaultLibOpenWrt is overlay-persistent. On ImmortalWrt /var → /tmp (tmpfs).
	DefaultLibOpenWrt = "/etc/gfc-client/lib"
	DefaultLog        = "/var/log/gfc-client"
	DefaultAPIPort   = 8787
	DefaultWebPort   = 8080
	DefaultFlashPort = 80
	DefaultDNSPort   = 53
	DefaultUnboundUID = 65353
	TunInterface     = "gfctun"

	BackupGenerations = 5

	ServiceNetwork = "gfc-network.service"
	ServiceAgent   = "gfc-agent.service"
	ServiceWeb     = "gfc-web.service"
	ServiceUnbound = "gfc-unbound.service"
	ServiceSingbox = "gfc-sing-box.service"
	ServiceRouting = "gfc-routing.service"
	ServiceDnsmasq = "dnsmasq.service"

	// Deprecated aliases kept for deploy script compatibility during migration.
	ServiceMosDNS = ServiceUnbound
	DefaultMosDNS = DefaultDNSPort
)

type Paths struct {
	Root            string
	Etc             string
	Lib             string
	Log             string
	EnvFile         string
	ActivationFile  string
	PlatformFile    string
	ConfigBundle    string
	StateFile       string
	StatusFile      string
	DBFile          string
	RulesDir        string
	DNSListsDir     string
	SingboxConfig          string
	UnboundConfig          string
	UnboundDomainsInsecure string
	UnboundConfD           string
	// Deprecated — use Unbound* paths.
	MosdnsConfig  string
	EasyMosdnsDir string
	DataplaneMode   string
	RoutingModeFile string
	PolicySelFile   string
	NFTBoot         string
	NFTDNS          string
	DnsmasqConf     string
	BackupsDir      string
	WebRoot         string
}

type Config struct {
	Paths       Paths
	DeviceName  string
	ProxyMode   string
	PollSeconds     int
	PollSecondsFast int
	APIPort     int
	WebPort     int
	FlashPort   int
	AdminToken  string
	LanIface    string
	WanIface    string
	LanAddress  string
	LanCIDR     string
}

func Load() *Config {
	envFile := env("GFC_ENV_FILE", filepath.Join(env("GFC_ETC", DefaultEtc), "gfc.env"))
	loadEnvFile(envFile)

	etc := env("GFC_ETC", DefaultEtc)
	root := env("GFC_ROOT", DefaultRoot)
	lib := ResolveLib()
	logDir := env("GFC_LOG_DIR", DefaultLog)
	envFile = env("GFC_ENV_FILE", filepath.Join(etc, "gfc.env"))

	paths := Paths{
		Root:            root,
		Etc:             etc,
		Lib:             lib,
		Log:             logDir,
		EnvFile:         envFile,
		ActivationFile:  filepath.Join(etc, "activation.b32"),
		PlatformFile:    filepath.Join(etc, "platform.b32"),
		ConfigBundle:    filepath.Join(lib, "state", "config_bundle.json"),
		StateFile:       filepath.Join(lib, "state", "client_state.json"),
		StatusFile:      filepath.Join(lib, "status.json"),
		DBFile:          filepath.Join(lib, "gfc-client.db"),
		RulesDir:        filepath.Join(lib, "rules"),
		DNSListsDir:     filepath.Join(lib, "dns-lists"),
		SingboxConfig:          filepath.Join(etc, "sing-box.json"),
		UnboundConfig:          "/etc/unbound/unbound.conf",
		UnboundDomainsInsecure: "/etc/unbound/domains-insecure.conf",
		UnboundConfD:           "/etc/unbound/conf.d",
		MosdnsConfig:           "/etc/unbound/unbound.conf",
		EasyMosdnsDir:          "/etc/unbound",
		DataplaneMode:   filepath.Join(etc, "dataplane-mode.json"),
		RoutingModeFile: filepath.Join(etc, "routing-mode.json"),
		PolicySelFile:   filepath.Join(etc, "policy", "selector.json"),
		NFTBoot:         filepath.Join(etc, "nftables.conf"),
		NFTDNS:          filepath.Join(etc, "nftables-dns.conf"),
		DnsmasqConf:     filepath.Join(etc, "dnsmasq.conf"),
		BackupsDir:      filepath.Join(lib, "backups"),
		WebRoot:         filepath.Join(root, "web"),
	}

	return &Config{
		Paths:       paths,
		DeviceName:  env("DEVICE_NAME", hostname()),
		ProxyMode:   env("GFC_PROXY_MODE", "gateway"),
		PollSeconds:     envInt("POLL_SECONDS", 3),
		PollSecondsFast: envInt("POLL_SECONDS_FAST", 2),
		APIPort:     envInt("GFC_API_PORT", DefaultAPIPort),
		WebPort:     envInt("GFC_CLIENT_WEB_PORT", DefaultWebPort),
		FlashPort:   envInt("GFC_CLIENT_FLASH_PORT", DefaultFlashPort),
		AdminToken:  env("GFC_ADMIN_TOKEN", ""),
		LanIface:    env("GFC_LAN_IFACE", ""),
		WanIface:    env("GFC_WAN_IFACE", ""),
		LanAddress:  env("GFC_LAN_ADDRESS", "192.168.68.1"),
		LanCIDR:     env("GFC_LAN_CIDR", "192.168.68.0/24"),
	}
}

// ResolveLib returns the state directory. On OpenWrt/ImmortalWrt, /var is tmpfs
// (/var → /tmp), so bundle + client_state must live under /etc/gfc-client/lib.
// Explicit GFC_LIB wins unless it is the known volatile default.
func ResolveLib() string {
	lib := strings.TrimSpace(os.Getenv("GFC_LIB"))
	if isOpenWrtHost() {
		if lib == "" || isLegacyVolatileLib(lib) {
			return DefaultLibOpenWrt
		}
		return lib
	}
	if lib == "" {
		return DefaultLib
	}
	return lib
}

func isOpenWrtHost() bool {
	p := strings.ToLower(strings.TrimSpace(os.Getenv("GFC_PLATFORM")))
	if p == "openwrt" || p == "immortalwrt" {
		return true
	}
	if _, err := os.Stat("/etc/openwrt_release"); err == nil {
		return true
	}
	return false
}

func isLegacyVolatileLib(lib string) bool {
	switch strings.TrimRight(filepath.ToSlash(lib), "/") {
	case DefaultLib, "/tmp/lib/gfc-client":
		return true
	}
	return false
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return strings.TrimSpace(v)
	}
	return def
}

func envInt(key string, def int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

func loadEnvFile(path string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		if os.Getenv(key) == "" {
			_ = os.Setenv(key, val)
		}
	}
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "gfc-client"
	}
	return h
}

func (c *Config) EnsureDirs() error {
	dirs := []string{
		c.Paths.Etc,
		c.Paths.Lib,
		filepath.Join(c.Paths.Lib, "state"),
		c.Paths.RulesDir,
		c.Paths.DNSListsDir,
		filepath.Join(c.Paths.Etc, "unbound"),
		filepath.Join(c.Paths.Etc, "policy"),
		filepath.Join(c.Paths.Etc, "policy-routing"),
		c.Paths.Log,
		c.Paths.BackupsDir,
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	c.migrateVolatileLib()
	return nil
}

func (c *Config) migrateVolatileLib() {
	dest := strings.TrimRight(filepath.ToSlash(c.Paths.Lib), "/")
	if dest == "" || dest == DefaultLib {
		return
	}
	for _, src := range []string{DefaultLib, "/tmp/lib/gfc-client"} {
		if strings.TrimRight(filepath.ToSlash(src), "/") == dest {
			continue
		}
		migrateLibTree(src, c.Paths.Lib)
	}
}

func migrateLibTree(src, dest string) {
	files := []string{
		filepath.Join("state", "config_bundle.json"),
		filepath.Join("state", "client_state.json"),
		filepath.Join("state", "ota-result.json"),
		"gfc-client.db",
		"status.json",
	}
	for _, rel := range files {
		copyFileIfMissing(filepath.Join(src, rel), filepath.Join(dest, rel))
	}
	copyDirIfEmpty(filepath.Join(src, "rules"), filepath.Join(dest, "rules"))
	copyDirIfEmpty(filepath.Join(src, "dns-lists"), filepath.Join(dest, "dns-lists"))
	copyDirIfEmpty(filepath.Join(src, "backups"), filepath.Join(dest, "backups"))
}

func copyFileIfMissing(src, dest string) {
	if _, err := os.Stat(dest); err == nil {
		return
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(dest), 0o755)
	mode := os.FileMode(0o600)
	if info, err := os.Stat(src); err == nil {
		mode = info.Mode()
	}
	_ = os.WriteFile(dest, data, mode)
}

func copyDirIfEmpty(src, dest string) {
	entries, err := os.ReadDir(src)
	if err != nil || len(entries) == 0 {
		return
	}
	if destEntries, err := os.ReadDir(dest); err == nil && len(destEntries) > 0 {
		return
	}
	_ = os.MkdirAll(dest, 0o755)
	for _, e := range entries {
		from := filepath.Join(src, e.Name())
		to := filepath.Join(dest, e.Name())
		if e.IsDir() {
			copyDirIfEmpty(from, to)
			continue
		}
		copyFileIfMissing(from, to)
	}
}

// ResolvedWanIface returns WAN interface from env or network-roles.json.
func (c *Config) ResolvedWanIface() string {
	if w := strings.TrimSpace(c.WanIface); w != "" {
		return w
	}
	path := filepath.Join(c.Paths.Etc, "network-roles.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var roles map[string]any
	if json.Unmarshal(data, &roles) != nil {
		return ""
	}
	if w, ok := roles["wan"].(string); ok {
		return strings.TrimSpace(w)
	}
	return ""
}
