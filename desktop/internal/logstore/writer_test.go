package logstore

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// wakingKernel stands in for the kernel's fact queue: record queues a fact and calls the waker
// the store installed, the way the kernel does when one of its own facts is recorded.
type wakingKernel struct {
	Kernel
	mu        sync.Mutex
	wake      func()
	recovered func(core.RecoveredPanic)
	installs  int
	removals  int
	facts     []core.CoreEvent
}

func (k *wakingKernel) WatchCoreEvents(wake func(), recovered func(core.RecoveredPanic)) func() {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.wake, k.recovered = wake, recovered
	k.installs++
	return func() {
		k.mu.Lock()
		defer k.mu.Unlock()
		k.wake, k.recovered = nil, nil
		k.removals++
	}
}

// reportPanic hands a panic to the receiver the store installed, the way the client does when it
// recovers one in a callback of the kernel.
func (k *wakingKernel) reportPanic(p core.RecoveredPanic) {
	k.mu.Lock()
	recovered := k.recovered
	k.mu.Unlock()
	if recovered != nil {
		recovered(p)
	}
}

func (k *wakingKernel) record(fact core.CoreEvent) {
	k.mu.Lock()
	k.facts = append(k.facts, fact)
	wake := k.wake
	k.mu.Unlock()
	if wake != nil {
		wake()
	}
}

func (k *wakingKernel) DrainCoreEvents(ctx context.Context) (core.CoreEvents, error) {
	k.mu.Lock()
	facts := k.facts
	k.facts = nil
	k.mu.Unlock()
	drained, err := k.Kernel.DrainCoreEvents(ctx)
	drained.Events = append(facts, drained.Events...)
	return drained, err
}

func (k *wakingKernel) counts() (installs, removals int, installed bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.installs, k.removals, k.wake != nil
}

// awaitLine subscribes to the store and returns a function that waits until a written line
// contains want.
func awaitLine(t *testing.T, s *Store, want string) func() {
	t.Helper()
	seen := make(chan struct{})
	var once sync.Once
	cancel := s.Subscribe(func(batch []Batch) {
		for _, entry := range batch {
			if strings.Contains(entry.Line, want) {
				once.Do(func() { close(seen) })
			}
		}
	})
	t.Cleanup(cancel)
	return func() {
		t.Helper()
		select {
		case <-seen:
		case <-time.After(waitLimit):
			t.Fatalf("no line containing %q was written", want)
		}
	}
}

func TestCoreFactsReachTheDiskWithoutHostEvents(t *testing.T) {
	kernel := &wakingKernel{Kernel: core.NewClient()}
	s, _, _ := openStore(t, func(o *Options) { o.Kernel = kernel })
	s.ObserveCoreFacts()
	// The kernel keeps one waker per process; observing again must not replace it.
	s.ObserveCoreFacts()
	if installs, _, installed := kernel.counts(); installs != 1 || !installed {
		t.Fatalf("waker installs = %d, installed %v, want one installed waker", installs, installed)
	}
	flush(t, s)

	// Nothing but the kernel's waker schedules the drain that writes this fact.
	written := awaitLine(t, s, "app.workspace.scratch_cleanup_failed")
	kernel.record(core.CoreEvent{
		Level:   core.LevelWarn,
		Event:   "app.workspace.scratch_cleanup_failed",
		Channel: "app",
		Fields:  core.LogErrorFields(errors.New("scratch directory busy")),
	})
	written()

	s.Close()
	if _, removals, installed := kernel.counts(); removals != 1 || installed {
		t.Fatalf("waker removals = %d, installed %v after Close, want it removed once", removals, installed)
	}
	// A closed store never installs the waker again.
	s.ObserveCoreFacts()
	if installs, _, _ := kernel.counts(); installs != 1 {
		t.Fatalf("waker installs = %d after Close, want 1", installs)
	}
}

