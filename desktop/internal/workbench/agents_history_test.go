package workbench

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// runeMeasure measures text one unit per character, so a test knows where a line breaks.
type runeMeasure struct{}

func (runeMeasure) TextWidthWeight(value string, _, _ float32) float32 {
	return float32(utf8.RuneCountInString(value))
}

func (runeMeasure) TextOffsetAt(value string, _, _, x float32) int {
	width := float32(0)
	for offset := range value {
		if width+1 > x {
			return offset
		}
		width++
	}
	return len(value)
}

// A preview's first line breaks after the last whole word that fits, and anywhere in a script
// that does not space its words.
func TestAgentPreviewLinesBreakBetweenWords(t *testing.T) {
	for _, test := range []struct {
		name                string
		text                string
		prefix, width       float32
		wantFirst, wantRest string
	}{
		{"fits", "short", 2, 40, "short", ""},
		{"at a space", "alpha beta gamma", 2, 12, "alpha beta", "gamma"},
		{"inside a word", "alpha beta gamma", 2, 10, "alpha", "beta gamma"},
		{"one long word", "abcdefghijkl", 0, 5, "abcde", "fghijkl"},
		{"chinese", "中文预览很长的文字", 0, 4, "中文预览", "很长的文字"},
		{"no room", "alpha", 10, 8, "", "alpha"},
	} {
		first, rest := agentPreviewLines(runeMeasure{}, test.prefix, test.width, test.text, 12)
		if first != test.wantFirst || rest != test.wantRest {
			t.Errorf("%s: got %q / %q, want %q / %q", test.name, first, rest, test.wantFirst, test.wantRest)
		}
	}
}

// A preview is one line of text with its white space folded, its control characters dropped and
// its length bounded.
func TestAgentPreviewTextFoldsWhiteSpace(t *testing.T) {
	if got := previewText("  hello\n\n  world\t!  "); got != "hello world !" {
		t.Fatalf("folded = %q", got)
	}
	if got := previewText("a\x00b\x1bc"); got != "abc" {
		t.Fatalf("control characters kept: %q", got)
	}
	if got := previewText(strings.Repeat("字", agentPreviewChars+50)); utf8.RuneCountInString(got) != agentPreviewChars {
		t.Fatalf("kept %d characters, want %d", utf8.RuneCountInString(got), agentPreviewChars)
	}
	messages := []agents.RecordedMessage{{Role: "user", Text: "first"}, {Role: "assistant", Text: "answer"}, {Role: "tool", Text: " \n "}}
	if got := previewOf(messages); got.role != "assistant" || got.text != "answer" {
		t.Fatalf("previewOf = %+v, want the last message with words", got)
	}
}

// Sessions are grouped under their directories in the order each directory first appears; a
// collapsed directory keeps only its heading, and a list with pages left ends in the row that
// reads the next one.
func TestAgentHistoryRowsGroupByDirectory(t *testing.T) {
	h := agentHistory{total: 5, sessions: []agents.RecordedSession{
		{Agent: "a", SessionID: "1", Cwd: "/w/one"},
		{Agent: "a", SessionID: "2", Cwd: "/w/two"},
		{Agent: "b", SessionID: "3", Cwd: "/w/one"},
	}}
	h.rebuildRows()
	want := []agentHistoryRow{
		{kind: agentRowGroup, cwd: "/w/one", count: 2},
		{kind: agentRowSession, cwd: "/w/one", session: 0},
		{kind: agentRowSession, cwd: "/w/one", session: 2},
		{kind: agentRowGroup, cwd: "/w/two", count: 1},
		{kind: agentRowSession, cwd: "/w/two", session: 1},
		{kind: agentRowMore},
	}
	if !reflect.DeepEqual(h.rows, want) {
		t.Fatalf("rows = %+v\nwant %+v", h.rows, want)
	}

	h.toggleGroup("/w/one")
	if len(h.rows) != 4 || h.rows[0].kind != agentRowGroup || h.rows[1].cwd != "/w/two" {
		t.Fatalf("collapsed rows = %+v", h.rows)
	}
	h.toggleGroup("/w/one")
	if len(h.rows) != 6 {
		t.Fatalf("expanded again: %d rows", len(h.rows))
	}

	h.groupCounts = map[string]uint64{"/w/one": 163}
	if got := h.groupCount(h.rows[0]); got != 163 {
		t.Fatalf("list heading counts %d, want Core's 163", got)
	}
	h.searched = "x"
	h.rebuildRows()
	if last := h.rows[len(h.rows)-1]; last.kind == agentRowMore {
		t.Fatal("search results end in a row that reads more")
	}
	if got := h.groupCount(h.rows[0]); got != 2 {
		t.Fatalf("search heading counts %d, want its 2 results", got)
	}
}

