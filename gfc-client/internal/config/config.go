package config

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	Version = "1.1.0"

	DefaultRoot      = "/opt/gfc-client"
	DefaultEtc       = "/etc/gfc-client"
	DefaultLib       = "/var/lib/gfc-client"
	DefaultLog       = "/var/log/gfc-client"
	DefaultAPIPort   = 8787
	DefaultWebPort   = 8080
	DefaultFlashPort = 80
	DefaultMosDNS    = 53
	TunInterface     = "gfctun"

	BackupGenerations = 5

	ServiceNetwork = "gfc-network.service"
	ServiceAgent   = "gfc-agent.service"
	ServiceWeb     = "gfc-web.service"
	ServiceMosDNS  = "gfc-mosdns.service"
	ServiceSingbox = "gfc-sing-box.service"
	ServiceDnsmasq = "dnsmasq.service"
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
	SingboxConfig   string
	MosdnsConfig    string
	EasyMosdnsDir   string
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
	PollSeconds int
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
	etc := env("GFC_ETC", DefaultEtc)
	root := env("GFC_ROOT", DefaultRoot)
	lib := env("GFC_LIB", DefaultLib)
	logDir := env("GFC_LOG_DIR", DefaultLog)

	paths := Paths{
		Root:            root,
		Etc:             etc,
		Lib:             lib,
		Log:             logDir,
		EnvFile:         filepath.Join(etc, "gfc.env"),
		ActivationFile:  filepath.Join(etc, "activation.b32"),
		PlatformFile:    filepath.Join(etc, "platform.b32"),
		ConfigBundle:    filepath.Join(lib, "state", "config_bundle.json"),
		StateFile:       filepath.Join(lib, "state", "client_state.json"),
		StatusFile:      filepath.Join(lib, "status.json"),
		DBFile:          filepath.Join(lib, "gfc-client.db"),
		RulesDir:        filepath.Join(lib, "rules"),
		DNSListsDir:     filepath.Join(lib, "dns-lists"),
		SingboxConfig:   filepath.Join(etc, "sing-box.json"),
		MosdnsConfig:    filepath.Join(etc, "mosdns", "easymosdns", "config.yaml"),
		EasyMosdnsDir:   filepath.Join(etc, "mosdns", "easymosdns"),
		DataplaneMode:   filepath.Join(etc, "dataplane-mode.json"),
		RoutingModeFile: filepath.Join(etc, "routing-mode.json"),
		PolicySelFile:   filepath.Join(etc, "policy", "selector.json"),
		NFTBoot:         filepath.Join(etc, "nftables.conf"),
		NFTDNS:          filepath.Join(etc, "nftables-dns.conf"),
		DnsmasqConf:     filepath.Join(etc, "dnsmasq.conf"),
		BackupsDir:      filepath.Join(lib, "backups"),
		WebRoot:         filepath.Join(root, "web"),
	}

	loadEnvFile(paths.EnvFile)

	return &Config{
		Paths:       paths,
		DeviceName:  env("DEVICE_NAME", hostname()),
		ProxyMode:   env("GFC_PROXY_MODE", "gateway"),
		PollSeconds: envInt("POLL_SECONDS", 10),
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
		filepath.Join(c.Paths.Etc, "mosdns"),
		filepath.Join(c.Paths.Etc, "policy"),
		c.Paths.Log,
		c.Paths.BackupsDir,
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	return nil
}
