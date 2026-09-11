//go:build linux

package transparent

import (
	"log"
	"net"
	"sync"

	"golang.org/x/sys/unix"
)

// Learn from ARP and IPv4 (incl. DHCP). ETH_P_ALL copies every cable frame
// into gfc-api and wedges LuCI/SSH on a live interconnect.
func startCapture(ports Ports, handle func(Role, []byte)) func() {
	var wg sync.WaitGroup
	var mu sync.Mutex
	var fds []int
	open := func(role Role, name string, proto uint16) {
		if name == "" {
			return
		}
		fd, err := openPacket(name, proto)
		if err != nil {
			log.Printf("transparent: capture %s proto=%#x: %v", name, proto, err)
			return
		}
		mu.Lock()
		fds = append(fds, fd)
		mu.Unlock()
		wg.Add(1)
		go func(role Role, name string, fd int) {
			defer wg.Done()
			buf := make([]byte, 2048)
			for {
				n, err := unix.Read(fd, buf)
				if err != nil {
					if err != unix.EBADF && err != unix.EINTR {
						log.Printf("transparent: capture read %s %s: %v", role, name, err)
					}
					return
				}
				if n < 14 {
					continue
				}
				frame := make([]byte, n)
				copy(frame, buf[:n])
				handle(role, frame)
			}
		}(role, name, fd)
	}
	for _, proto := range []uint16{unix.ETH_P_ARP, unix.ETH_P_IP} {
		open(RoleISP, ports.ISP, proto)
		open(RoleCPE, ports.CPE, proto)
	}
	return func() {
		mu.Lock()
		for _, fd := range fds {
			_ = unix.Close(fd)
		}
		fds = nil
		mu.Unlock()
		wg.Wait()
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
