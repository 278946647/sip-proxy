//go:build !linux

package policyrouting

import "github.com/278946647/sip-proxy/gfc-client/internal/config"

func startDNSSnoopImpl(_ *config.Config, _ func() Env) {}
