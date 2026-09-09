//go:build !linux

package transparent

func startCapture(ports Ports, handle func(Role, []byte)) func() {
	_ = ports
	_ = handle
	return func() {}
}
