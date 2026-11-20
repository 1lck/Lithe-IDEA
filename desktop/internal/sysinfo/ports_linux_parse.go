package sysinfo

import (
	"encoding/binary"
	"encoding/hex"
	"net/netip"
	"strconv"
	"strings"
)

type procTCPListener struct {
	address string
	port    uint16
}

// parseProcNetTCP parses Linux /proc/net/tcp or /proc/net/tcp6 contents and returns
// socket inode -> listening endpoint for rows in TCP_LISTEN ("0A").
func parseProcNetTCP(data []byte, ipv6 bool) map[uint64]procTCPListener {
	out := make(map[uint64]procTCPListener)
	lines := strings.Split(string(data), "\n")
	for _, line := range lines[min(1, len(lines)):] {
		fields := strings.Fields(line)
		// Columns: sl, local_address, rem_address, st, tx_queue:rx_queue, tr:tm->when, retrnsmt, uid, timeout, inode
		if len(fields) < 10 || fields[3] != "0A" {
			continue
		}
		addrHex, portHex, ok := strings.Cut(fields[1], ":")
		if !ok {
			continue
		}
		port64, err := strconv.ParseUint(portHex, 16, 16)
		if err != nil || port64 == 0 {
			continue
		}
		inode, err := strconv.ParseUint(fields[9], 10, 64)
		if err != nil || inode == 0 {
			continue
		}
		addr, ok := parseProcHexIP(addrHex, ipv6)
		if !ok {
			continue
		}
		out[inode] = procTCPListener{
			address: addr,
			port:    uint16(port64),
		}
	}
	return out
}

func parseProcHexIP(raw string, ipv6 bool) (string, bool) {
	buf, err := hex.DecodeString(raw)
	if err != nil {
		return "", false
	}
	if !ipv6 {
		if len(buf) != 4 {
			return "", false
		}
		// /proc/net/tcp encodes IPv4 as one host-endian 32-bit word on little-endian Linux hosts.
		v := binary.LittleEndian.Uint32(buf)
		var ip [4]byte
		binary.BigEndian.PutUint32(ip[:], v)
		return netip.AddrFrom4(ip).String(), true
	}
	if len(buf) != 16 {
		return "", false
	}
	// /proc/net/tcp6 encodes four little-endian 32-bit words in network order.
	var ip [16]byte
	for i := 0; i < 4; i++ {
		word := binary.LittleEndian.Uint32(buf[i*4 : i*4+4])
		binary.BigEndian.PutUint32(ip[i*4:i*4+4], word)
	}
	addr := netip.AddrFrom16(ip)
	return addr.String(), true
}
