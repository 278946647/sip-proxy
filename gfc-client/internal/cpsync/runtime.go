package cpsync

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/controlplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/linecode"
	"github.com/278946647/sip-proxy/gfc-client/internal/payload"
	"github.com/278946647/sip-proxy/gfc-client/internal/store"
)

// Runtime carries device mode fields reported back to control plane.
type Runtime struct {
	RoutingScheme string
	ProxyMode     string
	LiveMode      string
}

// SyncRuntime pushes local runtime mode to control plane so agent pulls stay aligned.
func SyncRuntime(cfg *config.Config, st *store.Store, rt Runtime) error {
	token := clientToken(cfg, st)
	if token == "" {
		return fmt.Errorf("device not activated")
	}
	servers := resolveServers(cfg, st)
	if len(servers) == 0 {
		return fmt.Errorf("control plane URL not configured")
	}
	client, err := controlplane.New(servers, token)
	if err != nil {
		return err
	}
	routing := ""
	if strings.TrimSpace(rt.RoutingScheme) != "" {
		routing = payload.NormalizeRoutingMode(rt.RoutingScheme)
	}
	proxy := strings.ToLower(strings.TrimSpace(rt.ProxyMode))
	live := strings.ToLower(strings.TrimSpace(rt.LiveMode))
	return client.UpdateRuntime(routing, proxy, live)
}

func clientToken(cfg *config.Config, st *store.Store) string {
	if device, _ := st.GetDevice(); device != nil {
		if token := strings.TrimSpace(device.ClientToken); token != "" {
			return token
		}
	}
	data, err := os.ReadFile(cfg.Paths.StateFile)
	if err != nil {
		return ""
	}
	var state struct {
		ClientToken string `json:"client_token"`
	}
	if json.Unmarshal(data, &state) != nil {
		return ""
	}
	return strings.TrimSpace(state.ClientToken)
}

func resolveServers(cfg *config.Config, st *store.Store) []string {
	if data, err := os.ReadFile(cfg.Paths.ActivationFile); err == nil {
		if pl, err := linecode.Decode(strings.TrimSpace(string(data))); err == nil {
			if urls := linecode.ServerURLs(pl); len(urls) > 0 {
				return urls
			}
		}
	}
	if device, _ := st.GetDevice(); device != nil {
		if u := strings.TrimSpace(device.ControlPlaneURL); u != "" {
			return []string{strings.TrimRight(u, "/")}
		}
	}
	var urls []string
	for _, key := range []string{"SERVER_URL", "SERVER_URL_FALLBACK"} {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			urls = append(urls, strings.TrimRight(v, "/"))
		}
	}
	return urls
}
