package logwindow

import (
	"context"
	"slices"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// termKernel writes a composed term the way the kernel does for an empty expression and
// records what it was asked to compose.
type termKernel struct {
	*exportKernel

	mu    sync.Mutex
	asked []string
}

func (k *termKernel) ComposeLogFilter(_ context.Context, expression string, term core.LogFilterTerm) (string, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.asked = append(k.asked, expression)
	return term.Kind + ":" + term.Value, nil
}

func TestShowOperationNarrowsToTheOperationOfThisSession(t *testing.T) {
	fixture := newExportFixture(t)
	kernel := &termKernel{exportKernel: fixture.kernel}
	m := fixture.model
	m.opts.Kernel = kernel
	m.prefs.Query.Session = sessionPrevious
	m.prefs.Query.Since, m.prefs.Query.Until = formatInstant(1), formatInstant(2)
	m.prefs.Query.ChannelPrefixes = []string{"git"}
	m.prefs.Query.Levels = []core.LogLevel{core.LevelError}
	m.prefs.Query.Expression = "level:error"
	m.follows = true

	m.showOperation("action-7")
	settle(t, m)

	q := m.prefs.Query
	if q.Session != sessionCurrent || q.Since != "" || q.Until != "" {
		t.Fatalf("session %q, range %q..%q; want the current session without a limit", q.Session, q.Since, q.Until)
	}
	if len(q.ChannelPrefixes) != 0 {
		t.Fatalf("channels %v; want every channel", q.ChannelPrefixes)
	}
	if !slices.Equal(q.Levels, allLevels) {
		t.Fatalf("levels %v; want %v", q.Levels, allLevels)
	}
	if q.Expression != "op:action-7" {
		t.Fatalf("expression %q; want the op term alone", q.Expression)
	}
	kernel.mu.Lock()
	asked := slices.Clone(kernel.asked)
	kernel.mu.Unlock()
	if !slices.Equal(asked, []string{""}) {
		t.Fatalf("composed into %q; want the term composed into an empty expression", asked)
	}
	if m.follows {
		t.Fatal("the table still follows new records after narrowing to an operation")
	}
	if m.expressionRevision == 0 {
		t.Fatal("the filter field was not told the expression changed")
	}
}
