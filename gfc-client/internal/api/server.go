package api

import (
	"encoding/json"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/278946647/sip-proxy/gfc-client/internal/activation"
	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/dataplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/dnslists"
	"github.com/278946647/sip-proxy/gfc-client/internal/envfile"
	"github.com/278946647/sip-proxy/gfc-client/internal/logtail"
	"github.com/278946647/sip-proxy/gfc-client/internal/network"
	"github.com/278946647/sip-proxy/gfc-client/internal/render/mosdns"
	"github.com/278946647/sip-proxy/gfc-client/internal/render/singbox"
	"github.com/278946647/sip-proxy/gfc-client/internal/reversessh"
	"github.com/278946647/sip-proxy/gfc-client/internal/rules"
	"github.com/278946647/sip-proxy/gfc-client/internal/stats"
	"github.com/278946647/sip-proxy/gfc-client/internal/store"
	"github.com/278946647/sip-proxy/gfc-client/internal/upgrade"
)

type Server struct {
	cfg        *config.Config
	store      *store.Store
	engine     *dataplane.Engine
	activation *activation.Service
	dns        *dnslists.Manager
	rules      *rules.Manager
	network    *network.Manager
	revSSH     *reversessh.Manager
	mode       string // admin | flash
}

func NewServer(cfg *config.Config, st *store.Store, mode string) *Server {
	engine := dataplane.New(cfg)
	_ = st.DefaultPolicyGroups()
	return &Server{
		cfg:        cfg,
		store:      st,
		engine:     engine,
		activation: activation.New(cfg, st, engine),
		dns:        dnslists.New(cfg),
		rules:      rules.New(cfg),
		network:    network.New(cfg),
		revSSH:     reversessh.New(cfg),
		mode:       mode,
	}
}

func (s *Server) Router() *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(s.authMiddleware())

	v1 := r.Group("/api/v1")
	{
		v1.GET("/status", s.getStatus)
		v1.GET("/health", s.getHealth)
		v1.GET("/metrics", s.getMetrics)
		v1.GET("/alerts", s.getAlerts)

		v1.POST("/activation/flash", s.flashActivation)
		v1.GET("/activation", s.getActivation)
		v1.DELETE("/activation", s.clearActivation)

		v1.GET("/nodes", s.listNodes)
		v1.GET("/policy/groups", s.listPolicy)
		v1.PUT("/policy/groups/:id/select", s.selectPolicy)

		v1.GET("/dns/stats", s.getDNSStats)
		v1.GET("/singbox/stats", s.getSingboxStats)
		v1.GET("/agent", s.getAgent)

		v1.GET("/upgrade/status", s.getUpgradeStatus)
		v1.POST("/upgrade/check", s.checkUpgrade)

		v1.GET("/dns/lists", s.dnsLists)
		v1.GET("/dns/lists/:name", s.dnsExport)
		v1.POST("/dns/lists/:name", s.dnsUpdate)
		v1.POST("/dns/lists/:name/import", s.dnsImport)
		v1.POST("/dns/easymosdns/update", s.easyUpdate)

		v1.GET("/rules", s.listRules)
		v1.POST("/rules/update", s.updateRules)
		v1.GET("/routing", s.getRouting)
		v1.PUT("/routing", s.setRouting)

		v1.GET("/services", s.getServices)
		v1.POST("/services/:name/restart", s.restartService)
		v1.POST("/dataplane/reload", s.reloadDataplane)
		v1.POST("/dataplane/apply", s.applyDataplane)
		v1.POST("/dataplane/rollback", s.rollbackDataplane)

		v1.GET("/network", s.getNetwork)
		v1.GET("/network/interfaces", s.getInterfaces)
		v1.GET("/network/bridge", s.getBridge)
		v1.PUT("/network/bridge", s.putBridge)
		v1.GET("/network/wan", s.getWAN)
		v1.PUT("/network/wan", s.putWAN)
		v1.GET("/network/dhcp", s.getDHCP)
		v1.PUT("/network/dhcp", s.putDHCP)
		v1.GET("/network/routes", s.getRoutes)
		v1.PUT("/network/routes", s.putRoutes)
		v1.GET("/network/vlan", s.getVLAN)
		v1.PUT("/network/vlan", s.putVLAN)
		v1.GET("/policy/firewall", s.getFirewall)
		v1.POST("/diagnostics/:type", s.runDiagnostic)

		v1.GET("/logs", s.getLogs)
		v1.GET("/settings", s.getSettings)
		v1.PUT("/settings", s.putSettings)
		v1.PUT("/settings/singbox/logging", s.putLogging)
	}

	// legacy /api paths for compatibility
	legacy := r.Group("/api")
	{
		legacy.GET("/status", s.getStatusLegacy)
		legacy.POST("/line-code", s.flashLegacy)
	}

	r.NoRoute(s.serveStatic)
	return r
}

