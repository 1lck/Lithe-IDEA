//go:build windows

package sysinfo

import (
	"encoding/binary"
	"net/netip"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	modIphlpapi             = windows.NewLazySystemDLL("iphlpapi.dll")
	procGetExtendedTcpTable = modIphlpapi.NewProc("GetExtendedTcpTable")
)

const (
	tcpTableOwnerPIDListener = 3
	errInsufficientBuffer    = windows.Errno(122)
)

// mibTCPRowOwnerPID matches Windows MIB_TCPROW_OWNER_PID (20 bytes).
type mibTCPRowOwnerPID struct {
	State      uint32
	LocalAddr  uint32
	LocalPort  uint32
	RemoteAddr uint32
	RemotePort uint32
	OwningPID  uint32
}

// mibTCP6RowOwnerPID matches Windows MIB_TCP6ROW_OWNER_PID (56 bytes).
type mibTCP6RowOwnerPID struct {
	LocalAddr     [16]byte
	LocalScopeID  uint32
	LocalPort     uint32
	RemoteAddr    [16]byte
	RemoteScopeID uint32
	RemotePort    uint32
	State         uint32
	OwningPID     uint32
}

func listeningSockets(pids []int) ([]ListeningSocket, error) {
	wanted := make(map[uint32]struct{}, len(pids))
	for _, pid := range pids {
		if pid > 0 {
			wanted[uint32(pid)] = struct{}{}
		}
	}
	if len(wanted) == 0 {
		return nil, nil
	}

	var out []ListeningSocket
	v4, err := readWindowsTCPTable(windows.AF_INET)
	if err == nil && len(v4) >= 4 {
		count := int(binary.LittleEndian.Uint32(v4[:4]))
		const rowSize = int(unsafe.Sizeof(mibTCPRowOwnerPID{}))
		if len(v4) >= 4+count*rowSize {
			rows := unsafe.Slice((*mibTCPRowOwnerPID)(unsafe.Pointer(&v4[4])), count)
			for _, row := range rows {
				if _, ok := wanted[row.OwningPID]; !ok {
					continue
				}
				port := tcpPortFromWinDWORD(row.LocalPort)
				if port == 0 {
					continue
				}
				var ip [4]byte
				binary.LittleEndian.PutUint32(ip[:], row.LocalAddr)
				out = append(out, ListeningSocket{
					PID:     int(row.OwningPID),
					Address: netip.AddrFrom4(ip).String(),
					Port:    port,
				})
			}
		}
	}

	v6, err6 := readWindowsTCPTable(windows.AF_INET6)
	if err6 == nil && len(v6) >= 4 {
		count := int(binary.LittleEndian.Uint32(v6[:4]))
		const rowSize = int(unsafe.Sizeof(mibTCP6RowOwnerPID{}))
		if len(v6) >= 4+count*rowSize {
			rows := unsafe.Slice((*mibTCP6RowOwnerPID)(unsafe.Pointer(&v6[4])), count)
			for _, row := range rows {
				if _, ok := wanted[row.OwningPID]; !ok {
					continue
				}
				port := tcpPortFromWinDWORD(row.LocalPort)
				if port == 0 {
					continue
				}
				out = append(out, ListeningSocket{
					PID:     int(row.OwningPID),
					Address: netip.AddrFrom16(row.LocalAddr).String(),
					Port:    port,
				})
			}
		}
	}

	if err != nil && err6 != nil {
		return nil, err
	}
	return out, nil
}

func tcpPortFromWinDWORD(raw uint32) uint16 {
	return uint16(raw&0xff)<<8 | uint16((raw>>8)&0xff)
}

func readWindowsTCPTable(family uint32) ([]byte, error) {
	var size uint32
	r0, _, _ := procGetExtendedTcpTable.Call(
		0,
		uintptr(unsafe.Pointer(&size)),
		0,
		uintptr(family),
		uintptr(tcpTableOwnerPIDListener),
		0,
	)
	if size == 0 {
		if r0 != 0 && windows.Errno(r0) != errInsufficientBuffer {
			return nil, windows.Errno(r0)
		}
		return nil, nil
	}
	buf := make([]byte, size)
	r0, _, _ = procGetExtendedTcpTable.Call(
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(unsafe.Pointer(&size)),
		0,
		uintptr(family),
		uintptr(tcpTableOwnerPIDListener),
		0,
	)
	if r0 != 0 {
		return nil, windows.Errno(r0)
	}
	return buf[:size], nil
}
