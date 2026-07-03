package dataplane

import (
	"github.com/278946647/sip-proxy/gfc-client/internal/config"
	"github.com/278946647/sip-proxy/gfc-client/internal/orchestrator"
)

// Engine is a thin wrapper around Orchestrator for backward compatibility.
type Engine struct {
	*orchestrator.Orchestrator
}

func New(cfg *config.Config) *Engine {
	return &Engine{Orchestrator: orchestrator.New(cfg)}
}

func (e *Engine) ApplyPayload(payload map[string]any, version string, restart bool) (bool, string) {
	return e.Orchestrator.ApplyPayload(payload, version, restart)
}

func (e *Engine) Rollback() (bool, string) {
	return e.Orchestrator.Rollback()
}

func (e *Engine) ReapplyLocal(restart bool) (bool, string) {
	return e.Orchestrator.ReapplyLocal(restart)
}

func (e *Engine) ReloadDNS() (bool, string) {
	return e.Orchestrator.ReloadDNS()
}

func (e *Engine) LoadBundle() map[string]any {
	return e.Orchestrator.LoadBundle()
}

func ServiceStatus() map[string]any {
	return orchestrator.ServiceStatus()
}
