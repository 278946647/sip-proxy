package cpsync

import (
	"fmt"
	"os"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/controlplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/linecode"
	"github.com/278946647/sip-proxy/gfc-client/internal/payload"
	"github.com/278946647/sip-proxy/gfc-client/internal/store"
)

// Runtime carries device mode fields that should be owned by control plane.
type Runtime struct {
	RoutingScheme string
	ProxyMode     string
}

// SyncRuntime pushes local runtime mode to control plane so the next config pull
// does not revert box-side changes.
func SyncRuntime(cfg *config.Config, st *store.Store, rt Runtime) error {
	device, err := st.GetDevice()
	if err != nil || device == nil || strings.TrimSpace(device.ClientToken) == "" {
		return nil
	}
	servers := resolveServers(cfg, st)
	if len(servers) == 0 {
		return fmt.Errorf("control plane URL not configured")
	}
	client, err := controlplane.New(servers, device.ClientToken)
	if err != nil {
		return err
	}
	routing := ""
	if strings.TrimSpace(rt.RoutingScheme) != "" {
		routing = payload.NormalizeRoutingMode(rt.RoutingScheme)
	}
	proxy := strings.ToLower(strings.TrimSpace(rt.ProxyMode))
	return client.UpdateRuntime(routing, proxy)
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
