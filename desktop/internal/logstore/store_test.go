package logstore

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// The real kernel client must satisfy Kernel, or the store could not be opened with it.
var _ Kernel = (*core.Client)(nil)

// waitLimit bounds every wait in this file. Nothing here sleeps to wait for the writer: a
// flush is a job the writer answers, and the one test that needs the writer held still holds it
// with a channel.
const waitLimit = 10 * time.Second

// testClock is the injected clock. Every reading moves it forward one millisecond, so events
// get increasing timestamps without the test depending on real time; Advance jumps it.
type testClock struct {
	mu sync.Mutex
	at time.Time
}

func newTestClock() *testClock {
	return &testClock{at: time.Date(2026, 11, 8, 9, 30, 0, 0, time.UTC)}
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = c.at.Add(time.Millisecond)
	return c.at
}

func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = c.at.Add(d)
}

// openStore opens a store on the real kernel in a temporary directory. mutate may change the
// options first, including the directory. The store is closed before the directory is removed.
func openStore(t *testing.T, mutate func(*Options)) (*Store, *testClock, string) {
	t.Helper()
	clock := newTestClock()
	opts := Options{Kernel: core.NewClient(), Version: "0.1.0", Now: clock.Now}
	if mutate != nil {
		mutate(&opts)
	}
	if opts.Dir == "" {
		opts.Dir = t.TempDir()
	}
	s, err := Open(opts)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(s.Close)
	return s, clock, opts.Dir
}

// flush writes everything queued and fails the test if the writer does not answer.
func flush(t *testing.T, s *Store) {
	t.Helper()
	if err := s.do(context.Background(), s.drain); err != nil {
		t.Fatalf("flush: %v", err)
	}
}

// window queries the current session through the store.
func window(t *testing.T, s *Store, q Query) core.LogQueryResult {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), waitLimit)
	defer cancel()
	collection, err := s.QueryWindow(ctx, q)
	if err != nil {
		t.Fatalf("QueryWindow: %v", err)
	}
	return collection.Result
}

// action queues one catalog event whose action field identifies it.
func action(s *Store, name string) {
	s.Emit(core.LevelInfo, "app.action.performed", "", map[string]any{"action": name, "surface": "button"})
}

func eventCounts(records []core.LogRecord) map[string]int {
	counts := make(map[string]int)
	for _, record := range records {
		counts[record.Event]++
	}
	return counts
}

// fieldValues lists, sorted, the value of one field across the records of one event.
func fieldValues(records []core.LogRecord, event, field string) []string {
	var values []string
	for _, record := range records {
		if record.Event == event {
			values = append(values, record.Fields[field])
		}
	}
	slices.Sort(values)
	return values
}

// readTree concatenates every regular file below root.
func readTree(t *testing.T, root string) string {
	t.Helper()
	var text strings.Builder
	err := filepath.WalkDir(root, func(target string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.Type().IsRegular() {
			return nil
		}
		data, err := os.ReadFile(target)
		if err != nil {
			return err
		}
		text.Write(data)
		return nil
	})
	if err != nil {
		t.Fatalf("read %s: %v", root, err)
	}
	return text.String()
}

// gatedKernel holds the writer inside the kernel's event drain until released, which freezes
// the writer at a known point without sleeping.
type gatedKernel struct {
	Kernel
	armed     atomic.Bool
	entered   chan struct{}
	release   chan struct{}
	enterOnce sync.Once
	freeOnce  sync.Once
}

func newGatedKernel() *gatedKernel {
	return &gatedKernel{Kernel: core.NewClient(), entered: make(chan struct{}), release: make(chan struct{})}
}

func (g *gatedKernel) DrainCoreEvents(ctx context.Context) (core.CoreEvents, error) {
	if g.armed.Load() {
		g.enterOnce.Do(func() { close(g.entered) })
		<-g.release
	}
	return g.Kernel.DrainCoreEvents(ctx)
}

