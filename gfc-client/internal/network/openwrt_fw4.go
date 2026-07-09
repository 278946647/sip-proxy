package network

// disableOpenWrtFW4 stops stock ImmortalWrt fw4; GFC gfc-routing owns nft NAT/FORWARD.
func disableOpenWrtFW4() error {
	if _, err := initd("firewall", "stop"); err != nil {
		_ = err
	}
	_, _ = initd("firewall", "disable")
	return nil
}