func TestRejectedEventsAreNamedWithTheirCode(t *testing.T) {
	s, _, _ := openStore(t, nil)
	flush(t, s)

	s.Emit(core.LevelInfo, "app.test.never_declared", "", nil)
	s.Emit(core.LevelError, "app.action.performed", "", map[string]any{"action": "wrong_level", "surface": "button"})
	s.Emit(core.LevelInfo, "app.action.performed", "", map[string]any{"action": "extra", "surface": "button", "extra": "x"})
	s.Emit(core.LevelInfo, "app.action.performed", "", map[string]any{"action": "extra_again", "surface": "button", "extra": "y"})
	action(s, "accepted")
	flush(t, s)

	total, recent := s.Rejections()
	if total != 4 {
		t.Fatalf("rejected = %d, want 4 (recent %+v)", total, recent)
	}
	unknown, ok := find(recent, "app.test.never_declared")
	if !ok || unknown.Code != -32053 || unknown.Count != 1 {
		t.Fatalf("unknown event rejection = %+v, found %v; recent %+v", unknown, ok, recent)
	}
	// The two rejections of app.action.performed differ by code, and the repeated one counts.
	var level, field Rejection
	for _, rejection := range recent {
		if rejection.Event != "app.action.performed" {
			continue
		}
		switch rejection.Code {
		case -32057:
			level = rejection
		case -32056:
			field = rejection
		}
	}
	if level.Count != 1 || field.Count != 2 {
		t.Fatalf("app.action.performed rejections: level %+v, field %+v; recent %+v", level, field, recent)
	}
	// A refused event is a bug of its caller, not a failed write.
	if dropped, failures := s.Stats(); dropped != 0 || failures != 0 {
		t.Fatalf("dropped = %d, write failures = %d, want 0 and 0", dropped, failures)
	}
	records := window(t, s, Query{Session: "current"}).Records
	if got := fieldValues(records, "app.action.performed", "action"); !slices.Equal(got, []string{"accepted"}) {
		t.Fatalf("written actions = %v, want only the accepted one", got)
	}

	// The window and the export see the same rejections.
	collection, err := s.QueryWindow(context.Background(), Query{Session: "current"})
	if err != nil {
		t.Fatalf("QueryWindow: %v", err)
	}
	if collection.Rejected != 4 || len(collection.Rejections) != len(recent) {
		t.Fatalf("collection rejections = %d %+v, want 4 %+v", collection.Rejected, collection.Rejections, recent)
	}
}

func find(rejections []Rejection, event string) (Rejection, bool) {
	for _, rejection := range rejections {
		if rejection.Event == event {
			return rejection, true
		}
	}
	return Rejection{}, false
}

func TestRejectionListKeepsTheLatestDistinctReasons(t *testing.T) {
	s, _, _ := openStore(t, nil)
	for i := range rejectionLimit + 5 {
		s.reject("app.test."+strconv.Itoa(i), -32055)
	}
	// Seeing the oldest kept reason again moves it to the end instead of adding a copy.
	s.reject("app.test.5", -32055)
	total, recent := s.Rejections()
	if total != rejectionLimit+6 || len(recent) != rejectionLimit {
		t.Fatalf("total = %d, kept = %d, want %d and %d", total, len(recent), rejectionLimit+6, rejectionLimit)
	}
	if recent[0].Event != "app.test.6" || recent[len(recent)-1].Event != "app.test.5" || recent[len(recent)-1].Count != 2 {
		t.Fatalf("kept rejections = %+v", recent)
	}
}

// failingEncoder fails every EncodeLogBatch call while armed, the way a kernel that cannot
// decode the request answers.
type failingEncoder struct {
	Kernel
	armed atomic.Bool
}

func (f *failingEncoder) EncodeLogBatch(ctx context.Context, batch core.LogBatch) (core.EncodedLogBatch, error) {
	if f.armed.Load() {
		return core.EncodedLogBatch{}, errors.New("encoder unavailable")
	}
	return f.Kernel.EncodeLogBatch(ctx, batch)
}

func TestUnencodableBatchIsCountedAsDropped(t *testing.T) {
	encoder := &failingEncoder{Kernel: core.NewClient()}
	s, _, _ := openStore(t, func(o *Options) { o.Kernel = encoder })
	flush(t, s)

	encoder.armed.Store(true)
	for _, name := range []string{"lost_1", "lost_2", "lost_3"} {
		action(s, name)
	}
	flush(t, s)
	if dropped, failures := s.Stats(); dropped != 3 || failures != 0 {
		t.Fatalf("dropped = %d, write failures = %d, want 3 and 0", dropped, failures)
	}
	// The report of the loss is lost too while the encoder fails; it is carried, not counted
	// as one more lost event.
	flush(t, s)
	if dropped, _ := s.Stats(); dropped != 3 {
		t.Fatalf("dropped = %d after a lost report, want 3", dropped)
	}

	encoder.armed.Store(false)
	flush(t, s)
	records := window(t, s, Query{Session: "current"}).Records
	if got := fieldValues(records, "log.dropped", "count"); !slices.Equal(got, []string{"3"}) {
		t.Fatalf("log.dropped counts = %v, want [3]", got)
	}
	if got := fieldValues(records, "app.action.performed", "action"); len(got) != 0 {
		t.Fatalf("lost actions were written: %v", got)
	}
}

