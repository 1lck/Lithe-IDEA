package workbench

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// The window finds the detailed-diagnostics switch by a type assertion on its log sink, which
// would silently leave every plugin session's trace off if the store stopped implementing it.
var _ diagnosticsWatchSink = (*logstore.Store)(nil)

// diagnosticsWatchLog is a log sink that counts who watches its diagnostics switch.
type diagnosticsWatchLog struct {
	opRecordingLog
	watchMu  sync.Mutex
	watching int
}

func (l *diagnosticsWatchLog) WatchDiagnostics(watch func(on bool)) func() {
	l.watchMu.Lock()
	l.watching++
	l.watchMu.Unlock()
	watch(false)
	var once sync.Once
	return func() {
		once.Do(func() {
			l.watchMu.Lock()
			l.watching--
			l.watchMu.Unlock()
		})
	}
}

func (l *diagnosticsWatchLog) watchers() int {
	l.watchMu.Lock()
	defer l.watchMu.Unlock()
	return l.watching
}

// TestPluginSessionsFollowTheDiagnosticsSwitch checks that a workbench with plugins watches the
// log's diagnostics switch once, even when it is wired again, that it stops watching when it is
// done with its sessions, that a window without plugins or without such a log watches nothing,
// and that a refused trace switch is recorded as a diagnostics failure under no action.
func TestPluginSessionsFollowTheDiagnosticsSwitch(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel:       &testKernel{Client: core.NewClient()},
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   t.TempDir(),
		Store:        store.At(dir),
		Languages:    []string{"en"},
	})
	a := h.app
	if a.plugins == nil {
		t.Fatal("the workbench opened without plugins")
	}
	t.Cleanup(func() {
		a.stopWatchingDiagnostics()
		a.logSink = nil
	})

	log := &diagnosticsWatchLog{}
	a.logSink = log
	a.watchDiagnostics()
	a.watchDiagnostics()
	if got := log.watchers(); got != 1 {
		t.Fatalf("wiring the switch twice left %d watchers, want one", got)
	}
	a.stopWatchingDiagnostics()
	a.stopWatchingDiagnostics()
	if got := log.watchers(); got != 0 {
		t.Fatalf("a workbench done with its sessions still has %d watchers", got)
	}

	a.logSink = &opRecordingLog{}
	a.watchDiagnostics()
	if a.unwatchDiagnostics != nil {
		t.Fatal("a log without a diagnostics switch was watched")
	}

	a.logSink = log
	service := a.plugins
	a.plugins = nil
	a.watchDiagnostics()
	a.plugins = service
	if got := log.watchers(); got != 0 {
		t.Fatalf("a workbench without plugins watches the switch %d times", got)
	}

	a.traceFailed(errors.New("lithe core: lsp.setDetailedDiagnostics: refused (unknown)"))
	if got := log.ops("app.logging.diagnostics_failed"); len(got) != 1 || got[0] != "" {
		t.Fatalf("a refused trace switch was recorded under %q, want once under no action", got)
	}
}
