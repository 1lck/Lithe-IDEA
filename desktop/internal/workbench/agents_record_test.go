package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// recordCore answers agentSessions.read the way Core does for a session file made of lines of
// the given lengths, each holding one message "line N": a range that ends inside a line stops
// at the line before it, and one inside a single line answers its own start.
type recordCore struct {
	mu       sync.Mutex
	lines    []uint64
	changed  bool
	sessions []agents.RecordedSession
	reads    []agents.ByteRange
	// text is the message text of line i; nil answers "line i".
	text func(int) string
}

func (f *recordCore) size() uint64 {
	var size uint64
	for _, length := range f.lines {
		size += length
	}
	return size
}

func (f *recordCore) Execute(_ context.Context, command string, params, result any) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	var answer any
	switch command {
	case "agentSessions.list":
		answer = map[string]any{"sessions": f.sessions}
	case "agentSessions.read":
		span := params.(map[string]any)["range"].(agents.ByteRange)
		f.reads = append(f.reads, span)
		if span.Start >= span.End || span.End > f.size() || span.End-span.Start > agentRecordMaxPage {
			return errors.New("range outside what the cache read")
		}
		if f.changed {
			answer = agents.ReadResult{Changed: true, Messages: []agents.RecordedMessage{}}
			break
		}
		read := agents.ReadResult{End: span.Start, Messages: []agents.RecordedMessage{}}
		var at uint64
		for i, length := range f.lines {
			lineEnd := at + length
			if at >= span.Start && lineEnd <= span.End {
				text := "line " + strconv.Itoa(i)
				if f.text != nil {
					text = f.text(i)
				}
				read.Messages = append(read.Messages, agents.RecordedMessage{Role: "assistant", Text: text})
				read.End = lineEnd
			}
			at = lineEnd
		}
		answer = read
	default:
		answer = map[string]any{}
	}
	data, err := json.Marshal(answer)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, result)
}

func messageTexts(messages []agents.RecordedMessage) []string {
	texts := make([]string, len(messages))
	for i, message := range messages {
		texts[i] = message.Text
	}
	return texts
}

// Pages end on whole lines, and the next page starts where the last one stopped.
func TestReadRecordPagesEndOnWholeLines(t *testing.T) {
	fake := &recordCore{lines: []uint64{100 << 10, 100 << 10, 100 << 10, 100 << 10}}
	kernel := agents.NewClient(fake)

	first := readRecordPages(context.Background(), kernel, "dev.lithe.test.agent/sample", "/s.jsonl", 0, fake.size())
	if first.err != nil || len(first.messages) != 2 || first.next != 200<<10 {
		t.Fatalf("first load = %v messages, next %d, err %v; want lines 0–1 and the next page at 200 KiB",
			messageTexts(first.messages), first.next, first.err)
	}
	second := readRecordPages(context.Background(), kernel, "dev.lithe.test.agent/sample", "/s.jsonl", first.next, fake.size())
	if got := messageTexts(second.messages); len(got) != 2 || got[0] != "line 2" || second.next != fake.size() {
		t.Fatalf("second load = %v, next %d; want lines 2–3 up to the end", got, second.next)
	}
}

// A line longer than a page is read with a page four times larger, until it fits.
func TestReadRecordPagesGrowsThePageForALongLine(t *testing.T) {
	fake := &recordCore{lines: []uint64{3 << 20, 2 << 20}}
	kernel := agents.NewClient(fake)

	pages := readRecordPages(context.Background(), kernel, "dev.lithe.test.agent/sample", "/s.jsonl", 0, fake.size())
	if pages.err != nil || pages.tooLong || len(pages.messages) != 1 || pages.next != 3<<20 {
		t.Fatalf("load = %v, next %d, tooLong %v, err %v; want the long line whole", messageTexts(pages.messages), pages.next, pages.tooLong, pages.err)
	}
	want := []uint64{agentRecordPage, agentRecordPage * 4, agentRecordPage * 16}
	if len(fake.reads) != len(want) {
		t.Fatalf("reads = %v, want pages of %v bytes", fake.reads, want)
	}
	for i, span := range fake.reads {
		if span.End-span.Start != want[i] {
			t.Fatalf("read %d spans %d bytes, want %d", i, span.End-span.Start, want[i])
		}
	}
}

