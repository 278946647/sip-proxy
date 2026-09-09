//go:build linux

package transparent

import (
	"log"
	"net"
	"sync"

	"golang.org/x/sys/unix"
)

func startCapture(ports Ports, handle func(Role, []byte)) func() {
	var wg sync.WaitGroup
	var mu sync.Mutex
	var fds []int
	open := func(role Role, name string) {
		if name == "" {
			return
		}
		fd, err := openPacket(name)
		if err != nil {
			log.Printf("transparent: capture %s: %v", name, err)
			return
		}
		mu.Lock()
		fds = append(fds, fd)
		mu.Unlock()
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 2048)
			for {
				n, err := unix.Read(fd, buf)
				if err != nil {
					return
				}
				if n < 14 {
					continue
				}
				frame := make([]byte, n)
				copy(frame, buf[:n])
				handle(role, frame)
			}
		}()
	}
	open(RoleISP, ports.ISP)
	open(RoleCPE, ports.CPE)
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

func openPacket(name string) (int, error) {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return -1, err
	}
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_RAW, int(htons(unix.ETH_P_ALL)))
	if err != nil {
		return -1, err
	}
	sll := &unix.SockaddrLinklayer{
		Protocol: htons(unix.ETH_P_ALL),
		Ifindex:  iface.Index,
	}
	if err := unix.Bind(fd, sll); err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	return fd, nil
}

func htons(v uint16) uint16 {
	return (v << 8) | (v >> 8)
}