// Search results are ordered by their newest match unless the user orders them by the sessions'
// activity or start.
func TestAgentHistorySortSearch(t *testing.T) {
	sessions := []agents.RecordedSession{
		{Agent: "a", SessionID: "1", UpdatedAtMs: 30, StartedAtMs: 1},
		{Agent: "a", SessionID: "2", UpdatedAtMs: 10, StartedAtMs: 3},
		{Agent: "a", SessionID: "3", UpdatedAtMs: 20, StartedAtMs: 2},
	}
	h := agentHistory{searched: "q", hits: map[string]agents.SearchHit{
		agentSessionKey("a", "1"): {AtMs: 5},
		agentSessionKey("a", "2"): {AtMs: 9},
		agentSessionKey("a", "3"): {AtMs: 7},
	}}
	order := func() string {
		var ids []string
		for _, session := range h.sessions {
			ids = append(ids, session.SessionID)
		}
		return strings.Join(ids, ",")
	}
	for _, test := range []struct {
		order agentHistoryOrder
		want  string
	}{{agentOrderLatest, "2,3,1"}, {agentOrderUpdated, "1,3,2"}, {agentOrderStarted, "2,3,1"}} {
		h.sessions = append([]agents.RecordedSession(nil), sessions...)
		h.searchOrder = test.order
		h.sortSearch()
		if got := order(); got != test.want {
			t.Errorf("order %d: %s, want %s", test.order, got, test.want)
		}
	}
}

// A further page adds only the sessions the loaded ones lack.
func TestAgentHistoryAppendNewSessions(t *testing.T) {
	loaded := []agents.RecordedSession{{Agent: "a", SessionID: "1"}, {Agent: "a", SessionID: "2"}}
	page := []agents.RecordedSession{{Agent: "a", SessionID: "2"}, {Agent: "b", SessionID: "2"}, {Agent: "a", SessionID: "3"}, {Agent: "a", SessionID: "3"}}
	got := appendNewSessions(loaded, page)
	var keys []string
	for _, session := range got {
		keys = append(keys, session.Agent+session.SessionID)
	}
	if strings.Join(keys, ",") != "a1,a2,b2,a3" {
		t.Fatalf("sessions = %v", keys)
	}
}

// A scope names each directory once and leaves out those under another, and a session's directory
// is in it by whole path components.
func TestAgentHistoryScopeDirectories(t *testing.T) {
	got := scopeDirectories([]string{"/w/repo/sub", "/w/repo", "", "/w/repo/", "/w/other"})
	if !reflect.DeepEqual(got, []string{filepath.FromSlash("/w/repo"), filepath.FromSlash("/w/other")}) {
		t.Fatalf("scope = %v", got)
	}
	for _, test := range []struct {
		cwd  string
		dirs []string
		want bool
	}{
		{"/w/repo", []string{"/w/repo"}, true},
		{"/w/repo/a/b", []string{"/w/repo/"}, true},
		{"/w/repository", []string{"/w/repo"}, false},
		{"", []string{"/w/repo"}, false},
		{"/anything", []string{"/"}, true},
		{`C:\w\repo\x`, []string{`C:\w\repo`}, true},
	} {
		if got := underAny(test.cwd, test.dirs); got != test.want {
			t.Errorf("underAny(%q, %v) = %v, want %v", test.cwd, test.dirs, got, test.want)
		}
	}
}

