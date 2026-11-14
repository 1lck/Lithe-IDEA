package workbench

import (
	"context"
	"errors"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
)

// The window asks its log sink for a plugin's ${logDir} by a type assertion, which would
// silently give every plugin process no log directory if the store stopped implementing it.
var _ pluginFileSink = (*logstore.Store)(nil)

// pluginFilesLog is a log sink that also gives plugin file directories.
type pluginFilesLog struct {
	opRecordingLog
	directory string
	err       error
	asked     []string
}

func (l *pluginFilesLog) PluginFilesDirectory(_ context.Context, pluginID string) (string, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.asked = append(l.asked, pluginID)
	return l.directory, l.err
}

// TestPluginLogDirectoryComesFromTheLogStore checks that a plugin process's ${logDir} is the
// directory the log store gives for the plugin, that a store that cannot make it leaves the
// process without one and records the failure as background work under the action, and that
// a window without a log store gives none.
func TestPluginLogDirectoryComesFromTheLogStore(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	a := h.app
	t.Cleanup(func() { a.logSink = nil })
	ctx := core.WithOrigin(context.Background(), core.Origin{Operation: "op-1", Trigger: "test.action"})

	log := &pluginFilesLog{directory: "/logs/sessions/s/plugins/io.example.plugin/files"}
	a.logSink = log
	if got := a.pluginLogDirectory(ctx, "io.example.plugin"); got != log.directory {
		t.Fatalf("pluginLogDirectory = %q, want %q", got, log.directory)
	}
	if len(log.asked) != 1 || log.asked[0] != "io.example.plugin" {
		t.Fatalf("the store was asked for %q, want the plugin's own directory", log.asked)
	}
	if got := log.ops(backgroundFailedEvent); len(got) != 0 {
		t.Fatalf("a directory the store made recorded a failure under %q", got)
	}

	failing := &pluginFilesLog{err: errors.New("disk full")}
	a.logSink = failing
	if got := a.pluginLogDirectory(ctx, "io.example.plugin"); got != "" {
		t.Fatalf("pluginLogDirectory = %q after the store failed, want none", got)
	}
	if got := failing.ops(backgroundFailedEvent); len(got) != 1 || got[0] != "op-1" {
		t.Fatalf("the failure was recorded under %q, want once under op-1", got)
	}

	a.logSink = &opRecordingLog{}
	if got := a.pluginLogDirectory(ctx, "io.example.plugin"); got != "" {
		t.Fatalf("pluginLogDirectory = %q from a sink that gives no plugin directories", got)
	}
	a.logSink = nil
	if got := a.pluginLogDirectory(ctx, "io.example.plugin"); got != "" {
		t.Fatalf("pluginLogDirectory = %q without a log store", got)
	}
}
