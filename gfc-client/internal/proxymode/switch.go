package proxymode

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

const DataplaneNoteP2 = "旁路数据面按 NFT §9.3 Option B 应用。请从管理 LAN 确认；超时将回滚 WAN、GFC_PROXY_MODE 与 nft。"

type WANApplyFunc func(body map[string]any) (map[string]any, error)

// ModeApplyFunc persists GFC_PROXY_MODE and reloads nft/policy routing.
type ModeApplyFunc func(mode string) error

type Controller struct {
	cfg      *config.Config
	lanCIDR  func() string
	applyWAN WANApplyFunc
	applyMode ModeApplyFunc

	mu    sync.Mutex
	timer *time.Timer
	now   func() time.Time
	after func(d time.Duration, f func()) *time.Timer
}

func NewController(cfg *config.Config, applyWAN WANApplyFunc, lanCIDR func() string) *Controller {
	c := &Controller{
		cfg:      cfg,
		applyWAN: applyWAN,
		lanCIDR:  lanCIDR,
		now:      func() time.Time { return time.Now().UTC() },
		after:    time.AfterFunc,
	}
	if c.lanCIDR == nil {
		c.lanCIDR = func() string { return cfg.LanCIDR }
	}
	return c
}

func (c *Controller) SetDataplaneApply(fn ModeApplyFunc) {
	c.applyMode = fn
}

type Status struct {
	Mode            string         `json:"proxy_mode"`
	DataplaneMode   string         `json:"dataplane_proxy_mode"`
	CustomerHosts   []string       `json:"customer_hosts"`
	LANCIDR         string         `json:"lan_cidr"`
	Pending         *PendingView   `json:"pending,omitempty"`
	DataplaneNote   string         `json:"dataplane_note,omitempty"`
	OperateFromLAN  string         `json:"operate_from_lan"`
}

type PendingView struct {
	Token       string `json:"token"`
	FromMode    string `json:"from_mode"`
	ToMode      string `json:"to_mode"`
	ExpiresAt   string `json:"expires_at"`
	SecondsLeft int    `json:"seconds_left"`
}

func (c *Controller) Status() Status {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	pending, _ := LoadPending(c.cfg)
	if pending != nil && PendingExpired(pending, now) {
		_ = c.rollbackLocked("timeout")
		pending = nil
	}
	st := Status{
		Mode:           CommittedMode(c.cfg),
		DataplaneMode:  NormalizeMode(c.cfg.ProxyMode),
		CustomerHosts:  LoadHosts(c.cfg),
		LANCIDR:        firstNonEmpty(c.lanCIDR(), c.cfg.LanCIDR),
		DataplaneNote:  DataplaneNoteP2,
		OperateFromLAN: "请从管理 LAN 口操作本页。旁路切换会改 WAN 静态地址；超时未确认将自动回滚 WAN 与模式。",
	}
	if pending != nil {
		st.Pending = &PendingView{
			Token:       pending.Token,
			FromMode:    pending.FromMode,
			ToMode:      pending.ToMode,
			ExpiresAt:   pending.ExpiresAt,
			SecondsLeft: SecondsLeft(pending, now),
		}
		st.Mode = NormalizeMode(pending.ToMode)
	}
	return st
}