// gateKernel reports every DEBUG gate the store pushes to the kernel on a channel.
type gateKernel struct {
	Kernel
	gates chan bool
}

func (g *gateKernel) ConfigureCoreEvents(ctx context.Context, debug bool, roots []string) error {
	select {
	case g.gates <- debug:
	default:
	}
	return g.Kernel.ConfigureCoreEvents(ctx, debug, roots)
}

func TestDiagnosticsExpireWithoutHostEvents(t *testing.T) {
	kernel := &gateKernel{Kernel: core.NewClient(), gates: make(chan bool, 64)}
	s, clock, _ := openStore(t, func(o *Options) {
		o.Kernel = kernel
		o.diagnosticWindow = 20 * time.Millisecond
	})
	flush(t, s)
	// The first drain told the kernel the gate is closed; only what follows matters.
	for len(kernel.gates) > 0 {
		<-kernel.gates
	}

	s.ConfigureDiagnostics(true)
	// Past the window on the store's clock; only the writer's expiry timer can now notice.
	clock.Advance(time.Minute)
	opened := false
	deadline := time.After(waitLimit)
	for {
		select {
		case on := <-kernel.gates:
			if on {
				opened = true
				continue
			}
			if !opened {
				t.Fatal("the kernel gate closed before it was opened")
			}
			if _, _, on := s.Diagnostics(); on {
				t.Fatal("diagnostics are on after the kernel gate closed")
			}
			return
		case <-deadline:
			t.Fatal("the kernel's DEBUG gate stayed open after the window expired")
		}
	}
}

// refusingKernel fails the DEBUG gate push.
type refusingKernel struct{ Kernel }

func (refusingKernel) ConfigureCoreEvents(context.Context, bool, []string) error {
	return errors.New("gate unavailable")
}

func TestFailedGatePushIsLoggedOnce(t *testing.T) {
	s, _, _ := openStore(t, func(o *Options) { o.Kernel = refusingKernel{Kernel: core.NewClient()} })
	flush(t, s)
	flush(t, s)
	records := window(t, s, Query{Session: "current"}).Records
	if counts := eventCounts(records); counts["app.logging.diagnostics_failed"] != 1 {
		t.Fatalf("event counts = %v, want one app.logging.diagnostics_failed", counts)
	}
}

func TestFailedDirectoryFallsBackAndIsLogged(t *testing.T) {
	s, _, first := openStore(t, nil)
	flush(t, s)
	second := filepath.Join(t.TempDir(), "logs")
	if err := s.ChangeDirectory(second); err != nil {
		t.Fatalf("ChangeDirectory: %v", err)
	}
	// The chosen directory disappears before anything is written there.
	if err := os.RemoveAll(second); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	action(s, "after_the_loss")
	flush(t, s)

	if s.Directory() != first {
		t.Fatalf("Directory = %q, want the default %q", s.Directory(), first)
	}
	records := window(t, s, Query{Session: "current"}).Records
	// The kernel redacts the directory; one record names the failed one, with its error.
	if got := fieldValues(records, "app.logging.redirect_failed", "directory"); len(got) != 1 || got[0] == "" {
		t.Fatalf("redirect_failed directories = %v, want one", got)
	}
	if got := fieldValues(records, "app.logging.redirect_failed", "error_domain"); len(got) != 1 || got[0] == "" {
		t.Fatalf("redirect_failed error domains = %v, want one", got)
	}
	if got := fieldValues(records, "app.action.performed", "action"); !slices.Contains(got, "after_the_loss") {
		t.Fatalf("the event that hit the failed directory was not retried: %v", got)
	}
}

func TestUnreadableDirectorySettingIsReported(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsName), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	directory, err := loadDirectory(store.At(dir))
	if directory != "" || err == nil {
		t.Fatalf("loadDirectory = %q, %v, want no directory and an error", directory, err)
	}
	// A directory a newer version stored in another shape is no directory either, and Open
	// records why the default is used.
	if err := os.WriteFile(filepath.Join(dir, settingsName), []byte(`{"directory":{"path":"/logs"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if directory, err := loadDirectory(store.At(dir)); directory != "" || err == nil {
		t.Fatalf("loadDirectory of another shape = %q, %v, want no directory and an error", directory, err)
	}
	if directory, err := loadDirectory(nil); directory != "" || err != nil {
		t.Fatalf("loadDirectory(nil) = %q, %v", directory, err)
	}
}
