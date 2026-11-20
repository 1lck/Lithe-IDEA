//go:build linux

package sysinfo

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func listeningSockets(pids []int) ([]ListeningSocket, error) {
	inodes := make(map[uint64]procTCPListener)
	for _, path := range []struct {
		file string
		ipv6 bool
	}{
		{"/proc/net/tcp", false},
		{"/proc/net/tcp6", true},
	} {
		data, err := os.ReadFile(path.file)
		if err != nil {
			continue
		}
		for inode, listener := range parseProcNetTCP(data, path.ipv6) {
			inodes[inode] = listener
		}
	}
	if len(inodes) == 0 {
		return nil, nil
	}
	var out []ListeningSocket
	for _, pid := range pids {
		fdDir := "/proc/" + strconv.Itoa(pid) + "/fd"
		entries, err := os.ReadDir(fdDir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			target, err := os.Readlink(filepath.Join(fdDir, entry.Name()))
			if err != nil {
				continue
			}
			inner, ok := strings.CutPrefix(target, "socket:[")
			if !ok {
				continue
			}
			inodeText, ok := strings.CutSuffix(inner, "]")
			if !ok {
				continue
			}
			inode, err := strconv.ParseUint(inodeText, 10, 64)
			if err != nil {
				continue
			}
			if listener, found := inodes[inode]; found {
				out = append(out, ListeningSocket{
					PID:     pid,
					Address: listener.address,
					Port:    listener.port,
				})
			}
		}
	}
	return out, nil
}