// The preview cache reads each span once, the rows wanted last first, and keeps a bounded number.
func TestAgentPreviewsQueueAndCache(t *testing.T) {
	var previews agentPreviews
	key := func(n int) agentPreviewKey {
		return agentPreviewKey{agent: "a", path: "p", start: uint64(n), end: uint64(n + 1)}
	}
	for n := range agentPreviewQueue + 5 {
		previews.want(key(n))
	}
	previews.want(key(agentPreviewQueue + 4))
	if len(previews.queue) != agentPreviewQueue || previews.queue[0] != key(5) {
		t.Fatalf("queue kept %d from %+v, want the latest %d", len(previews.queue), previews.queue[0], agentPreviewQueue)
	}
	batch := previews.take()
	if len(batch) != agentPreviewBatch || batch[0] != key(agentPreviewQueue+4) {
		t.Fatalf("batch of %d starts at %+v, want the latest wanted first", len(batch), batch[0])
	}

	previews.store(key(0), agentPreview{text: "kept"})
	previews.want(key(0))
	if previews.queue[len(previews.queue)-1] == key(0) {
		t.Fatal("a read preview was queued again")
	}
	for n := 1; n <= agentPreviewCache; n++ {
		previews.store(key(n), agentPreview{})
	}
	if _, ok := previews.lookup(key(0)); ok || len(previews.done) != agentPreviewCache {
		t.Fatalf("cache holds %d and still the oldest: %v", len(previews.done), ok)
	}

	previews.forget(func(k agentPreviewKey) bool { return k.start%2 == 0 })
	for k := range previews.done {
		if k.start%2 == 0 {
			t.Fatalf("forgotten preview %+v kept", k)
		}
	}
}

// A row previews its session's last message, or the hit while a search lists it.
func TestAgentHistoryPreviewKey(t *testing.T) {
	session := agents.RecordedSession{Agent: "a", SessionID: "1", Path: "/s.jsonl", LastMessageRange: &agents.ByteRange{Start: 40, End: 90}}
	h := agentHistory{hits: map[string]agents.SearchHit{agentSessionKey("a", "1"): {Agent: "a", Path: "/s.jsonl", Range: agents.ByteRange{Start: 5, End: 9}}}}
	if got, ok := h.previewKeyOf(session); !ok || got.start != 40 || got.end != 90 {
		t.Fatalf("list key = %+v %v", got, ok)
	}
	h.searched = "q"
	if got, ok := h.previewKeyOf(session); !ok || got.start != 5 || got.end != 9 {
		t.Fatalf("search key = %+v %v", got, ok)
	}
	if _, ok := (&agentHistory{}).previewKeyOf(agents.RecordedSession{Agent: "a", SessionID: "2"}); ok {
		t.Fatal("a session with no message has a preview")
	}
}

// Times read as how long ago, in the user's language, and as a date after a month.
func TestAgentRelativeTime(t *testing.T) {
	now := time.Date(2026, 11, 28, 12, 0, 0, 0, time.UTC)
	for _, test := range []struct {
		lang i18n.Language
		ago  time.Duration
		want string
	}{
		{i18n.English, 30 * time.Second, "Just now"},
		{i18n.English, time.Minute, "1 minute ago"},
		{i18n.English, 5 * time.Minute, "5 minutes ago"},
		{i18n.English, 90 * time.Minute, "1 hour ago"},
		{i18n.English, 3 * time.Hour, "3 hours ago"},
		{i18n.English, 49 * time.Hour, "2 days ago"},
		{i18n.Chinese, 30 * time.Second, "刚刚"},
		{i18n.Chinese, 90 * time.Minute, "1 小时前"},
	} {
		if got := agentRelativeTime(test.lang, now, now.Add(-test.ago)); got != test.want {
			t.Errorf("%v ago: %q, want %q", test.ago, got, test.want)
		}
	}
	old := now.Add(-40 * 24 * time.Hour)
	if got := agentRelativeTime(i18n.English, now, old); got != old.Local().Format("2006-01-02") {
		t.Fatalf("a month ago: %q", got)
	}
}

