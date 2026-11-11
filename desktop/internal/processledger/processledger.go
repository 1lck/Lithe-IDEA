// Package processledger remembers the processes this app started, so that a later start can end
// the ones an earlier run of the app left behind after it crashed or was killed.
//
// A record holds the PID together with the process's start time and command name. A PID is reused
// by the system, so a recorded PID is ended only when the process still has that start time and
// command: anything else with the same number belongs to someone else and is left alone. Only
// records this app wrote are considered; the ledger never searches for processes by name.
package processledger

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// LedgerFile is the name of the ledger in the application's preferences directory.
const LedgerFile = "process-ledger.json"

// stopWait bounds the wait between the polite and the forced end of a leftover process.
const stopWait = 2 * time.Second

// Record is one process the app started.
type Record struct {
	PID     int    `json:"pid"`
	Started string `json:"started"`
	Command string `json:"command"`
}

// Ledger is the file of records. A nil Ledger records nothing, so platforms without the
// identity check (Windows here) run without one.
type Ledger struct {
	path string
	mu   sync.Mutex
}

// Open returns the ledger in dir. It does not read the file; Sweep does.
func Open(dir string) *Ledger {
	if dir == "" {
		return nil
	}
	return &Ledger{path: filepath.Join(dir, LedgerFile)}
}

// Add records a started process. Errors are returned for the caller to report; a process that cannot
// be identified is not recorded.
func (l *Ledger) Add(pid int) error {
	if l == nil || pid <= 0 {
		return nil
	}
	started, command, ok := identity(pid)
	if !ok {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	records, err := l.read()
	if err != nil {
		return err
	}
	records = append(records, Record{PID: pid, Started: started, Command: command})
	return l.write(records)
}

// Remove forgets a process that ended on its own.
func (l *Ledger) Remove(pid int) error {
	if l == nil || pid <= 0 {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	records, err := l.read()
	if err != nil {
		return err
	}
	kept := records[:0]
	for _, record := range records {
		if record.PID != pid {
			kept = append(kept, record)
		}
	}
	if len(kept) == len(records) {
		return nil
	}
	return l.write(kept)
}

// Sweep ends the recorded processes that are still the processes that were recorded, then empties the
// ledger. It returns the number of processes it ended. Errors from ending one process do not stop the rest.
func (l *Ledger) Sweep(ctx context.Context) (int, error) {
	if l == nil {
		return 0, nil
	}
	l.mu.Lock()
	records, err := l.read()
	if err != nil {
		l.mu.Unlock()
		return 0, err
	}
	if err := l.write(nil); err != nil {
		l.mu.Unlock()
		return 0, err
	}
	l.mu.Unlock()
	ended := 0
	var failures []error
	for _, record := range records {
		started, command, ok := identity(record.PID)
		if !ok || started != record.Started || command != record.Command {
			continue
		}
		if err := endProcess(ctx, record.PID); err != nil {
			failures = append(failures, err)
			continue
		}
		ended++
	}
	return ended, errors.Join(failures...)
}

// Leftovers returns the recorded processes that are still the processes that were recorded. It
// ends nothing and changes nothing: the startup confirmation shows them and Settle acts on the answer.
func (l *Ledger) Leftovers() ([]Record, error) {
	if l == nil {
		return nil, nil
	}
	l.mu.Lock()
	records, err := l.read()
	l.mu.Unlock()
	if err != nil {
		return nil, err
	}
	var leftovers []Record
	for _, record := range records {
		started, command, ok := identity(record.PID)
		if ok && started == record.Started && command == record.Command {
			leftovers = append(leftovers, record)
		}
	}
	return leftovers, nil
}

// Settle forgets the given leftovers, and ends each one that is still the recorded process when end
// is true. Other records, including ones added since, stay in the ledger.
func (l *Ledger) Settle(ctx context.Context, settled []Record, end bool) (int, error) {
	if l == nil || len(settled) == 0 {
		return 0, nil
	}
	l.mu.Lock()
	records, err := l.read()
	if err != nil {
		l.mu.Unlock()
		return 0, err
	}
	kept := make([]Record, 0, len(records))
	for _, record := range records {
		if !slices.Contains(settled, record) {
			kept = append(kept, record)
		}
	}
	if err := l.write(kept); err != nil {
		l.mu.Unlock()
		return 0, err
	}
	l.mu.Unlock()
	if !end {
		return 0, nil
	}
	ended := 0
	var failures []error
	for _, record := range settled {
		started, command, ok := identity(record.PID)
		if !ok || started != record.Started || command != record.Command {
			continue
		}
		if err := endProcess(ctx, record.PID); err != nil {
			failures = append(failures, err)
			continue
		}
		ended++
	}
	return ended, errors.Join(failures...)
}

func (l *Ledger) read() ([]Record, error) {
	data, err := os.ReadFile(l.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var records []Record
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, nil
	}
	if err := json.Unmarshal(data, &records); err != nil {
		// A damaged ledger cannot identify anything safely, so it is treated as empty.
		return nil, nil
	}
	return records, nil
}

// write replaces the ledger atomically, so a crash never leaves half a file.
func (l *Ledger) write(records []Record) error {
	if err := os.MkdirAll(filepath.Dir(l.path), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(records)
	if err != nil {
		return err
	}
	temporary := l.path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, l.path)
}

// identity reads the start time and command name of a live process. ok is false when the process
// is gone or the platform cannot tell.
func identity(pid int) (started, command string, ok bool) {
	output, err := exec.Command("ps", "-o", "lstart=", "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "", "", false
	}
	line := strings.TrimSpace(string(output))
	if line == "" {
		return "", "", false
	}
	// lstart has a fixed width of 24 characters on the systems this runs on; the command follows it.
	if len(line) < 25 {
		return "", "", false
	}
	return strings.TrimSpace(line[:24]), strings.TrimSpace(line[24:]), true
}

// endProcess asks the process to stop, then kills it if it has not gone within stopWait.
func endProcess(ctx context.Context, pid int) error {
	if err := signal(pid, "TERM"); err != nil {
		return err
	}
	deadline := time.Now().Add(stopWait)
	for time.Now().Before(deadline) {
		if _, _, alive := identity(pid); !alive {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	return signal(pid, "KILL")
}

func signal(pid int, name string) error {
	return exec.Command("kill", "-"+name, strconv.Itoa(pid)).Run()
}