func (c *Controller) Apply(req SwitchRequest) (Status, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if req.LANCIDR == "" {
		req.LANCIDR = firstNonEmpty(c.lanCIDR(), c.cfg.LanCIDR)
	}
	req.Mode = NormalizeMode(req.Mode)
	req.ConfirmTimeoutSec = ClampConfirmTimeout(req.ConfirmTimeoutSec)
	if err := ValidateSwitch(req); err != nil {
		return Status{}, err
	}
	expired, _ := LoadPending(c.cfg)
	if expired != nil && PendingExpired(expired, c.now()) {
		if err := c.rollbackLocked("timeout"); err != nil {
			return Status{}, err
		}
	}
	if req.Mode == ModeGateway && CommittedMode(c.cfg) == ModeGateway {
		pending, _ := LoadPending(c.cfg)
		if pending == nil {
			return c.statusLocked(), nil
		}
	}

	existing, _ := LoadPending(c.cfg)
	if existing != nil && !PendingExpired(existing, c.now()) {
		return Status{}, fmt.Errorf("已有未确认的模式切换（剩余 %d 秒），请先确认或等待回滚", SecondsLeft(existing, c.now()))
	}

	hosts := []string{}
	if req.Mode == ModeBypass {
		var err error
		hosts, err = NormalizeHosts(req.CustomerHosts)
		if err != nil {
			return Status{}, err
		}
	} else {
		hosts = LoadHosts(c.cfg)
	}

	wanAfter := cloneMap(c.loadWANFile())
	if req.Mode == ModeBypass {
		wanAfter["enabled"] = true
		wanAfter["mode"] = "static"
		wanAfter["address"] = strings.TrimSpace(req.WAN.Address)
		wanAfter["netmask"] = strings.TrimSpace(req.WAN.Netmask)
		wanAfter["gateway"] = strings.TrimSpace(req.WAN.Gateway)
		if iface := strings.TrimSpace(req.WAN.Interface); iface != "" {
			wanAfter["interface"] = iface
		}
	}

	pending := &PendingSwitch{
		Token:         newToken(),
		FromMode:      CommittedMode(c.cfg),
		ToMode:        req.Mode,
		ExpiresAt:     c.now().Add(time.Duration(req.ConfirmTimeoutSec) * time.Second).Format(time.RFC3339),
		WANBefore:     cloneMap(c.loadWANFile()),
		WANAfter:      wanAfter,
		HostsBefore:   LoadHosts(c.cfg),
		HostsAfter:    hosts,
		DataplaneNote: DataplaneNoteP2,
	}
	if err := SavePending(c.cfg, pending); err != nil {
		return Status{}, err
	}
	if err := SaveHosts(c.cfg, hosts); err != nil {
		_ = c.restoreFiles(pending)
		_ = ClearPending(c.cfg)
		return Status{}, err
	}
	if req.Mode == ModeBypass {
		if err := writeJSON(wanPath(c.cfg), wanAfter); err != nil {
			_ = c.restoreFiles(pending)
			_ = ClearPending(c.cfg)
			return Status{}, err
		}
		if c.applyWAN != nil {
			if _, err := c.applyWAN(wanAfter); err != nil {
				_ = c.restoreFiles(pending)
				_ = ClearPending(c.cfg)
				return Status{}, fmt.Errorf("WAN 应用失败，已回滚文件: %w", err)
			}
		}
	}
	if err := c.applyModeLocked(req.Mode); err != nil {
		_ = c.restoreFiles(pending)
		if pending.WANBefore != nil && c.applyWAN != nil {
			_, _ = c.applyWAN(pending.WANBefore)
		}
		_ = c.applyModeLocked(pending.FromMode)
		_ = ClearPending(c.cfg)
		return Status{}, fmt.Errorf("数据面应用失败，已回滚: %w", err)
	}

	c.armTimerLocked(pending)
	return c.statusLocked(), nil
}

func (c *Controller) Confirm(token string) (Status, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	pending, err := LoadPending(c.cfg)
	if err != nil {
		return Status{}, err
	}
	if pending == nil {
		return Status{}, fmt.Errorf("没有待确认的模式切换")
	}
	if PendingExpired(pending, c.now()) {
		_ = c.rollbackLocked("timeout")
		return Status{}, fmt.Errorf("确认已超时，WAN 与模式已回滚")
	}
	if token != "" && token != pending.Token {
		return Status{}, fmt.Errorf("确认令牌不匹配")
	}
	if err := SaveCommitted(c.cfg, pending.ToMode); err != nil {
		return Status{}, err
	}
	c.stopTimerLocked()
	_ = ClearPending(c.cfg)
	return c.statusLocked(), nil
}

func (c *Controller) Rollback() (Status, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.rollbackLocked("manual"); err != nil {
		return Status{}, err
	}
	return c.statusLocked(), nil
}

