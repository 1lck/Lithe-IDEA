// Package logstore is the desktop client's log writer: it queues structured events, hands them
// to the Rust kernel to encode, and appends the encoded lines to the session's channel files.
//
// The kernel owns everything about the logging format: the disk line, the event catalog, the
// channel file layout, the read plans, the queries and the retention plan. This package only
// does what the kernel cannot, which is file I/O and queuing. It never builds a log line, never
// computes a channel path and never filters a record itself.
//
// Logs are runtime state and live in a user-writable directory (see DefaultDir), never in the
// application bundle or the installation directory: writing there would change the installed
// bytes that differential updates depend on.
//
// One writer goroutine owns every file handle and every piece of mutable I/O state. Callers
// only touch a short critical section (Emit) or hand a job to the writer (everything else).
package logstore

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// Limits and cadences of the writer.
const (
	// defaultCapacity bounds the queue; defaultReserved of it is kept for WARN and ERROR so a
	// burst of lower severities can never push out the evidence that matters most.
	defaultCapacity = 8000
	defaultReserved = 2000
	// batchSize is the most events one encoder call takes.
	batchSize = 256
	// coalesceDelay lets a burst of events share one drain.
	coalesceDelay = 100 * time.Millisecond
	// kernelTick is how often the writer drains the kernel's own facts when the host is idle.
	kernelTick = 500 * time.Millisecond
	// maintenanceInterval is how often retention runs; the first run is the startup cleanup.
	maintenanceInterval = time.Minute
	// defaultFileLimit rotates a channel file before it grows past this size.
	defaultFileLimit = 10 << 20
	// totalLimit is the whole log directory's retention budget.
	totalLimit = 100 << 20
	// handleLimit is how many channel files stay open at once.
	handleLimit = 32
	// channelLimit is how many channels get their own cached file identity; further channels
	// share the kernel's overflow file.
	channelLimit = 128
	// headerLimit bounds the cached header lines.
	headerLimit = 129
	// diagnosticWindow is how long detailed diagnostics stay on after being enabled.
	diagnosticWindow = 900 * time.Second
	// recentCount and recentLimit bound the lines replayed to a new subscriber.
	recentCount = 2000
	recentLimit = 2 << 20
	// subscriberLimit is the most concurrent live subscribers.
	subscriberLimit = 16
	// controlLimit is the most control operations in flight; more are refused, not queued.
	controlLimit = 4
	// controlTimeout bounds how long one control operation may take.
	controlTimeout = 10 * time.Second
	// windowLimit and windowBuckets shape the log window's queries.
	windowLimit   = 10000
	windowBuckets = 90

	// settingsName is the preference file that remembers the user's log directory.
	settingsName = "logging.json"
	// overflowFile is the file the kernel assigns channels beyond channelLimit.
	overflowFile = "_overflow.log"
	// timeLayout is the RFC 3339 form the kernel takes, in UTC with milliseconds.
	timeLayout = "2006-01-02T15:04:05.000Z07:00"
)

var (
	// ErrClosed is returned by operations on a store that has been closed.
	ErrClosed = errors.New("logstore: closed")
	// ErrBusy is returned when too many control operations are already in flight.
	ErrBusy = errors.New("logstore: too many concurrent operations")

	errUnsafePath  = errors.New("logstore: unsafe log path")
	errNoDirectory = errors.New("logstore: no log directory")
)

// categories are the top-level directories older layouts kept their files in.
var categories = []string{"application", "language", "run", "git", "plugins", "performance"}

