//go:build linux

package policyrouting

import (
	"context"
	"log"
	"net"
	"strings"
	"time"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

func startDNSSnoopImpl(cfg *config.Config, envFn func() Env) {
	var cancel context.CancelFunc
	var lastKey string
	reload := func() {
		env := envFn()
		lan := resolveLanIface(cfg)
		wan := ""
		if strings.EqualFold(strings.TrimSpace(env.ProxyMode), "bypass") {
			wan = cfg.ResolvedWanIface()
		}
		targets := loadSnoopTargets(cfg)
		key := snoopCaptureKey(lan, wan, targets)
		if key == lastKey {
			return
		}
		if cancel != nil {
			cancel()
			cancel = nil
		}
		lastKey = key
		if len(targets) == 0 {
			return
		}
		ctx, c := context.WithCancel(context.Background())
		cancel = c
		ifaces := uniqueIfaces("lo", lan, wan)
		log.Printf("policy-routing dns-snoop start ifaces=%v groups=%d", ifaces, len(targets))
		tcopy := append([]snoopTarget(nil), targets...)
		for _, iface := range ifaces {
			go captureDNSIface(ctx, cfg.Paths.Etc, iface, tcopy)
		}
	}
	reload()
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			reload()
		case <-snoopKick:
			lastKey = ""
			reload()
		}
	}
}

func snoopCaptureKey(lan, wan string, targets []snoopTarget) string {
	var b strings.Builder
	b.WriteString(lan)
	b.WriteByte('|')
	b.WriteString(wan)
	for _, t := range targets {
		b.WriteByte('|')
		b.WriteString(t.GroupID)
		b.WriteByte(':')
		b.WriteString(strings.Join(t.Members, ","))
	}
	return b.String()
}

func uniqueIfaces(names ...string) []string {
	seen := map[string]struct{}{}
	var out []string
	for _, n := range names {
		n = strings.TrimSpace(n)
		if n == "" {
			continue
		}
		if _, ok := seen[n]; ok {
			continue
		}
		seen[n] = struct{}{}
		out = append(out, n)
	}
	return out
}

func htons(v uint16) uint16 {
	return (v << 8) | (v >> 8)
}

func udp53SockFilter() ([]unix.SockFilter, error) {
	raw, err := bpf.Assemble([]bpf.Instruction{
		bpf.LoadAbsolute{Off: 9, Size: 1},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: 17, SkipFalse: 9},
		bpf.LoadAbsolute{Off: 0, Size: 1},
		bpf.ALUOpConstant{Op: bpf.ALUOpAnd, Val: 0x0f},
		bpf.ALUOpConstant{Op: bpf.ALUOpShiftLeft, Val: 2},
		bpf.TAX{},
		bpf.LoadIndirect{Off: 0, Size: 2},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: 53, SkipTrue: 2},
		bpf.LoadIndirect{Off: 2, Size: 2},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: 53, SkipFalse: 1},
		bpf.RetConstant{Val: 0xffff},
		bpf.RetConstant{Val: 0},
	})
	if err != nil {
		return nil, err
	}
	out := make([]unix.SockFilter, len(raw))
	for i, r := range raw {
		out[i] = unix.SockFilter{Code: r.Op, Jt: r.Jt, Jf: r.Jf, K: r.K}
	}
	return out, nil
}

func captureDNSIface(ctx context.Context, etc, ifaceName string, targets []snoopTarget) {
	ifi, err := net.InterfaceByName(ifaceName)
	if err != nil {
		log.Printf("policy-routing dns-snoop iface %s: %v", ifaceName, err)
		return
	}
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_DGRAM, int(htons(unix.ETH_P_IP)))
	if err != nil {
		log.Printf("policy-routing dns-snoop socket %s: %v", ifaceName, err)
		return
	}
	defer unix.Close(fd)

	filter, err := udp53SockFilter()
	if err != nil {
		log.Printf("policy-routing dns-snoop bpf: %v", err)
		return
	}
	prog := unix.SockFprog{Len: uint16(len(filter)), Filter: &filter[0]}
	if err := unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, &prog); err != nil {
		log.Printf("policy-routing dns-snoop attach filter %s: %v", ifaceName, err)
		return
	}

	sa := &unix.SockaddrLinklayer{
		Protocol: htons(unix.ETH_P_IP),
		Ifindex:  ifi.Index,
	}
	if err := unix.Bind(fd, sa); err != nil {
		log.Printf("policy-routing dns-snoop bind %s: %v", ifaceName, err)
		return
	}
	tv := unix.Timeval{Sec: 1}
	_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &tv)

	buf := make([]byte, 2048)
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		n, _, err := unix.Recvfrom(fd, buf, 0)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		if n < 28 {
			continue
		}
		payload, sport, _ := udpPayloadFromIPv4(buf[:n])
		if sport != 53 || len(payload) < 12 {
			continue
		}
		reply, ok := parseDNSReply(payload)
		if !ok {
			continue
		}
		applyDNSReply(etc, targets, reply)
	}
}