// free lets the writer go; it is safe to call more than once.
func (g *gatedKernel) free() {
	g.freeOnce.Do(func() { close(g.release) })
}

// recordingKernel remembers every DEBUG gate the store pushes to the kernel.
type recordingKernel struct {
	Kernel
	mu    sync.Mutex
	gates []bool
}

func (r *recordingKernel) ConfigureCoreEvents(ctx context.Context, debug bool, roots []string) error {
	r.mu.Lock()
	r.gates = append(r.gates, debug)
	r.mu.Unlock()
	return r.Kernel.ConfigureCoreEvents(ctx, debug, roots)
}

func (r *recordingKernel) states() []bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.gates)
}

func TestOpenRequiresKernel(t *testing.T) {
	if _, err := Open(Options{Dir: t.TempDir()}); err == nil {
		t.Fatal("Open without a kernel succeeded")
	}
}

func TestStoreWritesSessionFilesAndAnswersQueries(t *testing.T) {
	s, _, dir := openStore(t, nil)
	if s.Directory() != dir {
		t.Fatalf("Directory = %q, want %q", s.Directory(), dir)
	}
	if !strings.HasPrefix(s.SessionPath(), "sessions/2026-11-08T") {
		t.Fatalf("SessionPath = %q", s.SessionPath())
	}

	for i := range 3 {
		action(s, fmt.Sprintf("step_%d", i))
	}
	s.Flush()
	flush(t, s)

	ctx, cancel := context.WithTimeout(context.Background(), waitLimit)
	defer cancel()
	collection, err := s.QueryWindow(ctx, Query{Session: "current"})
	if err != nil {
		t.Fatalf("QueryWindow: %v", err)
	}
	counts := eventCounts(collection.Result.Records)
	if counts["app.session.started"] != 1 || counts["app.action.performed"] != 3 {
		t.Fatalf("event counts = %v", counts)
	}
	if got := fieldValues(collection.Result.Records, "app.action.performed", "action"); !slices.Equal(got, []string{"step_0", "step_1", "step_2"}) {
		t.Fatalf("actions = %v", got)
	}
	if collection.Result.Histogram == nil {
		t.Fatal("the window result has no histogram")
	}
	if collection.Directory != dir || collection.CurrentSessionPath != s.SessionPath() {
		t.Fatalf("collection = %q, %q", collection.Directory, collection.CurrentSessionPath)
	}
	if dropped, failures := s.Stats(); dropped != 0 || failures != 0 {
		t.Fatalf("Stats = %d dropped, %d failures", dropped, failures)
	}
	if s.UsedBytes() == 0 {
		t.Fatal("UsedBytes = 0 after writing")
	}

	path, err := s.kernel.ResolveLogChannel(ctx, "app", 0, nil)
	if err != nil {
		t.Fatalf("ResolveLogChannel: %v", err)
	}
	file := filepath.Join(dir, filepath.FromSlash(s.SessionPath()), filepath.FromSlash(path.RelativePath))
	info, err := os.Stat(file)
	if err != nil {
		t.Fatalf("the app channel file is missing: %v", err)
	}
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	// A header line, then at least the three action lines.
	if lines := strings.Count(string(data), "\n"); lines < 4 {
		t.Fatalf("the app channel file has %d lines", lines)
	}
	if runtime.GOOS != "windows" {
		if mode := info.Mode().Perm(); mode != 0o600 {
			t.Fatalf("file mode = %v, want 0600", mode)
		}
		sessions, err := os.Stat(filepath.Join(dir, "sessions"))
		if err != nil {
			t.Fatal(err)
		}
		if mode := sessions.Mode().Perm(); mode != 0o700 {
			t.Fatalf("directory mode = %v, want 0700", mode)
		}
	}
}