var (
	sessionNamePattern = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}_[a-f0-9]{8}$`)
	legacyNamePattern  = regexp.MustCompile(`^lithe\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\.[0-9]{3}Z\.[a-f0-9]{32}\.[0-9]{20}\.log$`)
)

// Kernel is the part of the Rust kernel the store needs. *core.Client implements it; tests wrap
// it to hold the writer at a known point.
type Kernel interface {
	EncodeLogBatch(ctx context.Context, batch core.LogBatch) (core.EncodedLogBatch, error)
	ResolveLogChannel(ctx context.Context, channel string, rotation int, existing []string) (core.LogChannelPath, error)
	PlanLogCollection(ctx context.Context, request core.LogCollectionRequest) (core.LogCollectionPlan, error)
	QueryLogs(ctx context.Context, query core.LogQuery) (core.LogQueryResult, error)
	PlanLogRetention(ctx context.Context, request core.LogRetentionRequest) (core.LogRetentionPlan, error)
	DrainCoreEvents(ctx context.Context) (core.CoreEvents, error)
	ConfigureCoreEvents(ctx context.Context, debug bool, roots []string) error
}

// Options configures Open.
type Options struct {
	// Kernel encodes, plans and queries; required.
	Kernel Kernel
	// Dir is the log directory. Empty means the directory saved in Settings, then DefaultDir.
	// A non-empty Dir overrides both and is also what RestoreDefaultDirectory returns to.
	Dir string
	// Settings persists the user's directory choice in logging.json as {"directory": "..."}.
	// Nil means the choice is not persisted.
	Settings *store.Store
	// Version is the bare application version token written into every file header.
	Version string
	// Now is the clock; nil means time.Now.
	Now func() time.Time

	// The fields below shrink the limits so tests reach them with a handful of events.
	capacity  int
	reserved  int
	fileLimit int
}

// directorySetting is the content of logging.json.
type directorySetting struct {
	Directory string `json:"directory"`
}

// queued is one accepted event waiting for the writer.
type queued struct {
	ts     time.Time
	level  core.LogLevel
	event  string
	op     string
	fields map[string]any
}

// openLog is one open channel file.
type openLog struct {
	file *os.File
	// size is the file's length as this store last saw it, header included.
	size int64
	// used orders the handles for least-recently-used eviction.
	used  uint64
	dirty bool
}

// diskFile is one file of the on-disk inventory.
type diskFile struct {
	path string
	// relative is relative to the log root. Root-level older files carry a virtual
	// "application/" prefix, the form the kernel's plans know them by.
	relative string
	// session is the session directory name, empty for older files outside sessions.
	session  string
	size     int64
	modified time.Time
}

// replay is the recent history owed to a subscriber that just joined.
type replay struct {
	sub     *subscriber
	batches []Batch
}

// Store queues, encodes and writes log events and answers queries about them. Every method is
// safe for concurrent use.
type Store struct {
	kernel     Kernel
	settings   *store.Store
	version    string
	now        func() time.Time
	defaultDir string
	sessionID  string
	pid        uint32
	started    time.Time
	capacity   int
	reserved   int
	fileLimit  int64

	// mu guards the ingress state and the fields the writer publishes to other goroutines.
	// Only the writer goroutine changes directory and sessionPath, so the writer itself may
	// read them without the lock.
	mu                sync.Mutex
	pending           []queued
	scheduled         bool
	urgent            bool
	dropped           int
	unreportedDropped int
	failures          int
	diagnosticUntil   time.Time
	stopped           bool
	controls          int
	directory         string
	sessionPath       string

	wake      chan struct{} // work was queued; arm the coalescing timer
	full      chan struct{} // a whole batch is waiting; drain now
	jobs      chan func()   // control operations, run on the writer
	quit      chan struct{}
	done      chan struct{}
	closeOnce sync.Once

	subsMu      sync.Mutex
	subscribers map[*subscriber]struct{}

	// Everything below is owned by the writer goroutine (and by Open before it starts).
	sequence        uint64
	previous        *core.LogEvent
	gateKnown       bool
	gateOn          bool
	channels        map[string][]string
	overflowPaths   []string
	headers         map[string]string
	handles         map[string]*openLog
	useCounter      uint64
	lastMaintenance time.Time
	startupDone     bool
	recent          []Batch
	recentBytes     int
	replays         []replay
}

// Open starts a store. It creates and probes the log directory, derives the session's path
// from the kernel, starts the writer and queues the app.session.started event. A custom
// directory that cannot be used falls back to the default one; Open fails only when no
// directory works.
func Open(opts Options) (*Store, error) {
	if opts.Kernel == nil {
		return nil, errors.New("logstore: a kernel is required")
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	version := opts.Version
	if version == "" {
		version = "0.0.0"
	}

	defaultDir := opts.Dir
	var defaultErr error
	if defaultDir == "" {
		defaultDir, defaultErr = DefaultDir()
	}
	chosen := opts.Dir
	if chosen == "" {
		chosen = loadDirectory(opts.Settings)
	}
	if chosen == "" {
		if defaultErr != nil {
			return nil, defaultErr
		}
		chosen = defaultDir
	}

	sessionID, err := newSessionID()
	if err != nil {
		return nil, fmt.Errorf("create the session id: %w", err)
	}
	capacity := max(1, opts.capacity)
	if opts.capacity == 0 {
		capacity = defaultCapacity
	}
	reserved := defaultReserved
	if opts.reserved != 0 || opts.capacity != 0 {
		reserved = opts.reserved
	}
	reserved = min(max(0, reserved), max(0, capacity-1))
	fileLimit := int64(defaultFileLimit)
	if opts.fileLimit > 0 {
		fileLimit = int64(opts.fileLimit)
	}

	s := &Store{
		kernel:      opts.Kernel,
		settings:    opts.Settings,
		version:     version,
		now:         now,
		defaultDir:  defaultDir,
		sessionID:   sessionID,
		pid:         uint32(os.Getpid()),
		started:     now(),
		capacity:    capacity,
		reserved:    reserved,
		fileLimit:   fileLimit,
		wake:        make(chan struct{}, 1),
		full:        make(chan struct{}, 1),
		jobs:        make(chan func()),
		quit:        make(chan struct{}),
		done:        make(chan struct{}),
		subscribers: make(map[*subscriber]struct{}),
		channels:    make(map[string][]string),
		headers:     make(map[string]string),
		handles:     make(map[string]*openLog),
	}
	if err := s.switchDirectory(chosen); err != nil {
		if defaultDir == "" || chosen == defaultDir {
			return nil, err
		}
		if fallbackErr := s.switchDirectory(defaultDir); fallbackErr != nil {
			return nil, fallbackErr
		}
	}
	// The header yields the session path, so SessionPath is valid as soon as Open returns.
	if _, err := s.header(context.Background(), "app"); err != nil {
		return nil, err
	}

	go s.run()
	s.Emit(core.LevelInfo, "app.session.started", "", nil)
	return s, nil
}

// newSessionID returns a random version 4 UUID in lowercase, the form the kernel's session
// naming expects.
func newSessionID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

// loadDirectory reads the user's saved log directory; an unreadable setting means none.
func loadDirectory(settings *store.Store) string {
	if settings == nil {
		return ""
	}
	var saved directorySetting
	if _, err := settings.Load(settingsName, &saved); err != nil || !filepath.IsAbs(saved.Directory) {
		return ""
	}
	return saved.Directory
}

// formatTime renders an instant the way the kernel takes it.
func formatTime(t time.Time) string {
	return t.UTC().Format(timeLayout)
}

// sessionName is the session directory name inside a session path such as sessions/<name>.
func sessionName(sessionPath string) string {
	if sessionPath == "" {
		return ""
	}
	return path.Base(sessionPath)
}

// fail counts one write or maintenance failure; queries report the total.
func (s *Store) fail() {
	s.mu.Lock()
	s.failures++
	s.mu.Unlock()
}

// signal wakes the writer without ever blocking the caller.
func signal(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	default:
	}
}

// Emit queues one event. It never blocks on I/O: when the queue is full the event is dropped
// and counted, and the writer later records the loss as a log.dropped event. WARN and ERROR
// have reserved room; DEBUG is accepted only while diagnostics are on. Fields are copied, so
// the caller may reuse the map.
func (s *Store) Emit(level core.LogLevel, event, op string, fields map[string]any) {
	at := s.now()
	s.mu.Lock()
	if s.stopped || (level == core.LevelDebug && !at.Before(s.diagnosticUntil)) {
		s.mu.Unlock()
		return
	}
	limit := s.capacity - s.reserved
	if level == core.LevelWarn || level == core.LevelError {
		limit = s.capacity
	}
	if len(s.pending) >= limit {
		s.dropped++
		s.unreportedDropped++
		s.mu.Unlock()
		return
	}
	s.pending = append(s.pending, queued{ts: at, level: level, event: event, op: op, fields: maps.Clone(fields)})
	var wake, full bool
	switch {
	case len(s.pending) >= batchSize && !s.urgent:
		s.urgent, s.scheduled, full = true, true, true
	case !s.scheduled:
		s.scheduled, wake = true, true
	}
	s.mu.Unlock()
	if full {
		signal(s.full)
	} else if wake {
		signal(s.wake)
	}
}

// Close drains the queue one last time, closes every file and ends the writer. It is safe to
// call more than once. It must not be called from a Subscribe callback.
func (s *Store) Close() {
	s.mu.Lock()
	s.stopped = true
	s.mu.Unlock()
	s.closeOnce.Do(func() { close(s.quit) })
	<-s.done
}

// Flush writes everything queued so far to disk before returning. It gives up after the
// control timeout if the writer is stuck.
func (s *Store) Flush() {
	_ = s.do(context.Background(), s.drain)
}

// Directory is the log directory in use.
func (s *Store) Directory() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.directory
}

// SessionPath is this process's session directory relative to Directory, for example
// sessions/2026-11-08T09-30-00_0d949d58.
func (s *Store) SessionPath() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sessionPath
}

// Stats reports how many events were dropped from a full queue and how many writes or
// maintenance steps failed since the process started.
func (s *Store) Stats() (dropped, writeFailures int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dropped, s.failures
}

// UsedBytes is the size of every log file in the directory, after writing what is queued. It is
// zero when the directory cannot be read.
func (s *Store) UsedBytes() int64 {
	var total int64
	err := s.do(context.Background(), func(ctx context.Context) error {
		if err := s.drain(ctx); err != nil {
			return err
		}
		if s.directory == "" {
			return errNoDirectory
		}
		files, err := inventory(s.directory)
		if err != nil {
			return err
		}
		for _, file := range files {
			total += file.size
		}
		return nil
	})
	if err != nil {
		return 0
	}
	return total
}

// Diagnostics reports whether detailed (DEBUG) diagnostics are on and how long until they turn
// themselves off. The category is empty: diagnostics always cover every category.
func (s *Store) Diagnostics() (category string, remaining time.Duration, on bool) {
	at := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.diagnosticsLocked(at)
}

func (s *Store) diagnosticsLocked(at time.Time) (string, time.Duration, bool) {
	if s.stopped || !at.Before(s.diagnosticUntil) {
		return "", 0, false
	}
	return "", s.diagnosticUntil.Sub(at), true
}

// ConfigureDiagnostics turns detailed diagnostics on or off. Turning them on lasts
// diagnosticWindow and then expires by itself; both the kernel's and the host's DEBUG events
// follow the same switch.
func (s *Store) ConfigureDiagnostics(enabled bool) {
	err := s.do(context.Background(), func(ctx context.Context) error {
		at := s.now()
		s.mu.Lock()
		if enabled {
			s.diagnosticUntil = at.Add(diagnosticWindow)
		} else {
			s.diagnosticUntil = time.Time{}
		}
		s.mu.Unlock()
		s.syncGate(ctx)
		return nil
	})
	if err != nil && !errors.Is(err, ErrClosed) {
		// The switch could not reach the writer: fail closed, and let the next tick tell the
		// kernel.
		s.mu.Lock()
		s.failures++
		s.diagnosticUntil = time.Time{}
		s.mu.Unlock()
	}
}

// ChangeDirectory moves logging to dir after writing what is queued, and remembers the choice
// in the settings. The old directory keeps its files. If the choice cannot be remembered the
// previous directory is restored and the error returned.
func (s *Store) ChangeDirectory(dir string) error {
	if dir == "" {
		return errNoDirectory
	}
	target, err := filepath.Abs(dir)
	if err != nil {
		return err
	}
	return s.relocate(target, target)
}

// RestoreDefaultDirectory moves logging back to the default directory and forgets the saved
// choice.
func (s *Store) RestoreDefaultDirectory() error {
	if s.defaultDir == "" {
		return errNoDirectory
	}
	return s.relocate(s.defaultDir, "")
}

// DefaultDirectory is the directory RestoreDefaultDirectory returns to, or empty when the
// platform has none. It is fixed when the store opens.
func (s *Store) DefaultDirectory() string {
	return s.defaultDir
}

// relocate switches to target and then saves saved as the remembered directory. Switching
// first validates the target with a probe file, so a bad directory is never saved.
func (s *Store) relocate(target, saved string) error {
	return s.do(context.Background(), func(ctx context.Context) error {
		if err := s.drain(ctx); err != nil {
			return err
		}
		previous := s.directory
		if err := s.switchDirectory(target); err != nil {
			return err
		}
		if s.settings == nil {
			return nil
		}
		if err := s.settings.Save(settingsName, directorySetting{Directory: saved}); err != nil {
			if previous != "" {
				_ = s.switchDirectory(previous)
			}
			return err
		}
		return nil
	})
}

// ClearLogs deletes every log file in the directory, including the current session's, and
// forgets the live history. Writing continues into fresh files.
func (s *Store) ClearLogs() error {
	return s.do(context.Background(), func(ctx context.Context) error {
		if err := s.drain(ctx); err != nil {
			return err
		}
		root := s.directory
		if root == "" {
			return nil
		}
		s.closeHandles()
		files, err := inventory(root)
		if err != nil {
			return err
		}
		var first error
		for _, file := range files {
			if err := ctx.Err(); err != nil {
				return err
			}
			if err := os.Remove(file.path); err != nil && !errors.Is(err, fs.ErrNotExist) && first == nil {
				first = err
			}
		}
		s.recent, s.recentBytes, s.previous = nil, 0, nil
		return first
	})
}

// do runs fn on the writer goroutine and waits for it. At most controlLimit operations are in
// flight; more are refused with ErrBusy instead of queuing without bound.
func (s *Store) do(ctx context.Context, fn func(context.Context) error) error {
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return ErrClosed
	}
	if s.controls >= controlLimit {
		s.mu.Unlock()
		return ErrBusy
	}
	s.controls++
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.controls--
		s.mu.Unlock()
	}()

	ctx, cancel := context.WithTimeout(ctx, controlTimeout)
	defer cancel()
	result := make(chan error, 1)
	job := func() {
		// An expired operation never starts; a running one checks the context between steps.
		if err := ctx.Err(); err != nil {
			result <- err
			return
		}
		result <- fn(ctx)
	}
	select {
	case s.jobs <- job:
	case <-ctx.Done():
		return ctx.Err()
	case <-s.done:
		return ErrClosed
	}
	// The writer has the job, so it always answers; fn is bounded by ctx checks and file I/O.
	return <-result
}

// run is the writer goroutine's loop. It is the only code that touches the open files.
func (s *Store) run() {
	defer close(s.done)
	ticker := time.NewTicker(kernelTick)
	defer ticker.Stop()

	var coalesce *time.Timer
	var coalesceC <-chan time.Time
	disarm := func() {
		if coalesce != nil {
			coalesce.Stop()
			coalesce, coalesceC = nil, nil
		}
	}
	defer disarm()

	for {
		select {
		case <-s.wake:
			if coalesce == nil {
				coalesce = time.NewTimer(coalesceDelay)
				coalesceC = coalesce.C
			}
		case <-s.full:
			disarm()
			s.drainSafely()
		case <-coalesceC:
			coalesce, coalesceC = nil, nil
			s.drainSafely()
		case <-ticker.C:
			// Also drains the kernel's own facts and expires diagnostics when the host is idle.
			disarm()
			s.drainSafely()
		case job := <-s.jobs:
			job()
			s.deliverReplays()
		case <-s.quit:
			s.shutdown()
			return
		}
	}
}

// shutdown runs the final drain, which also switches the kernel's DEBUG gate off because the
// store is stopped, then releases every resource.
func (s *Store) shutdown() {
	s.drainSafely()
	s.closeHandles()
	s.subsMu.Lock()
	for sub := range s.subscribers {
		sub.cancelled.Store(true)
	}
	clear(s.subscribers)
	s.subsMu.Unlock()
	s.replays = nil
}

func (s *Store) drainSafely() {
	if err := s.drain(context.Background()); err != nil {
		s.fail()
	}
}

// syncGate pushes the DEBUG gate to the kernel when it differs from what the kernel was last
// told. A failed push is not retried until the wanted state changes, so a broken kernel cannot
// make every drain fail again.
func (s *Store) syncGate(ctx context.Context) {
	at := s.now()
	s.mu.Lock()
	_, _, on := s.diagnosticsLocked(at)
	s.mu.Unlock()
	if s.gateKnown && s.gateOn == on {
		return
	}
	s.gateKnown, s.gateOn = true, on
	if err := s.kernel.ConfigureCoreEvents(ctx, on, nil); err != nil {
		s.fail()
	}
}

// diagnosticsOn reports whether DEBUG events are admitted right now.
func (s *Store) diagnosticsOn() bool {
	_, _, on := s.Diagnostics()
	return on
}

// input turns a queued host event into an encoder input and assigns its sequence number.
func (s *Store) input(event queued) core.LogEvent {
	s.sequence++
	return core.LogEvent{
		Ts:     formatTime(event.ts),
		Level:  event.level,
		Seq:    s.sequence,
		Event:  event.event,
		Op:     event.op,
		Fields: event.fields,
	}
}

// coreInput turns a fact the kernel recorded into an encoder input. The kernel's channel is
// passed along; the sequence is the writer's.
func (s *Store) coreInput(event core.CoreEvent) core.LogEvent {
	s.sequence++
	ts := event.Ts
	if ts == "" {
		ts = formatTime(s.now())
	}
	return core.LogEvent{
		Ts:      ts,
		Level:   event.Level,
		Seq:     s.sequence,
		Event:   event.Event,
		Op:      event.Op,
		Fields:  event.Fields,
		Channel: event.Channel,
	}
}

// drain takes everything queued plus the kernel's facts, encodes it in batches, appends the
// lines, runs due maintenance and syncs the files that changed. Once it has taken the queue it
// finishes even if ctx ends, because accepted events belong to the process, not to the caller
// that asked for the flush. Failures are counted, not returned: a failed drain must not stop a
// query from reading what is on disk.
func (s *Store) drain(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	ctx = context.WithoutCancel(ctx)

	s.mu.Lock()
	work := s.pending
	s.pending = nil
	unreported := s.unreportedDropped
	s.unreportedDropped = 0
	s.scheduled, s.urgent = false, false
	s.mu.Unlock()

	s.syncGate(ctx)
	coreWork, err := s.kernel.DrainCoreEvents(ctx)
	if err != nil {
		s.fail()
		coreWork = core.CoreEvents{}
	}

	var batch []core.LogEvent
	add := func(event core.LogEvent) {
		batch = append(batch, event)
		if len(batch) >= batchSize {
			s.persist(ctx, batch)
			batch = batch[:0]
		}
	}
	diagnostics := s.diagnosticsOn()
	for _, event := range coreWork.Events {
		if event.Level == core.LevelDebug && !diagnostics {
			continue
		}
		add(s.coreInput(event))
	}
	for _, event := range work {
		add(s.input(event))
	}
	if unreported > 0 || coreWork.Dropped > 0 {
		count := uint64(unreported) + coreWork.Dropped
		if count < coreWork.Dropped {
			count = ^uint64(0)
		}
		s.sequence++
		add(core.LogEvent{
			Ts:      formatTime(s.now()),
			Level:   core.LevelWarn,
			Seq:     s.sequence,
			Event:   "log.dropped",
			Msg:     "Dropped events",
			Fields:  map[string]any{"count": count},
			Channel: "app",
		})
	}
	if len(batch) > 0 {
		s.persist(ctx, batch)
	}

	at := s.now()
	if s.directory != "" && (s.lastMaintenance.IsZero() || at.Sub(s.lastMaintenance) >= maintenanceInterval) {
		s.maintain(ctx, at)
	}
	s.syncHandles()
	return nil
}

// persist encodes one batch and appends the resulting lines. The caller keeps ownership of
// batch and may reuse it afterwards.
func (s *Store) persist(ctx context.Context, batch []core.LogEvent) {
	encoded, err := s.kernel.EncodeLogBatch(ctx, core.LogBatch{
		Events:          batch,
		ValidateCatalog: true,
		Deduplicate:     true,
		Previous:        s.previous,
	})
	if err != nil {
		s.fail()
		return
	}
	// The next call hands the last input back so the kernel can fold consecutive duplicates
	// across batch boundaries; the slice is reused, so keep a copy.
	last := batch[len(batch)-1]
	s.previous = &last

	published := make([]Batch, 0, len(encoded.Results))
	for _, result := range encoded.Results {
		if result.Error != nil || result.Line == "" || result.Channel == "" {
			s.fail()
			continue
		}
		entry := Batch{Channel: result.Channel, Line: result.Line}
		if s.write(ctx, entry) {
			published = append(published, entry)
		}
	}
	if len(published) == 0 {
		return
	}

	s.recent = append(s.recent, published...)
	for _, entry := range published {
		s.recentBytes += len(entry.Line)
	}
	for len(s.recent) > recentCount || s.recentBytes > recentLimit {
		s.recentBytes -= len(s.recent[0].Line)
		s.recent = s.recent[1:]
	}
	s.publish(published)
}

// write appends one encoded line and reports whether it should be shown to live subscribers.
// A custom directory that stopped working must not lose evidence, so one failure moves logging
// to the default directory and tries once more. The line stays visible live even when that
// retry fails too, so the failure can be diagnosed from the window; it is dropped only when
// there is no other directory to try.
func (s *Store) write(ctx context.Context, entry Batch) bool {
	if err := s.appendEntry(ctx, entry); err == nil {
		return true
	}
	s.fail()
	if s.defaultDir == "" || s.directory == s.defaultDir {
		return false
	}
	if err := s.switchDirectory(s.defaultDir); err != nil {
		s.fail()
		return false
	}
	if err := s.appendEntry(ctx, entry); err != nil {
		s.fail()
	}
	return true
}

// publish hands freshly written lines to the live subscribers, on the writer goroutine.
func (s *Store) publish(batches []Batch) {
	s.subsMu.Lock()
	subs := make([]*subscriber, 0, len(s.subscribers))
	for sub := range s.subscribers {
		subs = append(subs, sub)
	}
	s.subsMu.Unlock()
	for _, sub := range subs {
		if !sub.cancelled.Load() {
			sub.fn(batches)
		}
	}
}

// deliverReplays sends the recent history to subscribers that joined during the last job. It
// runs after the job has answered, so a subscriber's callback never blocks its own Subscribe.
func (s *Store) deliverReplays() {
	replays := s.replays
	s.replays = nil
	for _, r := range replays {
		if !r.sub.cancelled.Load() {
			r.sub.fn(r.batches)
		}
	}
}

// header returns the header line (with its newline) that starts a channel's file, asking the
// kernel to encode it the first time. The first call also fixes the session path.
func (s *Store) header(ctx context.Context, channel string) (string, error) {
	if text, ok := s.headers[channel]; ok {
		return text, nil
	}
	encoded, err := s.kernel.EncodeLogBatch(ctx, core.LogBatch{Headers: []core.LogHeader{{
		Session: s.sessionID,
		Pid:     s.pid,
		App:     s.version,
		Channel: channel,
		Started: formatTime(s.started),
	}}})
	if err != nil {
		return "", err
	}
	if len(encoded.Headers) != 1 || encoded.Headers[0].Error != nil || encoded.Headers[0].Line == "" || encoded.SessionPath == "" {
		return "", errors.New("logstore: the kernel rejected the session header")
	}
	s.mu.Lock()
	s.sessionPath = encoded.SessionPath
	s.mu.Unlock()
	text := encoded.Headers[0].Line + "\n"
	if len(s.headers) < headerLimit {
		s.headers[channel] = text
	}
	return text, nil
}

// channelPaths returns the kernel's file paths for a channel at rotation 0, 1 and 2, resolving
// them once. Channels beyond channelLimit share the overflow paths so the cache stays bounded.
func (s *Store) channelPaths(ctx context.Context, channel string) ([]string, error) {
	paths := s.channels[channel]
	if paths == nil && len(s.channels) >= channelLimit {
		paths = s.overflowPaths
	}
	if paths != nil {
		return paths, nil
	}
	existing := slices.Sorted(maps.Keys(s.channels))
	paths = make([]string, 0, 3)
	for rotation := 0; rotation <= 2; rotation++ {
		resolved, err := s.kernel.ResolveLogChannel(ctx, channel, rotation, existing)
		if err != nil {
			return nil, err
		}
		paths = append(paths, resolved.RelativePath)
	}
	// Only admitted identities are cached per channel; overflow identities must not grow memory.
	if paths[0] == overflowFile {
		s.overflowPaths = paths
	} else {
		s.channels[channel] = paths
	}
	return paths, nil
}

// safePath joins a kernel-relative path to root and refuses anything that could leave it: an
// absolute path, a "." or ".." component, a symbolic link or reparse point on the way.
func safePath(root, relative string) (string, error) {
	if relative == "" || strings.HasPrefix(relative, "/") || filepath.IsAbs(relative) || filepath.VolumeName(relative) != "" {
		return "", errUnsafePath
	}
	current := root
	for _, part := range strings.Split(relative, "/") {
		if part == "" {
			continue
		}
		if part == "." || part == ".." || strings.ContainsAny(part, "\\\x00") || (runtime.GOOS == "windows" && strings.Contains(part, ":")) {
			return "", errUnsafePath
		}
		current = filepath.Join(current, part)
		if info, err := os.Lstat(current); err == nil && info.Mode()&(os.ModeSymlink|os.ModeIrregular) != 0 {
			return "", errUnsafePath
		}
	}
	if current == root {
		return "", errUnsafePath
	}
	return current, nil
}

// appendEntry writes one line to its channel's file, opening, rotating and evicting handles as
// needed. A new file starts with the channel's header line.
func (s *Store) appendEntry(ctx context.Context, entry Batch) error {
	root := s.directory
	if root == "" {
		return errNoDirectory
	}
	paths, err := s.channelPaths(ctx, entry.Channel)
	if err != nil {
		return err
	}
	headerChannel := entry.Channel
	if strings.HasPrefix(paths[0], "_overflow") {
		headerChannel = "_overflow"
	}
	headerText, err := s.header(ctx, headerChannel)
	if err != nil {
		return err
	}
	session := s.sessionPath
	relative := session + "/" + paths[0]
	target, err := safePath(root, relative)
	if err != nil {
		return err
	}
	data := []byte(entry.Line + "\n")

	// An open descriptor survives unlink and replacement; compare identity before every append
	// so accepted evidence always lands in a file that has a live path.
	if opened := s.handles[relative]; opened != nil && !matchesActiveFile(opened, target) {
		delete(s.handles, relative)
		s.closeLog(opened)
	}
	if opened := s.handles[relative]; opened != nil && opened.size+int64(len(data)) > s.fileLimit {
		if err := s.rotate(root, session, paths, relative); err != nil {
			return err
		}
	}
	if s.handles[relative] == nil {
		if size := fileSize(target); size > 0 && size+int64(len(data)) > s.fileLimit {
			if err := s.rotate(root, session, paths, relative); err != nil {
				return err
			}
		}
		if len(s.handles) >= handleLimit {
			s.evictOldest()
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return err
		}
		file, err := os.OpenFile(target, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
		if err != nil {
			return err
		}
		info, err := file.Stat()
		if err != nil {
			s.closeLog(&openLog{file: file})
			return err
		}
		opened := &openLog{file: file, size: info.Size(), used: s.useCounter}
		if opened.size == 0 {
			written, err := file.WriteString(headerText)
			opened.size += int64(written)
			opened.dirty = written > 0
			if err != nil {
				s.closeLog(opened)
				return err
			}
		}
		s.handles[relative] = opened
	}

	opened := s.handles[relative]
	written, err := opened.file.Write(data)
	opened.size += int64(written)
	if err != nil {
		// A handle that failed mid-write is unreliable; the next append opens a fresh one.
		delete(s.handles, relative)
		s.closeLog(opened)
		return err
	}
	s.useCounter++
	opened.used = s.useCounter
	opened.dirty = true
	return nil
}

// matchesActiveFile reports whether the open handle still is the file at target, at the size
// this store last saw.
func matchesActiveFile(opened *openLog, target string) bool {
	descriptor, err := opened.file.Stat()
	if err != nil {
		return false
	}
	onDisk, err := os.Lstat(target)
	if err != nil {
		return false
	}
	return os.SameFile(descriptor, onDisk) && descriptor.Size() == opened.size && onDisk.Size() == opened.size
}

// rotate shifts a channel's files up one slot: the oldest is deleted, rotation 1 becomes 2 and
// the active file becomes 1. The kernel keeps every rotation in a distinct path, which is
// verified before anything is moved.
func (s *Store) rotate(root, session string, paths []string, key string) error {
	if opened := s.handles[key]; opened != nil {
		delete(s.handles, key)
		s.closeLog(opened)
	}
	targets := make([]string, len(paths))
	distinct := make(map[string]struct{}, len(paths))
	for i, relative := range paths {
		target, err := safePath(root, session+"/"+relative)
		if err != nil {
			return err
		}
		targets[i] = target
		distinct[target] = struct{}{}
	}
	if len(targets) != 3 || len(distinct) != 3 {
		return errors.New("logstore: the kernel returned overlapping rotation paths")
	}
	if exists(targets[2]) {
		if err := os.Remove(targets[2]); err != nil {
			return err
		}
	}
	for i := 1; i >= 0; i-- {
		if exists(targets[i]) {
			if err := os.Rename(targets[i], targets[i+1]); err != nil {
				return err
			}
		}
	}
	return nil
}

// evictOldest closes the least recently written handle.
func (s *Store) evictOldest() {
	var oldestKey string
	var oldest *openLog
	for key, opened := range s.handles {
		if oldest == nil || opened.used < oldest.used {
			oldestKey, oldest = key, opened
		}
	}
	if oldest != nil {
		delete(s.handles, oldestKey)
		s.closeLog(oldest)
	}
}

// closeLog flushes and closes a handle, counting a failure to do so.
func (s *Store) closeLog(opened *openLog) {
	if opened.dirty {
		if err := opened.file.Sync(); err != nil {
			s.fail()
		}
	}
	if err := opened.file.Close(); err != nil {
		s.fail()
	}
}

func (s *Store) closeHandles() {
	for key, opened := range s.handles {
		s.closeLog(opened)
		delete(s.handles, key)
	}
}

// syncHandles makes the files written since the last drain durable.
func (s *Store) syncHandles() {
	for _, opened := range s.handles {
		if !opened.dirty {
			continue
		}
		opened.dirty = false
		if err := opened.file.Sync(); err != nil {
			s.fail()
		}
	}
}

// switchDirectory creates and probes target, then makes it the log directory. Open handles are
// closed because they belong to the old directory, and the next maintenance run is a startup
// cleanup again.
func (s *Store) switchDirectory(target string) error {
	if err := os.MkdirAll(target, 0o700); err != nil {
		return err
	}
	probe, err := os.CreateTemp(target, ".lithe-probe-*")
	if err != nil {
		return err
	}
	name := probe.Name()
	closeErr := probe.Close()
	if err := os.Remove(name); err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	s.closeHandles()
	s.mu.Lock()
	s.directory = target
	s.mu.Unlock()
	s.previous = nil
	s.lastMaintenance = time.Time{}
	s.startupDone = false
	return nil
}

func exists(target string) bool {
	_, err := os.Lstat(target)
	return err == nil
}

func fileSize(target string) int64 {
	info, err := os.Stat(target)
	if err != nil {
		return 0
	}
	return info.Size()
}

// inventory lists the log files under root that the kernel's plans know: session files, and
// the older layouts' files directly in the root or in a category directory. It never follows
// symbolic links, skips hidden entries and ignores directories it does not recognize.
func inventory(root string) ([]diskFile, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	var files []diskFile
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") || entry.Type()&(fs.ModeSymlink|fs.ModeIrregular) != 0 {
			continue
		}
		switch {
		case entry.IsDir() && name == "sessions":
			files = append(files, sessionFiles(root)...)
		case entry.IsDir() && slices.Contains(categories, name):
			files = append(files, categoryFiles(root, name)...)
		case entry.Type().IsRegular() && isLegacyName(name):
			if file, ok := describe(filepath.Join(root, name), "application/"+name, "", entry); ok {
				files = append(files, file)
			}
		}
	}
	return files, nil
}

func isLegacyName(name string) bool {
	return name == "lithe.log" || legacyNamePattern.MatchString(name)
}

// describe reads a directory entry's size and modification time.
func describe(target, relative, session string, entry fs.DirEntry) (diskFile, bool) {
	info, err := entry.Info()
	if err != nil {
		return diskFile{}, false
	}
	return diskFile{path: target, relative: relative, session: session, size: info.Size(), modified: info.ModTime()}, true
}

// sessionFiles lists every regular file below each well-named session directory.
func sessionFiles(root string) []diskFile {
	sessionsDir := filepath.Join(root, "sessions")
	entries, err := os.ReadDir(sessionsDir)
	if err != nil {
		return nil
	}
	var files []diskFile
	for _, entry := range entries {
		name := entry.Name()
		if !entry.IsDir() || !sessionNamePattern.MatchString(name) {
			continue
		}
		base := filepath.Join(sessionsDir, name)
		// WalkDir does not follow links found below base, and base itself is a real directory.
		_ = filepath.WalkDir(base, func(target string, d fs.DirEntry, walkErr error) error {
			if walkErr != nil || target == base {
				return nil
			}
			if strings.HasPrefix(d.Name(), ".") {
				if d.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
			if !d.Type().IsRegular() {
				return nil
			}
			inside, err := filepath.Rel(base, target)
			if err != nil {
				return nil
			}
			if file, ok := describe(target, "sessions/"+name+"/"+filepath.ToSlash(inside), name, d); ok {
				files = append(files, file)
			}
			return nil
		})
	}
	return files
}

// categoryFiles lists the older layouts' files directly inside a category directory.
func categoryFiles(root, category string) []diskFile {
	entries, err := os.ReadDir(filepath.Join(root, category))
	if err != nil {
		return nil
	}
	var files []diskFile
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") || !entry.Type().IsRegular() || !isLegacyName(name) {
			continue
		}
		if file, ok := describe(filepath.Join(root, category, name), category+"/"+name, "", entry); ok {
			files = append(files, file)
		}
	}
	return files
}

// maintain asks the kernel which files to delete to stay within the retention budget and
// deletes them. A failed run is retried at the next interval, and the startup cleanup flag
// stays set until one run succeeds.
func (s *Store) maintain(ctx context.Context, at time.Time) {
	if err := s.runRetention(ctx, s.directory, at); err != nil {
		s.fail()
	}
	s.lastMaintenance = at
}

func (s *Store) runRetention(ctx context.Context, root string, at time.Time) error {
	files, err := inventory(root)
	if err != nil {
		return err
	}
	originals := make(map[string]string, len(files))
	bySession := make(map[string][]core.LogFile)
	var legacy []core.LogFile
	for _, file := range files {
		originals[file.relative] = file.path
		entry := core.LogFile{RelativePath: file.relative, SizeBytes: uint64(max(0, file.size)), ModifiedAt: formatTime(file.modified)}
		if file.session != "" {
			entry.RelativePath = strings.TrimPrefix(file.relative, "sessions/"+file.session+"/")
			bySession[file.session] = append(bySession[file.session], entry)
		} else {
			legacy = append(legacy, entry)
		}
	}
	sessions := make([]core.LogSession, 0, len(bySession))
	for _, name := range slices.Sorted(maps.Keys(bySession)) {
		sessions = append(sessions, core.LogSession{Name: name, Files: bySession[name]})
	}
	current := sessionName(s.sessionPath)
	plan, err := s.kernel.PlanLogRetention(ctx, core.LogRetentionRequest{
		Sessions:       sessions,
		LegacyFiles:    legacy,
		CurrentSession: current,
		Now:            formatTime(at),
		Limits:         core.LogRetentionLimits{TotalBytes: totalLimit},
		StartupCleanup: !s.startupDone,
	})
	if err != nil {
		return err
	}
	currentPrefix := "sessions/" + current
	for _, deletion := range plan.Deletions {
		if err := ctx.Err(); err != nil {
			return err
		}
		// The current session is never retention's to delete, whatever the plan says.
		if deletion.RelativePath == currentPrefix || strings.HasPrefix(deletion.RelativePath, currentPrefix+"/") {
			continue
		}
		target, ok := originals[deletion.RelativePath]
		if !ok {
			if target, err = safePath(root, deletion.RelativePath); err != nil {
				s.fail()
				continue
			}
		}
		if deletion.Directory {
			err = os.RemoveAll(target)
		} else {
			err = os.Remove(target)
		}
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			s.fail()
		}
	}
	s.startupDone = true
	return nil
}