// A line longer than the largest page Core reads stops the viewer there.
func TestReadRecordPagesStopsAtALineCoreCannotRead(t *testing.T) {
	fake := &recordCore{lines: []uint64{20 << 20, 10}}
	pages := readRecordPages(context.Background(), agents.NewClient(fake), "dev.lithe.test.agent/sample", "/s.jsonl", 0, fake.size())
	if !pages.tooLong || len(pages.messages) != 0 || pages.next != 0 || pages.err != nil {
		t.Fatalf("load = %v, next %d, tooLong %v, err %v; want it stopped before the line", messageTexts(pages.messages), pages.next, pages.tooLong, pages.err)
	}
}

// A file that changed since the cache read it stops the viewer and says so.
func TestReadRecordPagesReportsAChangedFile(t *testing.T) {
	fake := &recordCore{lines: []uint64{10, 10}, changed: true}
	pages := readRecordPages(context.Background(), agents.NewClient(fake), "dev.lithe.test.agent/sample", "/s.jsonl", 0, fake.size())
	if !pages.changed || len(pages.messages) != 0 {
		t.Fatalf("load = changed %v, %v; want changed and no messages", pages.changed, messageTexts(pages.messages))
	}
}

// showAgentHistory opens the History tab of an English window listing sessions, with Core
// answering reads from fake.
func showAgentHistory(t *testing.T, fake *recordCore) *harness {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(dir), Languages: []string{"en-US"},
		AgentKernel: agents.NewClient(fake),
	})
	h.open(t.TempDir())
	v := &h.app.agentsView
	v.catalog = []agents.CatalogAgent{{PluginID: "dev.lithe.test.agent", AgentID: "sample", DisplayName: "Sample",
		Forms: []string{"conversation"}, MayRun: true, ReadsSessions: true, MayReadSessions: true}}
	v.configured = true
	v.tab = agentsTabHistory
	v.history.loaded = true
	v.history.sessions = fake.sessions
	h.click(center(h.button(itemAgents)))
	h.settle()
	return h
}

// View opens a recorded session's first page; Load More reads the next one, and the way back
// returns to the list.
func TestAgentHistoryViewPagesThroughASession(t *testing.T) {
	fake := &recordCore{lines: []uint64{200 << 10, 200 << 10, 200 << 10}}
	fake.sessions = []agents.RecordedSession{{
		Agent: "dev.lithe.test.agent/sample", SessionID: "s1", Path: "/s1.jsonl", ReadBytes: fake.size(),
		PluginID: "dev.lithe.test.agent", AgentID: "sample", Title: "Fix the cart total",
	}}
	h := showAgentHistory(t, fake)

	h.click(center(h.hitLabeled("View")))
	h.settleUntil("the first page", func() bool { return h.shows("line 0") })
	if h.shows("line 1") {
		t.Fatal("the first page showed more than its whole lines")
	}
	h.click(center(h.hitLabeled("Load More")))
	h.settleUntil("the second page", func() bool { return h.shows("line 1") })
	h.click(center(h.hitLabeled("Load More")))
	h.settleUntil("the last page", func() bool { return h.shows("line 2") })
	if h.shows("Load More") {
		t.Fatal("Load More is still offered after the last page")
	}
	h.click(center(h.hitLabeled("Back to History")))
	h.settle()
	if h.app.agentsView.history.record != nil || !h.shows("Fix the cart total") {
		t.Fatal("the way back did not return to the session list")
	}
}

// A search hit opens its session at the hit, and View from the Start reads it from the top.
func TestAgentHistoryHitOpensAtTheHit(t *testing.T) {
	fake := &recordCore{lines: []uint64{10, 10, 10}}
	fake.sessions = []agents.RecordedSession{{
		Agent: "dev.lithe.test.agent/sample", SessionID: "s1", Path: "/s1.jsonl", ReadBytes: fake.size(),
		PluginID: "dev.lithe.test.agent", AgentID: "sample", Title: "Fix the cart total",
	}}
	h := showAgentHistory(t, fake)
	h.app.agentsView.history.searched = true
	h.app.agentsView.history.hits = []agents.SearchHit{{
		Agent: "dev.lithe.test.agent/sample", Path: "/s1.jsonl", SessionID: "s1", Range: agents.ByteRange{Start: 20, End: 30},
		PluginID: "dev.lithe.test.agent", AgentID: "sample",
	}}
	h.settle()

	h.click(center(h.hitLabeled("View")))
	h.settleUntil("the hit's page", func() bool { return h.shows("line 2") })
	if h.shows("line 0") || !h.shows("Fix the cart total") {
		t.Fatal("the hit did not open its session at the hit, under the session's title")
	}
	h.click(center(h.hitLabeled("View from the Start")))
	h.settleUntil("the session from its start", func() bool { return h.shows("line 0") })
}