func TestSubscribeReceivesBatchesThatQueryWindowBatchParses(t *testing.T) {
	s, _, _ := openStore(t, nil)
	received := make(chan []Batch, 64)
	deliver := func(batches []Batch) {
		select {
		case received <- batches:
		default:
		}
	}
	collect := func() []Batch {
		var all []Batch
		for {
			select {
			case batches := <-received:
				all = append(all, batches...)
			default:
				return all
			}
		}
	}

	cancel := s.Subscribe(deliver)
	t.Cleanup(cancel)
	action(s, "step_0")
	action(s, "step_1")
	flush(t, s)

	batches := collect()
	for _, batch := range batches {
		if batch.Channel == "" || batch.Line == "" {
			t.Fatalf("incomplete batch %+v", batch)
		}
	}
	ctx, stop := context.WithTimeout(context.Background(), waitLimit)
	defer stop()
	result, err := s.QueryWindowBatch(ctx, batches, Query{})
	if err != nil {
		t.Fatalf("QueryWindowBatch: %v", err)
	}
	counts := eventCounts(result.Records)
	if counts["app.session.started"] != 1 || counts["app.action.performed"] != 2 {
		t.Fatalf("event counts = %v", counts)
	}
	for _, record := range result.Records {
		if !strings.HasPrefix(record.RelativePath, s.SessionPath()+"/") {
			t.Fatalf("record path %q is outside the session %q", record.RelativePath, s.SessionPath())
		}
	}
	summary, err := s.LiveSummary(ctx, result.Records)
	if err != nil {
		t.Fatalf("LiveSummary: %v", err)
	}
	if summary.Histogram == nil || summary.Dropped != 0 || summary.WriteFailures != 0 {
		t.Fatalf("LiveSummary = %+v", summary)
	}

	// A subscriber that joins late first receives the recent lines.
	late := make(chan []Batch, 64)
	lateCancel := s.Subscribe(func(batches []Batch) {
		select {
		case late <- batches:
		default:
		}
	})
	t.Cleanup(lateCancel)
	flush(t, s)
	replayed := 0
	for len(late) > 0 {
		replayed += len(<-late)
	}
	if replayed < len(batches) {
		t.Fatalf("late subscriber replayed %d lines, want at least %d", replayed, len(batches))
	}

	// A cancelled subscriber receives nothing more.
	cancel()
	cancel()
	action(s, "step_2")
	flush(t, s)
	if extra := collect(); len(extra) != 0 {
		t.Fatalf("a cancelled subscriber received %v", extra)
	}
}

func TestEmptyLevelSetReturnsNoRecords(t *testing.T) {
	s, _, _ := openStore(t, nil)
	action(s, "step_0")
	flush(t, s)

	if got := window(t, s, Query{Session: "current", Levels: []core.LogLevel{}}).Records; len(got) != 0 {
		t.Fatalf("an empty level set returned %d records", len(got))
	}
	if got := window(t, s, Query{Session: "current"}).Records; len(got) == 0 {
		t.Fatal("a nil level set returned no records")
	}
	if got := window(t, s, Query{Session: "current", Levels: []core.LogLevel{core.LevelInfo}}).Records; len(got) == 0 {
		t.Fatal("the INFO level returned no records")
	}
	if got := window(t, s, Query{Session: "current", Levels: []core.LogLevel{core.LevelError}}).Records; len(got) != 0 {
		t.Fatalf("the ERROR level returned %d records", len(got))
	}
}