// A row's stats count its messages and subagents and say when it was last active.
func TestAgentSessionStats(t *testing.T) {
	now := time.Date(2026, 11, 28, 12, 0, 0, 0, time.UTC)
	session := agents.RecordedSession{MessageCount: 1, SubagentCount: 3, UpdatedAtMs: now.Add(-2 * time.Hour).UnixMilli()}
	if got := agentSessionStats(i18n.English, session, now); got != "1 message · 3 subagents · 2 hours ago" {
		t.Fatalf("stats = %q", got)
	}
	session.SubagentCount = 0
	if got := agentSessionStats(i18n.Chinese, session, now); got != "1 条消息 · 2 小时前" {
		t.Fatalf("stats = %q", got)
	}
	if got := agentSessionStats(i18n.English, agents.RecordedSession{}, now); got != "" {
		t.Fatalf("empty stats = %q", got)
	}
}

// A narrow meta line takes the agent's name down to its minimum first, then the model, which
// drops out rather than show a sliver, then the counts and age, and last the rest of the name.
func TestAgentMetaWidthsGiveWayInOrder(t *testing.T) {
	const gap, nameMin, modelMin = 5, 30, 40
	natural := [3]float32{100, 200, 120} // name, counts and age, model: 430 with two gaps
	cases := []struct {
		room float32
		want [3]float32
	}{
		{room: 500, want: natural},
		{room: 430, want: natural},
		{room: 400, want: [3]float32{70, 200, 120}},
		{room: 330, want: [3]float32{30, 200, 90}},
		{room: 280, want: [3]float32{30, 200, 40}},
		{room: 270, want: [3]float32{30, 200, 0}},
		{room: 235, want: [3]float32{30, 200, 0}},
		{room: 200, want: [3]float32{30, 165, 0}},
		{room: 20, want: [3]float32{15, 0, 0}},
	}
	for _, tc := range cases {
		if got := agentMetaWidths(tc.room, gap, nameMin, modelMin, natural); got != tc.want {
			t.Errorf("room %v: widths = %v, want %v", tc.room, got, tc.want)
		}
	}
	if got := agentMetaWidths(200, gap, nameMin, modelMin, [3]float32{100, 120, 0}); got != [3]float32{75, 120, 0} {
		t.Errorf("without a model: widths = %v", got)
	}
	if got := agentMetaWidths(25, gap, nameMin, modelMin, [3]float32{20, 0, 0}); got != [3]float32{20, 0, 0} {
		t.Errorf("a short name alone: widths = %v", got)
	}
}

// A directory heading reads as its last two components, ~ for home, and its tooltip never shows
// the home directory's path.
func TestAgentGroupLabelAndHomePath(t *testing.T) {
	home := "/Users/someone"
	for _, test := range []struct{ cwd, want string }{
		{"", "No directory"},
		{home, "~"},
		{home + "/", "~"},
		{home + "/Dev/Lithe-IDEA/desktop", "Lithe-IDEA/desktop"},
		{"/srv", "srv"},
		{`C:\Users\someone\repo`, "someone/repo"},
	} {
		if got := agentGroupLabel(i18n.English, test.cwd, home); got != test.want {
			t.Errorf("label of %q = %q, want %q", test.cwd, got, test.want)
		}
	}
	for _, test := range []struct{ cwd, want string }{
		{home, "~"},
		{home + "/Dev/x", "~/Dev/x"},
		{home + "two/x", home + "two/x"},
		{"/srv/x", "/srv/x"},
		{"", ""},
	} {
		if got := agentHomePath(test.cwd, home+"/"); got != test.want {
			t.Errorf("home path of %q = %q, want %q", test.cwd, got, test.want)
		}
	}
}