func (s *Server) authMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if s.mode == "flash" {
			p := c.Request.URL.Path
			if p == "/api/v1/health" || strings.HasPrefix(p, "/api/v1/activation") || p == "/api/line-code" {
				c.Next()
				return
			}
			if strings.HasPrefix(p, "/api/") {
				c.JSON(http.StatusForbidden, gin.H{"ok": false, "error": gin.H{"message": "刷码端口仅支持刷码"}})
				c.Abort()
				return
			}
		}
		if s.cfg.AdminToken != "" {
		 tok := c.GetHeader("X-GFC-Token")
		 if tok != s.cfg.AdminToken && !strings.HasPrefix(c.Request.URL.Path, "/api/v1/activation") {
		 	if c.Request.URL.Path != "/api/line-code" {
		 		// allow LAN without token for now on admin port
		 	}
		 }
		}
		c.Next()
	}
}

func (s *Server) ok(c *gin.Context, data any) {
	c.JSON(http.StatusOK, gin.H{"ok": true, "data": data})
}

func (s *Server) fail(c *gin.Context, code int, msg string) {
	c.JSON(code, gin.H{"ok": false, "error": gin.H{"message": msg}})
}

func (s *Server) getStatus(c *gin.Context) {
	device, _ := s.store.GetDevice()
	state := "idle"
	if s.activation.IsActivated() {
		state = "active"
	}
	data := map[string]any{
		"state":     state,
		"device":    device,
		"dataplane": readJSONFile(s.cfg.Paths.DataplaneMode),
		"network":   s.network.Status(),
		"system":    stats.System(),
		"tun":       stats.TunStatus(config.TunInterface),
		"dns":       stats.DNSProbe("127.0.0.1", config.DefaultMosDNS),
		"agent":     stats.AgentStatus(s.cfg),
	}
	s.ok(c, data)
}

func (s *Server) getStatusLegacy(c *gin.Context) {
	device, _ := s.store.GetDevice()
	status := readJSONFile(s.cfg.Paths.StatusFile)
	s.ok(c, map[string]any{"device": device, "metrics": status, "network": s.network.Status()})
}

func (s *Server) getHealth(c *gin.Context) {
	s.ok(c, dataplane.ServiceStatus())
}

func (s *Server) getMetrics(c *gin.Context) {
	s.ok(c, readJSONFile(s.cfg.Paths.StatusFile))
}

func (s *Server) getAlerts(c *gin.Context) {
	var alerts []map[string]any
	health := dataplane.ServiceStatus()
	for name, raw := range health {
		info, _ := raw.(map[string]any)
		active := strings.TrimSpace(toString(info["active"]))
		if active != "" && active != "active" {
			alerts = append(alerts, map[string]any{
				"severity": "critical",
				"source":   "service",
				"title":    name + " 服务异常",
				"message":  "systemd active=" + active,
			})
		}
	}
	dns := stats.DNSProbe("127.0.0.1", config.DefaultMosDNS)
	if ok, _ := dns["ok"].(bool); !ok {
		alerts = append(alerts, map[string]any{
			"severity": "warning",
			"source":   "dns",
			"title":    "DNS 探测失败",
			"message":  toString(dns["error"]),
		})
	}
	s.ok(c, map[string]any{"alerts": alerts, "count": len(alerts)})
}

