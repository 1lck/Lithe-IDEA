package workbench

import (
	"context"
	"slices"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// cappedHistoryKernel reads the history as gitKernel does but says every walk stopped at its
// limit while the history goes on, and records the most commits each page asked Core to read.
type cappedHistoryKernel struct {
	gitKernel
	mu  sync.Mutex
	max []int
}

func (k *cappedHistoryKernel) GitHistoryPage(ctx context.Context, root, reference, cursor string, limit, maxCommits int) (core.GitHistoryPage, error) {
	k.mu.Lock()
	k.max = append(k.max, maxCommits)
	k.mu.Unlock()
	page, err := k.gitKernel.GitHistoryPage(ctx, root, reference, cursor, limit, maxCommits)
	page.HasMore, page.NextCursor, page.LimitReached = false, "", true
	return page, err
}

// asked is the most commits each page so far asked Core to read.
func (k *cappedHistoryKernel) asked() []int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return slices.Clone(k.max)
}

// The log of one repository asks Core to read as many commits as the Git Log settings let it.
// When the history goes on past them, the list ends in a note that older commits are beyond the
// read limit and a button that opens those settings, never a failure and a retry. A changed limit
// is stored, the default as zero, and reads the log again with the new one.
func TestLogEndsAtItsLimitWithANoteThatOpensTheSettings(t *testing.T) {
	dir := newTestRepository(t)
	gitRun(t, dir, "commit", "-am", "second")
	k := &cappedHistoryKernel{gitKernel: gitKernel{core.NewClient()}}
	h := newHarness(t, k)
	h.app.settings.GitLogLimit = 2000
	p := h.openLog(t, dir)
	if got := k.asked(); len(got) == 0 || got[0] != 2000 {
		t.Fatalf("the first page asked Core for at most %v commits, want 2000", got)
	}
	if !p.log.limitReached || p.log.hasMore {
		t.Fatalf("the log says limit reached %v, more %v; want the limit note and no more", p.log.limitReached, p.log.hasMore)
	}
	g := h.app.text.Git
	if !h.shows(g.LimitReached(2)) || h.shows(g.LoadMoreFailed) || h.shows(g.Retry) {
		t.Fatalf("the end of the log does not say %q alone", g.LimitReached(2))
	}

	log := &treeRecordingLog{}
	h.app.logSink = log
	t.Cleanup(func() { h.app.logSink = nil })
	h.clickNamed(g.AdjustLimit)
	h.settle()
	if n := countPerformed(log, "settings.open"); n != 1 {
		t.Fatalf("%q opened the settings %d times, want once", g.AdjustLimit, n)
	}

	h.app.setGitLogLimits(10000, settingswindow.DefaultGitLogMergedLimit)
	h.settleUntil("the log read again", func() bool {
		got := k.asked()
		return !p.log.loading && got[len(got)-1] == 10000
	})
	if h.app.settings.GitLogLimit != 10000 || h.app.settings.GitLogMergedLimit != 0 {
		t.Fatalf("stored limits %d and %d, want 10000 and the default as zero", h.app.settings.GitLogLimit, h.app.settings.GitLogMergedLimit)
	}
	h.app.setGitLogLimits(settingswindow.DefaultGitLogLimit, 30000)
	h.settle()
	if h.app.settings.GitLogLimit != 0 || h.app.settings.GitLogMergedLimit != 30000 {
		t.Fatalf("stored limits %d and %d, want the default as zero and 30000", h.app.settings.GitLogLimit, h.app.settings.GitLogMergedLimit)
	}
	if got := k.asked(); got[len(got)-1] != settingswindow.DefaultGitLogLimit {
		t.Fatalf("the log of one repository read again with %d, want the default %d", got[len(got)-1], settingswindow.DefaultGitLogLimit)
	}
}