func TestFullQueueDropsAndReportsTheLoss(t *testing.T) {
	gate := newGatedKernel()
	s, _, _ := openStore(t, func(o *Options) {
		o.Kernel = gate
		o.capacity = 6
		o.reserved = 2
	})
	// Registered after the store, so it runs before the store is closed and a failing test
	// can never leave the writer held.
	t.Cleanup(gate.free)
	flush(t, s)

	// Hold the writer inside a drain that has already taken the (empty) queue.
	gate.armed.Store(true)
	flushed := make(chan error, 1)
	go func() { flushed <- s.do(context.Background(), s.drain) }()
	select {
	case <-gate.entered:
	case <-time.After(waitLimit):
		t.Fatal("the writer never reached the kernel")
	}

	// Four INFO events fit (capacity 6 minus 2 reserved); the other six are dropped. The WARN
	// event uses the reserved room.
	for i := range 10 {
		action(s, fmt.Sprintf("step_%d", i))
	}
	s.Emit(core.LevelWarn, "editor.text.classification_failed", "", nil)
	if dropped, _ := s.Stats(); dropped != 6 {
		t.Fatalf("dropped = %d, want 6", dropped)
	}

	gate.free()
	select {
	case err := <-flushed:
		if err != nil {
			t.Fatalf("held flush: %v", err)
		}
	case <-time.After(waitLimit):
		t.Fatal("the held flush never finished")
	}
	flush(t, s)

	records := window(t, s, Query{Session: "current"}).Records
	counts := eventCounts(records)
	if counts["app.action.performed"] != 4 || counts["editor.text.classification_failed"] != 1 {
		t.Fatalf("event counts = %v", counts)
	}
	if got := fieldValues(records, "log.dropped", "count"); !slices.Equal(got, []string{"6"}) {
		t.Fatalf("log.dropped counts = %v, want [6]", got)
	}
	if dropped, _ := s.Stats(); dropped != 6 {
		t.Fatalf("dropped = %d after the flush, want 6", dropped)
	}
}

func TestChangeDirectoryMovesNewEvents(t *testing.T) {
	settingsDir := t.TempDir()
	second := t.TempDir()
	settings := store.At(settingsDir)
	s, _, first := openStore(t, func(o *Options) { o.Settings = settings })

	action(s, "stayed_there")
	if err := s.ChangeDirectory(second); err != nil {
		t.Fatalf("ChangeDirectory: %v", err)
	}
	if s.Directory() != second {
		t.Fatalf("Directory = %q, want %q", s.Directory(), second)
	}
	action(s, "moved_here")
	flush(t, s)

	before, after := readTree(t, first), readTree(t, second)
	if !strings.Contains(before, "stayed_there") || strings.Contains(before, "moved_here") {
		t.Fatalf("the old directory holds the wrong events:\n%s", before)
	}
	if !strings.Contains(after, "moved_here") || strings.Contains(after, "stayed_there") {
		t.Fatalf("the new directory holds the wrong events:\n%s", after)
	}
	// The session continues; only the directory changed.
	if _, err := os.Stat(filepath.Join(second, filepath.FromSlash(s.SessionPath()))); err != nil {
		t.Fatalf("the session directory is missing in the new directory: %v", err)
	}

	var saved directorySetting
	if found, err := settings.Load(settingsName, &saved); err != nil || !found || saved.Directory != second {
		t.Fatalf("saved setting = %+v, found %v, err %v", saved, found, err)
	}

	// A directory that cannot be created changes nothing.
	blocker := filepath.Join(first, "blocker")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.ChangeDirectory(filepath.Join(blocker, "inside")); err == nil {
		t.Fatal("ChangeDirectory into a file succeeded")
	}
	if err := s.ChangeDirectory(""); err == nil {
		t.Fatal("ChangeDirectory with an empty path succeeded")
	}
	if s.Directory() != second {
		t.Fatalf("a failed change moved the directory to %q", s.Directory())
	}

	// A later process starts in the saved directory.
	reopened, err := Open(Options{Kernel: core.NewClient(), Settings: settings, Version: "0.1.0", Now: newTestClock().Now})
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(reopened.Close)
	if reopened.Directory() != second {
		t.Fatalf("reopened Directory = %q, want %q", reopened.Directory(), second)
	}

	if err := s.RestoreDefaultDirectory(); err != nil {
		t.Fatalf("RestoreDefaultDirectory: %v", err)
	}
	if s.Directory() != first {
		t.Fatalf("Directory = %q after restoring, want %q", s.Directory(), first)
	}
	action(s, "back_home")
	flush(t, s)
	if !strings.Contains(readTree(t, first), "back_home") {
		t.Fatal("the default directory did not receive the event after restoring")
	}
	saved = directorySetting{Directory: "stale"}
	if found, err := settings.Load(settingsName, &saved); err != nil || !found || saved.Directory != "" {
		t.Fatalf("saved setting after restoring = %+v, found %v, err %v", saved, found, err)
	}
}

