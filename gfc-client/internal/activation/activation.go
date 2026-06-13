package activation

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/controlplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/dataplane"
	"github.com/278946647/sip-proxy/gfc-client/internal/linecode"
	"github.com/278946647/sip-proxy/gfc-client/internal/store"
)

type Service struct {
	cfg    *config.Config
	store  *store.Store
	engine *dataplane.Engine
}

func New(cfg *config.Config, st *store.Store, engine *dataplane.Engine) *Service {
	return &Service{cfg: cfg, store: st, engine: engine}
}

func (s *Service) Flash(code string, resetState bool) (map[string]any, error) {
	code = strings.TrimSpace(code)
	if code == "" {
		return nil, errVal("empty line code")
	}
	payload, err := linecode.Decode(code)
	if err != nil {
		return nil, err
	}
	kind := linecode.Kind(payload)
	if err := os.WriteFile(s.cfg.Paths.ActivationFile, []byte(code), 0o600); err != nil {
		return nil, err
	}
	_ = s.store.SaveActivation(code, payload)

	if kind == "platform" {
		urls := linecode.ServerURLs(payload)
		if len(urls) > 0 {
			s.updateEnvURLs(urls)
		}
		_ = os.WriteFile(s.cfg.Paths.PlatformFile, []byte(code), 0o600)
		return map[string]any{
			"kind": "platform", "servers": urls,
			"message": "平台地址已更新",
		}, nil
	}

	if resetState {
		_ = os.Remove(s.cfg.Paths.StateFile)
		_ = s.store.ClearDevice()
	}
	urls := linecode.ServerURLs(payload)
	if len(urls) > 0 {
		s.updateEnvURLs(urls)
	}
	return map[string]any{
		"kind":    "line",
		"lineId":  payload["lineId"],
		"nodeName": payload["nodeName"],
		"state":   "pending_activate",
		"message": "线路码已保存，联网后将自动激活",
	}, nil
}

func (s *Service) Clear() error {
	for _, p := range []string{s.cfg.Paths.ActivationFile, s.cfg.Paths.PlatformFile, s.cfg.Paths.StateFile} {
		_ = os.Remove(p)
	}
	_ = s.store.ClearDevice()
	_, _ = s.engine.BootstrapIdle()
	return nil
}

func (s *Service) ReadActivation() (string, map[string]any, error) {
	data, err := os.ReadFile(s.cfg.Paths.ActivationFile)
	if err != nil {
		return "", nil, err
	}
	code := strings.TrimSpace(string(data))
	payload, err := linecode.Decode(code)
	return code, payload, err
}

func (s *Service) IsActivated() bool {
	st, err := loadClientState(s.cfg.Paths.StateFile)
	return err == nil && st.ClientToken != ""
}

func (s *Service) SaveClientState(st *controlplane.ClientState) error {
	raw, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.cfg.Paths.StateFile), 0o755); err != nil {
		return err
	}
	return os.WriteFile(s.cfg.Paths.StateFile, raw, 0o600)
}

func loadClientState(path string) (*controlplane.ClientState, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var st controlplane.ClientState
	if err := json.Unmarshal(data, &st); err != nil {
		return nil, err
	}
	return &st, nil
}

func (s *Service) LoadClientState() (*controlplane.ClientState, error) {
	return loadClientState(s.cfg.Paths.StateFile)
}

func (s *Service) updateEnvURLs(urls []string) {
	if len(urls) == 0 {
		return
	}
	lines := []string{}
	if data, err := os.ReadFile(s.cfg.Paths.EnvFile); err == nil {
		lines = strings.Split(string(data), "\n")
	}
	set := func(key, val string) {
		prefix := key + "="
		found := false
		for i, line := range lines {
			if strings.HasPrefix(line, prefix) {
				lines[i] = prefix + val
				found = true
				break
			}
		}
		if !found {
			lines = append(lines, prefix+val)
		}
	}
	set("SERVER_URL", urls[0])
	if len(urls) > 1 {
		set("SERVER_URL_FALLBACK", urls[1])
	}
	_ = os.WriteFile(s.cfg.Paths.EnvFile, []byte(strings.Join(lines, "\n")+"\n"), 0o600)
}

type valError struct{ msg string }

func (e valError) Error() string { return e.msg }
func errVal(msg string) error   { return valError{msg: msg} }
