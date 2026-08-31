package policyrouting

import (
	"encoding/binary"
	"fmt"
	"net"
	"strings"
	"time"
)

type dnsReply struct {
	QName string
	IPs   []string
	TTL   time.Duration
}

func udpPayloadFromIPv4(pkt []byte) (payload []byte, srcPort, dstPort uint16) {
	if len(pkt) < 20 {
		return nil, 0, 0
	}
	if pkt[0]>>4 != 4 {
		return nil, 0, 0
	}
	ihl := int(pkt[0]&0x0f) * 4
	if ihl < 20 || len(pkt) < ihl+8 {
		return nil, 0, 0
	}
	frag := binary.BigEndian.Uint16(pkt[6:8])
	if frag&0x1fff != 0 {
		return nil, 0, 0
	}
	if pkt[9] != 17 {
		return nil, 0, 0
	}
	udp := pkt[ihl:]
	srcPort = binary.BigEndian.Uint16(udp[0:2])
	dstPort = binary.BigEndian.Uint16(udp[2:4])
	ulen := int(binary.BigEndian.Uint16(udp[4:6]))
	if ulen >= 8 && len(udp) >= ulen {
		return udp[8:ulen], srcPort, dstPort
	}
	return udp[8:], srcPort, dstPort
}

func decodeDNSName(msg []byte, offset int) (name string, next int, err error) {
	var labels []string
	jumped := false
	next = offset
	for hops := 0; hops < 128; hops++ {
		if offset >= len(msg) {
			return "", 0, fmt.Errorf("dns name truncated")
		}
		l := int(msg[offset])
		if l == 0 {
			offset++
			if !jumped {
				next = offset
			}
			return strings.Join(labels, "."), next, nil
		}
		if l&0xC0 == 0xC0 {
			if offset+1 >= len(msg) {
				return "", 0, fmt.Errorf("dns pointer truncated")
			}
			ptr := int(l&0x3F)<<8 | int(msg[offset+1])
			if ptr >= len(msg) {
				return "", 0, fmt.Errorf("dns pointer oob")
			}
			if !jumped {
				next = offset + 2
				jumped = true
			}
			offset = ptr
			continue
		}
		if l&0xC0 != 0 {
			return "", 0, fmt.Errorf("dns label reserved")
		}
		offset++
		if offset+l > len(msg) {
			return "", 0, fmt.Errorf("dns label truncated")
		}
		labels = append(labels, strings.ToLower(string(msg[offset:offset+l])))
		offset += l
	}
	return "", 0, fmt.Errorf("dns name loop")
}

func parseDNSReply(msg []byte) (dnsReply, bool) {
	var out dnsReply
	if len(msg) < 12 {
		return out, false
	}
	flags := binary.BigEndian.Uint16(msg[2:4])
	if flags&0x8000 == 0 {
		return out, false
	}
	qd := int(binary.BigEndian.Uint16(msg[4:6]))
	an := int(binary.BigEndian.Uint16(msg[6:8]))
	ns := int(binary.BigEndian.Uint16(msg[8:10]))
	ar := int(binary.BigEndian.Uint16(msg[10:12]))
	if qd < 1 {
		return out, false
	}
	off := 12
	for i := 0; i < qd; i++ {
		name, n, err := decodeDNSName(msg, off)
		if err != nil {
			return out, false
		}
		off = n + 4
		if off > len(msg) {
			return out, false
		}
		if i == 0 {
			out.QName = canonDomain(name)
		}
	}
	if out.QName == "" {
		return out, false
	}
	seen := map[string]struct{}{}
	var minTTL uint32
	total := an + ns + ar
	for i := 0; i < total; i++ {
		_, n, err := decodeDNSName(msg, off)
		if err != nil {
			break
		}
		off = n
		if off+10 > len(msg) {
			break
		}
		typ := binary.BigEndian.Uint16(msg[off : off+2])
		ttl := binary.BigEndian.Uint32(msg[off+4 : off+8])
		rdlen := int(binary.BigEndian.Uint16(msg[off+8 : off+10]))
		off += 10
		if off+rdlen > len(msg) {
			break
		}
		if typ == 1 && rdlen == 4 {
			ip := net.IPv4(msg[off], msg[off+1], msg[off+2], msg[off+3]).To4()
			if ip != nil {
				s := ip.String()
				if _, ok := seen[s]; !ok {
					seen[s] = struct{}{}
					out.IPs = append(out.IPs, s)
				}
				if minTTL == 0 || ttl < minTTL {
					minTTL = ttl
				}
			}
		}
		off += rdlen
	}
	if len(out.IPs) == 0 {
		return out, false
	}
	out.TTL = time.Duration(minTTL) * time.Second
	return out, true
}

func applyDNSReply(etc string, targets []snoopTarget, reply dnsReply) {
	if len(targets) == 0 || reply.QName == "" || len(reply.IPs) == 0 {
		return
	}
	for _, t := range targets {
		pat := matchingPattern(reply.QName, t.Members)
		if pat == "" {
			continue
		}
		recordSnoopHit(etc, t.GroupID, t.SetName, reply.QName, pat, reply.IPs, reply.TTL)
	}
}
