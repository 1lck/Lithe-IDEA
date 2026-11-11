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
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// LedgerFile is the name of the ledger in the application's preferences directory.
const LedgerFile = "process-ledger.json"

// Supported says this platform can tell a process's start time and command (identity), so
// the ledger records the processes the app starts. On Windows it cannot, and nothing is
// recorded or found at the next start.
const Supported = runtime.GOOS != "windows"

// Record is one process the app started.
type Record struct {
	PID     int    `json:"pid"`
	Started string `json:"started"`
	Command string `json:"command"`
	// Kind is what the process is (KindRun and the others); empty for records written before kinds.
	Kind string `json:"kind,omitempty"`
}

// Ledger is the file of records. A nil Ledger records nothing, so platforms without the
// identity check (Windows here) run without one.
type Ledger struct {
	path string
	mu   sync.Mutex
}

// Kind names what a record is, so the start-up confirmation can label it.
const (
	KindRun      = "run"
	KindTerminal = "terminal"
	KindBuild    = "build"
	KindDebug    = "debug"
	KindProcess  = "process"
)

// ledgers memoizes one Ledger per directory, so every caller in the process shares one lock on the file.
var (
	ledgersMu sync.Mutex
	ledgers   = map[string]*Ledger{}
	active    *Ledger
)

// Open returns the ledger in dir, shared by every caller in the process. It does not read the file;
// Leftovers does.
func Open(dir string) *Ledger {
	if dir == "" {
		return nil
	}
	path := filepath.Join(dir, LedgerFile)
	ledgersMu.Lock()
	defer ledgersMu.Unlock()
	if l, ok := ledgers[path]; ok {
		return l
	}
	l := &Ledger{path: path}
	ledgers[path] = l
	return l
}

// Activate makes the ledger in dir the one Track records into, and returns it.
func Activate(dir string) *Ledger {
	l := Open(dir)
	ledgersMu.Lock()
	active = l
	ledgersMu.Unlock()
	return l
}

// Track records a started process of the given kind in the active ledger and returns the function
// that forgets it when the process has ended. Without an active ledger, or when the process cannot be
// identified, it records nothing and the function does nothing.
func Track(kind string, pid int) func() {
	ledgersMu.Lock()
	l := active
	ledgersMu.Unlock()
	if l == nil || pid <= 0 {
		return func() {}
	}
	if err := l.AddKind(kind, pid); err != nil {
		return func() {}
	}
	return func() { _ = l.Remove(pid) }
}

// Add records a started process. Errors are returned for the caller to report; a process that cannot
// be identified is not recorded.
func (l *Ledger) Add(pid int) error {
	return l.AddKind(KindRun, pid)
}

// AddKind records a started process of the given kind.
func (l *Ledger) AddKind(kind string, pid int) error {
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
	records = append(records, Record{PID: pid, Started: started, Command: command, Kind: kind})
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
		if current(record) {
			leftovers = append(leftovers, record)
		}
	}
	return leftovers, nil
}

// Settle forgets the given leftovers, and when end is true ends each one that is still the
// recorded process: every one is asked to stop at once, and those still running after grace are
// killed. Other records, including ones added since, stay in the ledger. It returns the number of
// processes that ended.
func (l *Ledger) Settle(ctx context.Context, settled []Record, end bool, grace time.Duration) (int, error) {
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
	return endProcesses(ctx, settled, grace)
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

// current reports that record's PID is still the process that was recorded.
func current(record Record) bool {
	started, command, ok := identity(record.PID)
	return ok && started == record.Started && command == record.Command
}

// endProcesses asks every recorded process that is still running to stop, waits up to grace for
// them to exit and kills the ones still running then. The identity is checked again before the
// kill, so a PID the system reused during the wait is left alone.
func endProcesses(ctx context.Context, records []Record, grace time.Duration) (int, error) {
	var failures []error
	var asked []Record
	for _, record := range records {
		if !current(record) {
			continue
		}
		if err := signal(record.PID, "TERM"); err != nil {
			failures = append(failures, err)
			continue
		}
		asked = append(asked, record)
	}
	ended := 0
	deadline := time.Now().Add(grace)
	for {
		running := asked[:0]
		for _, record := range asked {
			if current(record) {
				running = append(running, record)
			} else {
				ended++
			}
		}
		asked = running
		if len(asked) == 0 || !time.Now().Before(deadline) {
			break
		}
		select {
		case <-ctx.Done():
			return ended, errors.Join(append(failures, ctx.Err())...)
		case <-time.After(100 * time.Millisecond):
		}
	}
	for _, record := range asked {
		if err := signal(record.PID, "KILL"); err != nil {
			failures = append(failures, err)
			continue
		}
		ended++
	}
	return ended, errors.Join(failures...)
}

func signal(pid int, name string) error {
	return exec.Command("kill", "-"+name, strconv.Itoa(pid)).Run()
}
