//go:build !darwin && !linux && !windows

package sysinfo

func listeningSockets([]int) ([]ListeningSocket, error) {
	return nil, nil
}
