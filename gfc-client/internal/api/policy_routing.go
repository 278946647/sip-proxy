package api

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/278946647/sip-proxy/gfc-client/internal/policyrouting"
	"github.com/278946647/sip-proxy/gfc-client/internal/proxymode"
	"github.com/278946647/sip-proxy/gfc-client/internal/render/singbox"
)

func (s *Server) policyRoutingEnv() policyrouting.Env {
	env := policyrouting.DefaultEnv()
	pm := s.proxyMode.Status()
	env.ProxyMode = pm.Mode
	if env.ProxyMode == "" {
		env.ProxyMode = proxymode.NormalizeMode(s.cfg.ProxyMode)
	}
	env.CustomerHosts = pm.CustomerHosts
	env.LANCIDR = pm.LANCIDR
	if env.LANCIDR == "" {
		env.LANCIDR = s.lanCIDR()
	}
	env.RoutingMode = singbox.NewRenderer(s.cfg).RoutingMode()
	return env
}

func (s *Server) policyRouting() *policyrouting.Service {
	return policyrouting.NewService(s.cfg, s.policyRoutingEnv)
}

// failLuCI returns HTTP 200 with ok=false so BusyBox wget (used by luci-app-gfc)
// can read the JSON error. wget -qO- on HTTP 4xx exits 8 with empty stdout
// ("wget exit 8") and hides the real message.
func (s *Server) failLuCI(c *gin.Context, msg string) {
	c.JSON(http.StatusOK, gin.H{"ok": false, "error": gin.H{"message": msg}})
}

func (s *Server) getPolicyRoutingGroups(c *gin.Context) {
	groups, err := s.policyRouting().GetGroups()
	if err != nil {
		s.failLuCI(c, err.Error())
		return
	}
	s.ok(c, gin.H{"groups": groups})
}

func (s *Server) putPolicyRoutingGroups(c *gin.Context) {
	var body struct {
		Groups []policyrouting.Group `json:"groups"`
	}
	if err := c.BindJSON(&body); err != nil {
		s.failLuCI(c, err.Error())
		return
	}
	groups, err := s.policyRouting().PutGroups(body.Groups)
	if err != nil {
		s.failLuCI(c, err.Error())
		return
	}
	s.ok(c, gin.H{"groups": groups})
}

func (s *Server) getPolicyRoutingPolicies(c *gin.Context) {
	policies, err := s.policyRouting().GetPolicies()
	if err != nil {
		s.failLuCI(c, err.Error())
		return
	}
	s.ok(c, gin.H{"policies": policies})
}

func (s *Server) putPolicyRoutingPolicies(c *gin.Context) {
	var body struct {
		Policies []policyrouting.Policy `json:"policies"`
	}
	if err := c.BindJSON(&body); err != nil {
		s.failLuCI(c, err.Error())
		return
	}
	policies, err := s.policyRouting().PutPolicies(body.Policies)
	if err != nil {
		s.failLuCI(c, err.Error())
		return
	}
	s.ok(c, gin.H{"policies": policies})
}

func (s *Server) postPolicyRoutingApply(c *gin.Context) {
	var body policyrouting.ApplyInput
	_ = c.ShouldBindJSON(&body)
	res, err := s.policyRouting().Apply(body)
	if err != nil {
		s.failLuCI(c, err.Error())
		return
	}
	s.ok(c, res)
}

func (s *Server) postPolicyRoutingProbe(c *gin.Context) {
	var body policyrouting.ProbeRequest
	if err := c.BindJSON(&body); err != nil {
		s.failLuCI(c, err.Error())
		return
	}
	res, err := s.policyRouting().Probe(body)
	if err != nil {
		s.failLuCI(c, err.Error())
		return
	}
	s.ok(c, res)
}

func (s *Server) getPolicyRoutingSystemRules(c *gin.Context) {
	res, err := s.policyRouting().SystemRules()
	if err != nil {
		s.fail(c, http.StatusInternalServerError, err.Error())
		return
	}
	s.ok(c, res)
}

func (s *Server) getPolicyRoutingEffective(c *gin.Context) {
	res, err := s.policyRouting().Effective()
	if err != nil {
		s.fail(c, http.StatusInternalServerError, err.Error())
		return
	}
	s.ok(c, res)
}

func (s *Server) getPolicyRoutingDomainMap(c *gin.Context) {
	s.ok(c, s.policyRouting().DomainMapView())
}