func (c *Controller) Resume() {
	c.mu.Lock()
	defer c.mu.Unlock()
	pending, _ := LoadPending(c.cfg)
	if pending == nil {
		return
	}
	if PendingExpired(pending, c.now()) {
		_ = c.rollbackLocked("timeout")
		return
	}
	_ = c.applyModeLocked(pending.ToMode)
	c.armTimerLocked(pending)
}

func (c *Controller) rollbackLocked(reason string) error {
	pending, err := LoadPending(c.cfg)
	if err != nil {
		return err
	}
	if pending == nil {
		return nil
	}
	c.stopTimerLocked()
	_ = c.restoreFiles(pending)
	if pending.WANBefore != nil && c.applyWAN != nil {
		if _, err := c.applyWAN(pending.WANBefore); err != nil {
			return fmt.Errorf("回滚 WAN 失败 (%s): %w", reason, err)
		}
	}
	if err := c.applyModeLocked(pending.FromMode); err != nil {
		return fmt.Errorf("回滚数据面失败 (%s): %w", reason, err)
	}
	return ClearPending(c.cfg)
}

func (c *Controller) restoreFiles(pending *PendingSwitch) error {
	if pending == nil {
		return nil
	}
	if pending.HostsBefore != nil {
		if err := SaveHosts(c.cfg, pending.HostsBefore); err != nil {
			return err
		}
	}
	if pending.WANBefore != nil {
		if err := writeJSON(wanPath(c.cfg), pending.WANBefore); err != nil {
			return err
		}
	}
	return nil
}

func (c *Controller) armTimerLocked(pending *PendingSwitch) {
	c.stopTimerLocked()
	if pending == nil {
		return
	}
	exp, err := time.Parse(time.RFC3339, pending.ExpiresAt)
	if err != nil {
		return
	}
	d := exp.Sub(c.now())
	if d < 0 {
		d = 0
	}
	c.timer = c.after(d, func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		_ = c.rollbackLocked("timeout")
	})
}

func (c *Controller) stopTimerLocked() {
	if c.timer != nil {
		c.timer.Stop()
		c.timer = nil
	}
}

func (c *Controller) statusLocked() Status {
	pending, _ := LoadPending(c.cfg)
	st := Status{
		Mode:           CommittedMode(c.cfg),
		DataplaneMode:  NormalizeMode(c.cfg.ProxyMode),
		CustomerHosts:  LoadHosts(c.cfg),
		LANCIDR:        firstNonEmpty(c.lanCIDR(), c.cfg.LanCIDR),
		DataplaneNote:  DataplaneNoteP2,
		OperateFromLAN: "请从管理 LAN 口操作本页。旁路切换会改 WAN 静态地址；超时未确认将自动回滚 WAN 与模式。",
	}
	if pending != nil {
		st.Pending = &PendingView{
			Token:       pending.Token,
			FromMode:    pending.FromMode,
			ToMode:      pending.ToMode,
			ExpiresAt:   pending.ExpiresAt,
			SecondsLeft: SecondsLeft(pending, c.now()),
		}
		st.Mode = NormalizeMode(pending.ToMode)
	}
	return st
}

func (c *Controller) loadWANFile() map[string]any {
	data, err := os.ReadFile(wanPath(c.cfg))
	if err != nil {
		return map[string]any{"enabled": true, "mode": "dhcp"}
	}
	var cfg map[string]any
	if json.Unmarshal(data, &cfg) != nil || cfg == nil {
		return map[string]any{"enabled": true, "mode": "dhcp"}
	}
	return cfg
}

func newToken() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b[:])
}

func cloneMap(in map[string]any) map[string]any {
	if in == nil {
		return map[string]any{}
	}
	raw, err := json.Marshal(in)
	if err != nil {
		out := make(map[string]any, len(in))
		for k, v := range in {
			out[k] = v
		}
		return out
	}
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	if out == nil {
		return map[string]any{}
	}
	return out
}

func firstNonEmpty(a, b string) string {
	if strings.TrimSpace(a) != "" {
		return strings.TrimSpace(a)
	}
	return strings.TrimSpace(b)
}

func (c *Controller) applyModeLocked(mode string) error {
	if c.applyMode == nil {
		return nil
	}
	return c.applyMode(NormalizeMode(mode))
}
