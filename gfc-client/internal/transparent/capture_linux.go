//go:build linux

package transparent

import (
	"errors"
	"log"
	"net"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// Learn from ARP and IPv4 (incl. DHCP). Bridge slaves consume ETH_P_IP/ARP
// taps; ETH_P_ALL plus a kernel BPF (IPv4/ARP only) matches tcpdump.
func startCapture(ports Ports, handle func(Role, []byte)) func() {
	stop := make(chan struct{})
	var once sync.Once
	var wg sync.WaitGroup
	var mu sync.Mutex
	fds := make(map[int]struct{})

	register := func(fd int) {
		mu.Lock()
		if fds != nil {
			fds[fd] = struct{}{}
		} else {
			_ = unix.Close(fd)
		}
		mu.Unlock()
	}
	unregister := func(fd int) {
		mu.Lock()
		if fds != nil {
			delete(fds, fd)
		}
		mu.Unlock()
	}

	open := func(role Role, name string) {
		if name == "" {
			return
		}
		wg.Add(1)
		go captureLoop(stop, role, name, handle, register, unregister, &wg)
	}
	open(RoleISP, ports.ISP)
	open(RoleCPE, ports.CPE)
	return func() {
		once.Do(func() {
			close(stop)
			mu.Lock()
			for fd := range fds {
				_ = unix.Close(fd)
			}
			fds = nil
			mu.Unlock()
			wg.Wait()
		})
	}
}

func captureLoop(stop <-chan struct{}, role Role, name string, handle func(Role, []byte), register, unregister func(int), wg *sync.WaitGroup) {
	defer wg.Done()
	buf := make([]byte, 2048)
	for {
		select {
		case <-stop:
			return
		default:
		}
		fd, err := openPacket(name)
		if err != nil {
			log.Printf("transparent: capture %s %s: %v", role, name, err)
			if !waitRetry(stop, time.Second) {
				return
			}
			continue
		}
		register(fd)
		alive := readFrames(stop, fd, buf, role, name, handle)
		unregister(fd)
		_ = unix.Close(fd)
		if !alive {
			return
		}
		if !waitRetry(stop, 500*time.Millisecond) {
			return
		}
	}
}

func readFrames(stop <-chan struct{}, fd int, buf []byte, role Role, name string, handle func(Role, []byte)) bool {
	for {
		n, err := unix.Read(fd, buf)
		if err != nil {
			select {
			case <-stop:
				return false
			default:
			}
			if errors.Is(err, unix.EBADF) {
				return false
			}
			if errors.Is(err, unix.EINTR) {
				continue
			}
			if errors.Is(err, unix.ENETDOWN) || errors.Is(err, unix.ENETRESET) || errors.Is(err, unix.ENXIO) || errors.Is(err, unix.ENODEV) {
				log.Printf("transparent: capture rebind %s %s: %v", role, name, err)
				return true
			}
			log.Printf("transparent: capture read %s %s: %v", role, name, err)
			return true
		}
		if n < 14 {
			continue
		}
		frame := make([]byte, n)
		copy(frame, buf[:n])
		handle(role, frame)
	}
}

func waitRetry(stop <-chan struct{}, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-stop:
		return false
	case <-t.C:
		return true
	}
}

func openPacket(name string) (int, error) {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return -1, err
	}
	// ETH_P_ALL is required on a bridge slave: the bridge rx_handler consumes
	// the skb before ETH_P_IP/ARP taps run. tcpdump sees the same frames
	// because it also uses ETH_P_ALL. Kernel BPF keeps non-ARP/IPv4 out of
	// gfc-api (a busy interconnect must not copy every TCP segment).
	proto := htons(unix.ETH_P_ALL)
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_RAW, int(proto))
	if err != nil {
		return -1, err
	}
	_ = unix.SetsockoptInt(fd, unix.SOL_PACKET, unix.PACKET_IGNORE_OUTGOING, 1)
	sll := &unix.SockaddrLinklayer{
		Protocol: proto,
		Ifindex:  iface.Index,
	}
	if err := unix.Bind(fd, sll); err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	if err := attachARPIPFilter(fd); err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	// Bridge unicast (CPE→PE) is PACKET_OTHERHOST. IFF_PROMISC on the NIC
	// lets the bridge forward; the socket still drops OTHERHOST unless it
	// joins PACKET_MR_PROMISC (tcpdump does this).
	mreq := unix.PacketMreq{
		Ifindex: int32(iface.Index),
		Type:    unix.PACKET_MR_PROMISC,
	}
	if err := unix.SetsockoptPacketMreq(fd, unix.SOL_PACKET, unix.PACKET_ADD_MEMBERSHIP, &mreq); err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	return fd, nil
}

// attachARPIPFilter is tcpdump's "ether proto \ip or ether proto \arp".
func attachARPIPFilter(fd int) error {
	filter := []unix.SockFilter{
		{Code: 0x28, K: 12},                      // ldh [12]
		{Code: 0x15, Jt: 1, Jf: 0, K: etherIPv4}, // jeq IPv4
		{Code: 0x15, Jt: 0, Jf: 1, K: etherARP},  // jeq ARP
		{Code: 0x06, K: 0x40000},                 // ret #-1
		{Code: 0x06, K: 0},                       // ret #0
	}
	prog := unix.SockFprog{Len: uint16(len(filter)), Filter: &filter[0]}
	return unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, &prog)
}

func htons(v uint16) uint16 {
	return (v << 8) | (v >> 8)
}