func toString(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func (s *Server) flashActivation(c *gin.Context) {
	var body struct {
		Code       string `json:"code"`
		ResetState bool   `json:"reset_state"`
	}
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	result, err := s.activation.Flash(body.Code, body.ResetState)
	if err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	s.store.Audit("flash", map[string]any{"kind": result["kind"]}, "ok")
	s.ok(c, result)
}

func (s *Server) flashLegacy(c *gin.Context) {
	s.flashActivation(c)
}

func (s *Server) getActivation(c *gin.Context) {
	code, payload, err := s.activation.ReadActivation()
	if err != nil {
		s.fail(c, 404, "not activated")
		return
	}
	s.ok(c, map[string]any{"code_present": code != "", "payload": payload})
}

func (s *Server) clearActivation(c *gin.Context) {
	if err := s.activation.Clear(); err != nil {
		s.fail(c, 500, err.Error())
		return
	}
	s.ok(c, map[string]any{"cleared": true})
}

func (s *Server) listNodes(c *gin.Context) {
	nodes, _ := s.store.ListNodes()
	if len(nodes) == 0 {
		payload := s.engine.LoadBundle()
		if payload != nil {
			if node, ok := payload["node"].(map[string]any); ok {
				nodes = []map[string]any{node}
			}
		}
	}
	s.ok(c, map[string]any{"nodes": nodes})
}

func (s *Server) listPolicy(c *gin.Context) {
	groups, _ := s.store.ListPolicyGroups()
	s.ok(c, map[string]any{"groups": groups})
}

func (s *Server) selectPolicy(c *gin.Context) {
	var body struct {
		Outbound string `json:"outbound"`
	}
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	id := c.Param("id")
	if err := s.store.SelectPolicy(id, body.Outbound); err != nil {
		s.fail(c, 500, err.Error())
		return
	}
	sel := map[string]string{"selected": body.Outbound}
	raw, _ := json.MarshalIndent(sel, "", "  ")
	_ = os.MkdirAll(filepath.Dir(s.cfg.Paths.PolicySelFile), 0o755)
	_ = os.WriteFile(s.cfg.Paths.PolicySelFile, raw, 0o644)
	ok, msg := s.engine.ReapplyLocal(true)
	s.ok(c, map[string]any{"selected": body.Outbound, "apply": ok, "message": msg})
}

func (s *Server) dnsLists(c *gin.Context) {
	_ = s.dns.EnsureDefaults()
	s.ok(c, s.dns.Stats())
}

func (s *Server) dnsExport(c *gin.Context) {
	text, err := s.dns.Export(c.Param("name"))
	if err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	s.ok(c, map[string]any{"content": text})
}

func (s *Server) dnsUpdate(c *gin.Context) {
	var body struct {
		Action  string   `json:"action"`
		Domains []string `json:"domains"`
	}
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	count, err := s.dns.Update(c.Param("name"), body.Domains, body.Action)
	if err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	ok, msg := s.engine.ReloadDNS()
	s.ok(c, map[string]any{"count": count, "reload": ok, "message": msg})
}

func (s *Server) dnsImport(c *gin.Context) {
	var body struct {
		Content string `json:"content"`
		Replace bool   `json:"replace"`
	}
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	count, err := s.dns.Import(c.Param("name"), body.Content, body.Replace)
	if err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	ok, msg := s.engine.ReloadDNS()
	s.ok(c, map[string]any{"count": count, "reload": ok, "message": msg})
}

func (s *Server) easyUpdate(c *gin.Context) {
	if err := mosdns.NewRenderer(s.cfg).Render(); err != nil {
		s.fail(c, 500, err.Error())
		return
	}
	ok, msg := s.engine.ReloadDNS()
	s.ok(c, map[string]any{"ok": ok, "message": msg})
}

func (s *Server) listRules(c *gin.Context) {
	s.ok(c, map[string]any{"rules": s.rules.List()})
}

func (s *Server) updateRules(c *gin.Context) {
	result := s.rules.Update()
	ok, msg := s.engine.ReapplyLocal(true)
	result["apply"] = ok
	result["apply_message"] = msg
	s.ok(c, result)
}

func (s *Server) getRouting(c *gin.Context) {
	sb := singbox.NewRenderer(s.cfg)
	s.ok(c, map[string]any{"mode": sb.RoutingMode(), "rules_available": s.rules.Available()})
}

func (s *Server) setRouting(c *gin.Context) {
	var body struct {
		Mode string `json:"mode"`
	}
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	raw, _ := json.MarshalIndent(map[string]string{"mode": body.Mode}, "", "  ")
	_ = os.WriteFile(s.cfg.Paths.RoutingModeFile, raw, 0o644)
	_ = s.store.UpdateSettings(map[string]any{"routing_mode": body.Mode})
	ok, msg := s.engine.ReapplyLocal(true)
	s.ok(c, map[string]any{"mode": body.Mode, "apply": ok, "message": msg})
}

func (s *Server) getServices(c *gin.Context) {
	s.ok(c, map[string]any{"services": dataplane.ServiceStatus()})
}

func (s *Server) restartService(c *gin.Context) {
	ok, msg := s.engine.RestartUnit(c.Param("name"))
	s.ok(c, map[string]any{"ok": ok, "message": msg})
}

func (s *Server) reloadDataplane(c *gin.Context) {
	ok, msg := s.engine.ReapplyLocal(true)
	s.ok(c, map[string]any{"ok": ok, "message": msg})
}

func (s *Server) rollbackDataplane(c *gin.Context) {
	ok, msg := s.engine.Rollback()
	s.ok(c, map[string]any{"ok": ok, "message": msg})
}

func (s *Server) applyDataplane(c *gin.Context) {
	payload := s.engine.LoadBundle()
	if payload == nil {
		s.fail(c, 400, "no config bundle")
		return
	}
	ok, msg := s.engine.ApplyPayload(payload, "manual", true)
	s.ok(c, map[string]any{"ok": ok, "message": msg})
}

func (s *Server) getNetwork(c *gin.Context) {
	s.ok(c, s.network.Status())
}

func (s *Server) getInterfaces(c *gin.Context) {
	s.ok(c, map[string]any{"interfaces": network.ListInterfaces()})
}

func (s *Server) getBridge(c *gin.Context) {
	s.ok(c, s.network.LoadBridge())
}

func (s *Server) putBridge(c *gin.Context) {
	var body map[string]any
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	result, err := s.network.ApplyBridge(body)
	if err != nil {
		s.fail(c, 500, err.Error())
		return
	}
	s.ok(c, result)
}

func (s *Server) getWAN(c *gin.Context) {
	s.ok(c, s.network.LoadWAN())
}

func (s *Server) putWAN(c *gin.Context) {
	var body map[string]any
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	result, err := s.network.ApplyWAN(body)
	if err != nil {
		s.fail(c, 500, err.Error())
		return
	}
	s.ok(c, result)
}

func (s *Server) getDHCP(c *gin.Context) {
	s.ok(c, s.network.LoadDHCP())
}

func (s *Server) putDHCP(c *gin.Context) {
	var body map[string]any
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	result, err := s.network.ApplyDHCP(body)
	if err != nil {
		s.fail(c, 500, err.Error())
		return
	}
	s.ok(c, result)
}

func (s *Server) getRoutes(c *gin.Context) {
	s.ok(c, s.network.LoadRoutes())
}

func (s *Server) putRoutes(c *gin.Context) {
	var body map[string]any
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	result, err := s.network.ApplyRoutes(body)
	if err != nil {
		s.fail(c, 500, err.Error())
		return
	}
	s.ok(c, result)
}

func (s *Server) getVLAN(c *gin.Context) {
	s.ok(c, s.network.LoadVLAN())
}

func (s *Server) putVLAN(c *gin.Context) {
	var body map[string]any
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	result, err := s.network.ApplyVLAN(body)
	if err != nil {
		s.fail(c, 500, err.Error())
		return
	}
	s.ok(c, result)
}

func (s *Server) getFirewall(c *gin.Context) {
	boot := map[string]any{"path": s.cfg.Paths.NFTBoot, "exists": fileExists(s.cfg.Paths.NFTBoot)}
	dns := map[string]any{"path": s.cfg.Paths.NFTDNS, "exists": fileExists(s.cfg.Paths.NFTDNS)}
	s.ok(c, map[string]any{"nftables": []map[string]any{boot, dns}})
}

func (s *Server) runDiagnostic(c *gin.Context) {
	kind := c.Param("type")
	var body map[string]any
	_ = c.BindJSON(&body)
	switch kind {
	case "dns":
		host := strings.TrimSpace(toString(body["host"]))
		if host == "" {
			host = "www.google.com"
		}
		ips, err := net.LookupHost(host)
		s.ok(c, map[string]any{"host": host, "ips": ips, "ok": err == nil, "error": errString(err)})
	case "ping":
		host := strings.TrimSpace(toString(body["host"]))
		if host == "" {
			host = "1.1.1.1"
		}
		out, err := exec.Command("ping", "-c", "3", "-W", "2", host).CombinedOutput()
		s.ok(c, map[string]any{"host": host, "output": string(out), "ok": err == nil, "error": errString(err)})
	case "tun":
		s.ok(c, stats.TunStatus(config.TunInterface))
	default:
		s.fail(c, 400, "unsupported diagnostic type")
	}
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func (s *Server) getLogs(c *gin.Context) {
	service := c.DefaultQuery("service", "agent")
	lines := 200
	if n, err := parseInt(c.Query("lines")); err == nil {
		lines = n
	}
	s.ok(c, logtail.Tail(s.cfg, service, lines))
}

func (s *Server) getSettings(c *gin.Context) {
	settings, _ := s.store.GetSettings()
	settings["device_name"] = s.cfg.DeviceName
	settings["proxy_mode"] = s.cfg.ProxyMode
	s.ok(c, settings)
}

func (s *Server) getDNSStats(c *gin.Context) {
	logPath := filepath.Join(s.cfg.Paths.Log, "mosdns.log")
	s.ok(c, stats.MosDNS(logPath, 800))
}

func (s *Server) getSingboxStats(c *gin.Context) {
	s.ok(c, stats.Singbox("http://127.0.0.1:9090"))
}

func (s *Server) getAgent(c *gin.Context) {
	device, _ := s.store.GetDevice()
	data := stats.AgentStatus(s.cfg)
	data["device"] = device
	data["reverse_ssh"] = s.revSSH.Status()
	if device != nil {
		data["reverse_ssh_port"] = reversessh.Port(device.DeviceKey, 0)
	}
	s.ok(c, data)
}

func (s *Server) getUpgradeStatus(c *gin.Context) {
	s.ok(c, upgrade.Check(""))
}

func (s *Server) checkUpgrade(c *gin.Context) {
	var body struct {
		ManifestURL string `json:"manifest_url"`
	}
	_ = c.BindJSON(&body)
	s.ok(c, upgrade.Check(body.ManifestURL))
}

func (s *Server) putSettings(c *gin.Context) {
	var body map[string]any
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	_ = s.store.UpdateSettings(body)

	result := map[string]any{"saved": true}
	if mode, ok := body["proxy_mode"].(string); ok && strings.TrimSpace(mode) != "" {
		mode = strings.ToLower(strings.TrimSpace(mode))
		if err := envfile.Set(s.cfg.Paths.EnvFile, "GFC_PROXY_MODE", mode); err != nil {
			s.fail(c, 500, err.Error())
			return
		}
		_ = os.Setenv("GFC_PROXY_MODE", mode)
		s.cfg.ProxyMode = mode
		netOut, err := s.network.ApplyNetwork()
		result["proxy_mode"] = mode
		result["network"] = netOut
		if err != nil {
			result["network_error"] = err.Error()
		}
		ok, msg := s.engine.ReapplyLocal(true)
		result["dataplane"] = map[string]any{"ok": ok, "message": msg}
	}
	s.ok(c, result)
}

func (s *Server) putLogging(c *gin.Context) {
	var body struct {
		Level string `json:"level"`
	}
	if err := c.BindJSON(&body); err != nil {
		s.fail(c, 400, err.Error())
		return
	}
	_ = os.Setenv("GFC_SINGBOX_LOG_LEVEL", body.Level)
	ok, msg := s.engine.ReapplyLocal(true)
	s.ok(c, map[string]any{"level": body.Level, "apply": ok, "message": msg})
}

func (s *Server) serveStatic(c *gin.Context) {
	webRoot := s.cfg.Paths.WebRoot
	reqPath := c.Request.URL.Path

	if s.mode == "flash" {
		if reqPath == "/" {
			c.Redirect(http.StatusFound, "/flash.html")
			return
		}
		if reqPath != "/flash.html" && !strings.HasPrefix(reqPath, "/assets/") {
			c.Redirect(http.StatusFound, "/flash.html")
			return
		}
		if reqPath == "/flash.html" {
			c.File(filepath.Join(webRoot, "index.html"))
			return
		}
		fp := filepath.Join(webRoot, filepath.Clean("/"+reqPath))
		if st, err := os.Stat(fp); err == nil && !st.IsDir() {
			c.File(fp)
			return
		}
		c.File(filepath.Join(webRoot, "index.html"))
		return
	}

	path := reqPath
	if path == "/" {
		path = "/index.html"
	}
	fp := filepath.Join(webRoot, filepath.Clean("/"+path))
	if st, err := os.Stat(fp); err != nil || st.IsDir() {
		c.File(filepath.Join(webRoot, "index.html"))
		return
	}
	c.File(fp)
}

func readJSONFile(path string) map[string]any {
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]any{}
	}
	var m map[string]any
	if json.Unmarshal(data, &m) != nil {
		return map[string]any{}
	}
	return m
}

func parseInt(s string) (int, error) {
	var n int
	err := json.Unmarshal([]byte(s), &n)
	return n, err
}
