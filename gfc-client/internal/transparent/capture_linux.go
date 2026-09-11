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

// Learn from ARP and IPv4 (incl. DHCP). ETH_P_ALL copies every cable frame
// into gfc-api and wedges LuCI/SSH on a live interconnect.
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

	open := func(role Role, name string, proto uint16) {
		if name == "" {
			return
		}
		wg.Add(1)
		go captureLoop(stop, role, name, proto, handle, register, unregister, &wg)
	}
	for _, proto := range []uint16{unix.ETH_P_ARP, unix.ETH_P_IP} {
		open(RoleISP, ports.ISP, proto)
		open(RoleCPE, ports.CPE, proto)
	}
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

func captureLoop(stop <-chan struct{}, role Role, name string, proto uint16, handle func(Role, []byte), register, unregister func(int), wg *sync.WaitGroup) {
	defer wg.Done()
	buf := make([]byte, 2048)
	for {
		select {
		case <-stop:
			return
		default:
		}
		fd, err := openPacket(name, proto)
		if err != nil {
			log.Printf("transparent: capture %s %s proto=%#x: %v", role, name, proto, err)
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

func openPacket(name string, etherType uint16) (int, error) {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return -1, err
	}
	proto := htons(etherType)
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
	// Bridge unicast (CPE→PE) is PACKET_OTHERHOST. IFF_PROMISC on the NIC
	// lets the bridge forward; the socket still drops OTHERHOST unless it
	// joins PACKET_MR_PROMISC (tcpdump does this; ETH_P_ALL is still avoided).
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

func htons(v uint16) uint16 {
	return (v << 8) | (v >> 8)
}