func TestRotationKeepsFilesUnderTheLimit(t *testing.T) {
	const limit = 1500
	s, _, dir := openStore(t, func(o *Options) { o.fileLimit = limit })
	for i := range 40 {
		action(s, fmt.Sprintf("step_%d", i))
	}
	flush(t, s)

	ctx, cancel := context.WithTimeout(context.Background(), waitLimit)
	defer cancel()
	rotated, err := s.kernel.ResolveLogChannel(ctx, "app", 1, nil)
	if err != nil {
		t.Fatalf("ResolveLogChannel: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, filepath.FromSlash(s.SessionPath()), filepath.FromSlash(rotated.RelativePath))); err != nil {
		t.Fatalf("the rotated file is missing: %v", err)
	}
	err = filepath.WalkDir(dir, func(target string, d fs.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if info.Size() > limit {
			t.Errorf("%s is %d bytes, over the %d limit", target, info.Size(), limit)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, failures := s.Stats(); failures != 0 {
		t.Fatalf("write failures = %d", failures)
	}
}

func TestDiagnosticsGateDebugEventsAndExpire(t *testing.T) {
	recorder := &recordingKernel{Kernel: core.NewClient()}
	s, clock, _ := openStore(t, func(o *Options) { o.Kernel = recorder })
	debug := func(method string) {
		s.Emit(core.LevelDebug, "app.core.request.traced", "", map[string]any{
			"duration_ms": 5, "method": method, "source": "user",
		})
	}

	if _, _, on := s.Diagnostics(); on {
		t.Fatal("diagnostics start on")
	}
	debug("while_off")
	s.ConfigureDiagnostics(true)
	_, remaining, on := s.Diagnostics()
	if !on || remaining <= 14*time.Minute || remaining > 15*time.Minute {
		t.Fatalf("Diagnostics = on %v, remaining %v", on, remaining)
	}
	debug("while_on")
	flush(t, s)
	methods := fieldValues(window(t, s, Query{Session: "current"}).Records, "app.core.request.traced", "method")
	if !slices.Contains(methods, "while_on") || slices.Contains(methods, "while_off") {
		t.Fatalf("DEBUG methods written = %v", methods)
	}

	// The window closes by itself; the next drain tells the kernel.
	clock.Advance(16 * time.Minute)
	if _, _, on := s.Diagnostics(); on {
		t.Fatal("diagnostics stayed on after the window")
	}
	debug("after_expiry")
	flush(t, s)
	methods = fieldValues(window(t, s, Query{Session: "current"}).Records, "app.core.request.traced", "method")
	if slices.Contains(methods, "after_expiry") {
		t.Fatalf("a DEBUG event was written after the window: %v", methods)
	}
	gates := recorder.states()
	if !slices.Contains(gates, true) || gates[len(gates)-1] {
		t.Fatalf("kernel gates = %v, want a true followed by a final false", gates)
	}

	s.ConfigureDiagnostics(true)
	s.ConfigureDiagnostics(false)
	if _, _, on := s.Diagnostics(); on {
		t.Fatal("diagnostics stayed on after being turned off")
	}
	if gates := recorder.states(); gates[len(gates)-1] {
		t.Fatalf("kernel gates = %v, want a final false", gates)
	}
}

func TestStartupRetentionRemovesExpiredSessionsOnly(t *testing.T) {
	dir := t.TempDir()
	const stale, recent = "2026-09-01T00-00-00_deadbeef", "2026-11-01T00-00-00_cafebabe"
	for _, name := range []string{stale, recent} {
		session := filepath.Join(dir, "sessions", name)
		if err := os.MkdirAll(session, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(session, "app.log"), []byte("{}\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	s, _, _ := openStore(t, func(o *Options) { o.Dir = dir })
	flush(t, s)

	if _, err := os.Stat(filepath.Join(dir, "sessions", stale)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the expired session survived the startup cleanup: %v", err)
	}
	for _, kept := range []string{recent, filepath.Base(s.SessionPath())} {
		if _, err := os.Stat(filepath.Join(dir, "sessions", kept)); err != nil {
			t.Fatalf("session %s was removed: %v", kept, err)
		}
	}
	if _, failures := s.Stats(); failures != 0 {
		t.Fatalf("write failures = %d", failures)
	}
}

func TestClearLogsRemovesFilesAndWritingContinues(t *testing.T) {
	s, _, dir := openStore(t, nil)
	action(s, "before_clear")
	flush(t, s)
	if s.UsedBytes() == 0 {
		t.Fatal("nothing was written before the clear")
	}

	if err := s.ClearLogs(); err != nil {
		t.Fatalf("ClearLogs: %v", err)
	}
	if files, err := inventory(dir); err != nil || len(files) != 0 {
		t.Fatalf("inventory after clearing = %d files, %v", len(files), err)
	}
	if used := s.UsedBytes(); used != 0 {
		t.Fatalf("UsedBytes = %d after clearing", used)
	}

	action(s, "after_clear")
	flush(t, s)
	text := readTree(t, dir)
	if !strings.Contains(text, "after_clear") || strings.Contains(text, "before_clear") {
		t.Fatalf("files after clearing and writing:\n%s", text)
	}
	if got := fieldValues(window(t, s, Query{Session: "current"}).Records, "app.action.performed", "action"); !slices.Equal(got, []string{"after_clear"}) {
		t.Fatalf("actions after clearing = %v", got)
	}
}

func TestCloseWritesWhatIsQueuedAndIsFinal(t *testing.T) {
	s, _, dir := openStore(t, nil)
	action(s, "last_words")
	s.Close()
	s.Close()

	s.Emit(core.LevelInfo, "app.session.started", "", nil)
	s.Flush()
	if err := s.ClearLogs(); !errors.Is(err, ErrClosed) {
		t.Fatalf("ClearLogs after Close = %v, want ErrClosed", err)
	}
	if !strings.Contains(readTree(t, dir), "last_words") {
		t.Fatal("Close did not write the queued event")
	}
	s.Subscribe(func([]Batch) {})()
}

func TestConcurrentUseIsSafe(t *testing.T) {
	s, _, _ := openStore(t, nil)
	var wg sync.WaitGroup
	for g := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range 50 {
				action(s, fmt.Sprintf("w%d_%d", g, i))
				if i%10 == 0 {
					s.Flush()
					s.Stats()
					_ = s.Directory()
					_ = s.SessionPath()
				}
			}
		}()
	}
	wg.Wait()
	flush(t, s)

	records := window(t, s, Query{Session: "current"}).Records
	if got := eventCounts(records)["app.action.performed"]; got != 400 {
		t.Fatalf("%d action events were written, want 400", got)
	}
	if dropped, failures := s.Stats(); dropped != 0 || failures != 0 {
		t.Fatalf("Stats = %d dropped, %d failures", dropped, failures)
	}
}

func TestSafePathRejectsEscapes(t *testing.T) {
	root := t.TempDir()
	for _, bad := range []string{"", "/", "/etc/passwd", "..", "a/../b", "./a", "a/./b", `a\b`, "a/\x00b"} {
		if got, err := safePath(root, bad); err == nil {
			t.Errorf("safePath(%q) = %q, want an error", bad, got)
		}
	}
	want := filepath.Join(root, "sessions", "x", "app.log")
	if got, err := safePath(root, "sessions/x/app.log"); err != nil || got != want {
		t.Errorf("safePath = %q, %v, want %q", got, err, want)
	}

	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		t.Skipf("symbolic links are unavailable: %v", err)
	}
	if got, err := safePath(root, "link/app.log"); err == nil {
		t.Errorf("safePath through a symbolic link = %q, want an error", got)
	}
}
