package policyrouting

import (
	"encoding/binary"
	"path/filepath"
	"testing"
)

func writeDNSName(buf []byte, name string) []byte {
	for _, lab := range splitDNSLabels(name) {
		buf = append(buf, byte(len(lab)))
		buf = append(buf, lab...)
	}
	return append(buf, 0)
}

func splitDNSLabels(name string) [][]byte {
	if name == "" {
		return nil
	}
	parts := [][]byte{}
	start := 0
	for i := 0; i <= len(name); i++ {
		if i == len(name) || name[i] == '.' {
			parts = append(parts, []byte(name[start:i]))
			start = i + 1
		}
	}
	return parts
}

func TestParseDNSReplyA(t *testing.T) {
	msg := make([]byte, 12)
	binary.BigEndian.PutUint16(msg[0:], 0x1234)
	binary.BigEndian.PutUint16(msg[2:], 0x8180)
	binary.BigEndian.PutUint16(msg[4:], 1)
	binary.BigEndian.PutUint16(msg[6:], 1)
	msg = writeDNSName(msg, "platform.linkedin.com")
	msg = append(msg, 0, 1, 0, 1) // QTYPE A QCLASS IN
	msg = append(msg, 0xc0, 12)   // pointer to QNAME
	rr := make([]byte, 10)
	binary.BigEndian.PutUint16(rr[0:], 1)   // A
	binary.BigEndian.PutUint16(rr[2:], 1)   // IN
	binary.BigEndian.PutUint32(rr[4:], 300) // TTL
	binary.BigEndian.PutUint16(rr[8:], 4)
	msg = append(msg, rr...)
	msg = append(msg, 1, 2, 3, 4)

	got, ok := parseDNSReply(msg)
	if !ok {
		t.Fatal("parse failed")
	}
	if got.QName != "platform.linkedin.com" {
		t.Fatalf("qname=%s", got.QName)
	}
	if len(got.IPs) != 1 || got.IPs[0] != "1.2.3.4" {
		t.Fatalf("ips=%v", got.IPs)
	}
	if got.TTL.Seconds() != 300 {
		t.Fatalf("ttl=%s", got.TTL)
	}
}

func TestParseDNSReplyCNAMEAdditionalA(t *testing.T) {
	// QNAME CNAME + A in additional; parser must keep QNAME and collect the A.
	msg := make([]byte, 12)
	binary.BigEndian.PutUint16(msg[0:], 0x1234)
	binary.BigEndian.PutUint16(msg[2:], 0x8180)
	binary.BigEndian.PutUint16(msg[4:], 1) // QD
	binary.BigEndian.PutUint16(msg[6:], 1) // AN = CNAME
	binary.BigEndian.PutUint16(msg[10:], 1) // AR = A
	msg = writeDNSName(msg, "platform.linkedin.com")
	msg = append(msg, 0, 1, 0, 1) // QTYPE A QCLASS IN
	msg = append(msg, 0xc0, 12)   // CNAME owner = QNAME
	cnameHdr := make([]byte, 10)
	binary.BigEndian.PutUint16(cnameHdr[0:], 5) // CNAME
	binary.BigEndian.PutUint16(cnameHdr[2:], 1)
	binary.BigEndian.PutUint32(cnameHdr[4:], 60)
	cnameTarget := writeDNSName(nil, "static.licdn.com")
	binary.BigEndian.PutUint16(cnameHdr[8:], uint16(len(cnameTarget)))
	msg = append(msg, cnameHdr...)
	msg = append(msg, cnameTarget...)
	msg = writeDNSName(msg, "static.licdn.com")
	aHdr := make([]byte, 10)
	binary.BigEndian.PutUint16(aHdr[0:], 1)
	binary.BigEndian.PutUint16(aHdr[2:], 1)
	binary.BigEndian.PutUint32(aHdr[4:], 120)
	binary.BigEndian.PutUint16(aHdr[8:], 4)
	msg = append(msg, aHdr...)
	msg = append(msg, 9, 8, 7, 6)

	got, ok := parseDNSReply(msg)
	if !ok {
		t.Fatal("parse failed")
	}
	if got.QName != "platform.linkedin.com" {
		t.Fatalf("qname=%s", got.QName)
	}
	if len(got.IPs) != 1 || got.IPs[0] != "9.8.7.6" {
		t.Fatalf("ips=%v", got.IPs)
	}
	if got.TTL.Seconds() != 120 {
		t.Fatalf("ttl=%s", got.TTL)
	}
}

func TestApplyDNSReplyMatchesWildcard(t *testing.T) {
	dir := t.TempDir()
	targets := []snoopTarget{{
		GroupID: "g1", SetName: "usr_dom_g1", Members: []string{"*.linkedin.com"},
	}}
	applyDNSReply(dir, targets, dnsReply{
		QName: "platform.linkedin.com",
		IPs:   []string{"8.8.8.8"},
		TTL:   minSnoopTTL,
	})
	m := loadDomainMapFile(filepath.Join(dir, DirName, DomainMapFile))
	g := m.Groups["g1"]
	if len(g.Learned) != 1 || g.Learned[0].QName != "platform.linkedin.com" {
		t.Fatalf("learned=%+v", g.Learned)
	}
	if len(g.IPs) != 1 || g.IPs[0] != "8.8.8.8" {
		t.Fatalf("ips=%v", g.IPs)
	}
}
