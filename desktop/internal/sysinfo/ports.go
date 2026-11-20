package sysinfo

// ListeningSocket describes one TCP socket in the LISTEN state owned by a local process.
type ListeningSocket struct {
	PID     int
	Address string
	Port    uint16
}

// ListeningSockets returns every TCP listening socket held by the named process IDs.
// Unreachable or exited processes are skipped cleanly; an empty slice yields nil, nil.
func ListeningSockets(pids []int) ([]ListeningSocket, error) {
	if len(pids) == 0 {
		return nil, nil
	}
	seen := make(map[int]struct{}, len(pids))
	unique := make([]int, 0, len(pids))
	for _, pid := range pids {
		if pid <= 0 {
			continue
		}
		if _, ok := seen[pid]; ok {
			continue
		}
		seen[pid] = struct{}{}
		unique = append(unique, pid)
	}
	if len(unique) == 0 {
		return nil, nil
	}
	return listeningSockets(unique)
}
