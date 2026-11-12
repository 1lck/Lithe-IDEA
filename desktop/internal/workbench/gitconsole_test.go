package workbench

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// openConsole opens dir, runs a Git command the console records, and shows the Console tab
// of the Git tool window until Core presented every recorded command. Core records the
// commands of git.write, not the reads that load the window, so the test prunes the
// worktrees, which changes nothing in a repository without a linked worktree.
func (h *harness) openConsole(t *testing.T, dir string) {
	t.Helper()
	h.open(dir)
	p := h.app.project
	if p == nil || !p.git.isRepository() {
		t.Fatalf("the project is not a loaded repository: %+v", p)
	}
	kernel, ok := h.app.kernel.(gitKernel)
	if !ok {
		t.Fatalf("the window's kernel is %T, want gitKernel", h.app.kernel)
	}
	if err := kernel.GitPruneWorktrees(p.ctx, p.root); err != nil {
		t.Fatalf("GitPruneWorktrees() error: %v", err)
	}
	h.app.layout.gitTab = gitTabConsole
	h.app.invalidator.Invalidate()
	h.settle()
	if !h.app.consoleView.read {
		h.click(center(h.button(itemGit)))
		h.settle()
	}
	if !h.app.consoleView.read {
		t.Fatal("the Console tab is not shown")
	}
	h.await("the console's commands to be presented", func() bool { return consolePresentedAll(&h.app.consoleView) })
}

// consolePresentedAll says v holds commands and Core's presentation of each, made for the
// record as it is and the search the rows were flattened for.
func consolePresentedAll(v *consoleView) bool {
	if v.presenting || v.failed || len(v.snapshot.Records) == 0 {
		return false
	}
	for i := range v.snapshot.Records {
		r := &v.snapshot.Records[i]
		p := v.presented[r.ID]
		if p == nil || p.revision != r.Revision || p.search != v.searchFor {
			return false
		}
	}
	return true
}

// searchConsole types text into the console's search and paints what the search found.
func (h *harness) searchConsole(text string) {
	h.t.Helper()
	h.app.consoleView.search.SetText(text)
	h.app.invalidator.Invalidate()
	h.settle()
}

// consoleWord is an argument of a recorded command that a search finds as it is: at least
// three lowercase letters or dashes. It is empty when no command has one.
func consoleWord(records []core.GitConsoleRecord) string {
	for i := range records {
		for _, argument := range records[i].Arguments {
			if len(argument) >= 3 && strings.Trim(argument, "abcdefghijklmnopqrstuvwxyz-") == "" {
				return argument
			}
		}
	}
	return ""
}

func TestConsoleListsTheRecordedCommands(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	h.openConsole(t, dir)
	header := "[" + filepath.Base(dir) + "] git "
	h.await("a recorded git command", func() bool { return h.showsWrapped(header) })

	h.clickNamed(h.app.text.Console.CopyAll)
	if copied := h.driver.Clipboard(); !strings.Contains(copied, header) {
		t.Fatalf("the copied console is %q, want a command headed %q", copied, header)
	}
}

func TestConsoleSearchesAndClears(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, gitKernel{core.NewClient()})
	h.openConsole(t, dir)
	v, text := &h.app.consoleView, &h.app.text.Console
	word := consoleWord(v.snapshot.Records)
	if word == "" {
		t.Fatalf("no recorded argument to search for: %+v", v.snapshot.Records)
	}

	h.searchConsole(word)
	h.await("the matches of "+word, func() bool {
		return v.searchFor == word && v.counted && v.total > 0 && h.shows(text.Matches(v.total))
	})

	const nonsense = "zzqxjv-no-such-text"
	h.searchConsole(nonsense)
	h.await("no match for "+nonsense, func() bool {
		return v.searchFor == nonsense && v.counted && v.total == 0 && h.shows(text.NoMatches)
	})

	h.clickNamed(text.Clear)
	h.await("the empty console", func() bool { return h.shows(text.Empty) })
}

// consoleStarted is the start time of the records of the tests that need no Core, shown as
// 09:08:07.006 in UTC.
var consoleStarted = time.Date(2026, 11, 10, 9, 8, 7, 6_000_000, time.UTC)

// consoleFetch is a fetch with one temporary setting that wrote a line of text and three
// progress lines, with the presentation Core gives it: the setting and the progress lines
// each in a fold.
func consoleFetch() (core.GitConsoleRecord, *consolePresented) {
	record := core.GitConsoleRecord{
		ID:              "r1",
		Revision:        3,
		Started:         consoleStarted,
		Root:            "/work/repo",
		Arguments:       []string{"fetch", "origin"},
		TemporaryConfig: [][2]string{{"color.ui", "false"}},
		Lines: []core.GitConsoleLine{
			{Stream: "stdout", Text: "From origin"},
			{Stream: "stderr", Text: "Receiving 10%"},
			{Stream: "stderr", Text: "Receiving 50%"},
			{Stream: "stderr", Text: "Receiving 100%"},
		},
		State:  core.GitConsoleCompleted,
		Exited: true,
	}
	presented := &consolePresented{
		revision: 3,
		lines:    4,
		entry: core.GitConsoleEntry{
			ID:              "r1",
			RepositoryLabel: "/work/repo",
			Command: []core.GitConsoleCommandFragment{
				{ID: "configuration-0", Kind: consoleFragmentConfiguration, Text: "-c color.ui=false", Preview: "-c ...", Count: 1},
				{ID: "argument-0", Kind: "text", Text: "fetch"},
				{ID: "argument-1", Kind: "text", Text: "origin"},
			},
			Output: []core.GitConsoleOutputFragment{
				{ID: "output-0", Start: 0, End: 1, Kind: "text", Count: 1},
				{ID: "output-1", Start: 1, End: 4, Kind: consoleFragmentProgress, Count: 3},
			},
		},
	}
	return record, presented
}

// consoleViewOf is a console view of records with presented, Core's presentations by record
// ID, as the window holds them after a snapshot.
func consoleViewOf(records []core.GitConsoleRecord, presented map[string]*consolePresented) *consoleView {
	return &consoleView{read: true, snapshot: core.GitConsoleSnapshot{Records: records, Revision: 1}, presented: presented}
}

// consoleHasRow says one of the rows of v reads text.
func consoleHasRow(v *consoleView, text string) bool {
	for _, row := range v.rows {
		if row.text == text {
			return true
		}
	}
	return false
}

func TestConsoleFlattenFoldsAndKeepsKeys(t *testing.T) {
	text := &i18n.For(i18n.English).Console
	record, presented := consoleFetch()
	v := consoleViewOf([]core.GitConsoleRecord{record}, map[string]*consolePresented{record.ID: presented})

	v.flatten(text, time.UTC)
	if len(v.rows) != 3 {
		t.Fatalf("the closed rows are %+v, want the header, a line and a fold", v.rows)
	}
	header, fold := v.rows[0], v.rows[2]
	if header.text != "09:08:07.006: [repo] git -c ... fetch origin" || header.toggle != text.ExpandConfiguration(1) || !header.folded {
		t.Fatalf("the closed header is %+v", header)
	}
	if v.rows[1].text != "From origin" || v.rows[1].toggle != "" {
		t.Fatalf("the line row is %+v", v.rows[1])
	}
	if fold.text != "Receiving 100%" || fold.toggle != text.ExpandLines(3) || !fold.folded {
		t.Fatalf("the closed fold is %+v", fold)
	}

	v.open = map[consoleFold]bool{header.fold: true, fold.fold: true}
	v.flatten(text, time.UTC)
	if len(v.rows) != 5 {
		t.Fatalf("the open rows are %+v, want the header and four lines", v.rows)
	}
	opened, last := v.rows[0], v.rows[4]
	if opened.text != "09:08:07.006: [repo] git -c color.ui=false fetch origin" || opened.toggle != text.Collapse || opened.folded {
		t.Fatalf("the open header is %+v", opened)
	}
	if v.rows[2].text != "Receiving 10%" || v.rows[2].toggle != "" || v.rows[3].text != "Receiving 50%" {
		t.Fatalf("the open fold's lines are %+v", v.rows[2:4])
	}
	if last.text != "Receiving 100%" || last.toggle != text.Collapse || last.folded {
		t.Fatalf("the open fold's last line is %+v", last)
	}
	if opened.key != header.key || last.key != fold.key {
		t.Fatalf("the keys changed: header %d to %d, fold %d to %d", header.key, opened.key, fold.key, last.key)
	}
}

func TestConsoleFlattenShowsOnlyAnUnexpectedExit(t *testing.T) {
	text := &i18n.For(i18n.English).Console
	cases := []struct {
		name     string
		code     int
		expected bool
		shown    bool
	}{
		{name: "unexpected", code: 1, shown: true},
		{name: "expected", code: 1, expected: true},
		{name: "success", code: 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			record := core.GitConsoleRecord{
				ID:           "r2",
				Revision:     1,
				Started:      consoleStarted,
				Root:         "/work/repo",
				Arguments:    []string{"status"},
				Lines:        []core.GitConsoleLine{{Stream: "stdout", Text: "a"}},
				State:        core.GitConsoleCompleted,
				Exited:       true,
				ExitCode:     tc.code,
				ExpectedExit: tc.expected,
			}
			v := consoleViewOf([]core.GitConsoleRecord{record}, nil)
			v.flatten(text, time.UTC)
			if len(v.rows) == 0 || v.rows[0].text != "09:08:07.006: [repo] git status" {
				t.Fatalf("the rows are %+v, want the header first", v.rows)
			}
			if got := consoleHasRow(v, text.ExitCode(tc.code)); got != tc.shown {
				t.Fatalf("the exit code row is shown: %v, want %v; rows %+v", got, tc.shown, v.rows)
			}
			if failed := v.rows[0].tone == consoleToneError; failed != tc.shown {
				t.Fatalf("the header is drawn failed: %v, want %v", failed, tc.shown)
			}
		})
	}
}

func TestConsoleStepOpensTheFoldOfAHit(t *testing.T) {
	text := &i18n.For(i18n.English).Console
	record, presented := consoleFetch()
	line := 1
	presented.search = "receiving"
	presented.entry.Matches = 3
	presented.hits = []core.GitConsoleHit{{RecordID: record.ID, FragmentID: "output-1", LineIndex: &line}}
	v := consoleViewOf([]core.GitConsoleRecord{record}, map[string]*consolePresented{record.ID: presented})
	v.searchFor = "receiving"

	v.flatten(text, time.UTC)
	if v.total != 3 || !v.counted || len(v.hits) != 1 || v.hits[0].row != 2 || v.hits[0].fold.fragment != "output-1" {
		t.Fatalf("the hits are %+v of %d, counted %v; want one on the closed fold of 3 matches", v.hits, v.total, v.counted)
	}

	v.step(1, text, time.UTC)
	if !v.open[consoleFold{record: record.ID, fragment: "output-1"}] {
		t.Fatalf("stepping to the hit left its fold closed: %+v", v.open)
	}
	if v.hitIndex != 0 || v.hitRow != 2 || v.rows[v.hitRow].text != "Receiving 10%" || !v.detach {
		t.Fatalf("the current hit is %d on row %d (detach %v), want the first on the line it matched", v.hitIndex, v.hitRow, v.detach)
	}
}

func TestConsoleCopyTexts(t *testing.T) {
	text := &i18n.For(i18n.English).Console
	commit := core.GitConsoleRecord{
		Arguments:       []string{"commit", "-m", "it's done", "--allow-empty"},
		TemporaryConfig: [][2]string{{"user.name", "A B"}},
		Lines:           []core.GitConsoleLine{{Stream: "stdout", Text: "a"}, {Stream: "stdout", Text: "b"}},
	}
	if got, want := consoleCommand(&commit), `git -c 'user.name=A B' commit -m 'it'\''s done' --allow-empty`; got != want {
		t.Fatalf("the command is %s, want %s", got, want)
	}
	if got := consoleOutput(&commit); got != "a\nb" {
		t.Fatalf("the output is %q, want the lines joined", got)
	}

	status := core.GitConsoleRecord{
		Started:   consoleStarted,
		Root:      "/work/repo",
		Arguments: []string{"status"},
		Lines:     []core.GitConsoleLine{{Stream: "stdout", Text: "a"}},
		Exited:    true,
		ExitCode:  1,
	}
	want := "09:08:07.006: [repo] git status\na\n" + text.ExitCode(1)
	if got := consoleCopyAll([]core.GitConsoleRecord{status}, text, time.UTC); got != want {
		t.Fatalf("the copied console is %q, want %q", got, want)
	}
}

// A Git write the user starts shows the Console tab of the Git tool window. Started in the
// Commit tool window, it opens the Git tool window beside it; where the Commit tool window
// stands in the Git tool window's place, it only selects the tab, so the write does not
// close the window it was started in.
func TestGitWritesShowTheConsole(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	commit, git := catalogIndex[itemCommit], catalogIndex[itemGit]
	h.app.reduceChrome(core.SetChromeOpen(itemGit, false))
	h.app.layout.gitTab = gitTabLog
	h.settle()

	h.app.openStashPush(p)
	h.app.pushStash(p)
	h.settleChain()
	if len(p.stash.list) != 1 || p.stash.writeErr != "" {
		t.Fatalf("stashes after the stash = %+v (%q)", p.stash.list, p.stash.writeErr)
	}
	if h.app.layout.gitTab != gitTabConsole || !h.app.chrome.isOpen(git) || !h.app.chrome.isOpen(commit) {
		t.Fatalf("after the stash: Git tab %d, Git open %v, Commit open %v; want the Console beside the Commit tool window",
			h.app.layout.gitTab, h.app.chrome.isOpen(git), h.app.chrome.isOpen(commit))
	}

	h.app.reduceChrome(core.MoveChrome(itemCommit, core.ZoneBottomLeft, ""))
	h.app.reduceChrome(core.SetChromeOpen(itemCommit, true))
	h.app.layout.gitTab = gitTabLog
	h.settle()
	if h.app.chrome.isOpen(git) || !h.app.chrome.isOpen(commit) {
		t.Fatal("the Commit tool window does not stand in the Git tool window's place")
	}
	h.app.applyStash(p, p.stash.list[0], true)
	h.settleChain()
	if len(p.stash.list) != 0 {
		t.Fatalf("stashes after the pop = %+v", p.stash.list)
	}
	if h.app.layout.gitTab != gitTabConsole || h.app.chrome.isOpen(git) || !h.app.chrome.isOpen(commit) {
		t.Fatalf("after the pop: Git tab %d, Git open %v, Commit open %v; want the Console tab selected behind the Commit tool window",
			h.app.layout.gitTab, h.app.chrome.isOpen(git), h.app.chrome.isOpen(commit))
	}
}

// consoleSpanTexts is the stretches of row's text, each with its kind.
func consoleSpanTexts(row consoleRow) []string {
	var out []string
	from := 0
	for _, span := range row.spans {
		out = append(out, fmt.Sprintf("%d:%s", span.kind, row.text[from:span.end]))
		from = span.end
	}
	return out
}

func TestConsoleHeaderIsSpannedForItsColorsAndItsInlineFold(t *testing.T) {
	text := &i18n.For(i18n.English).Console
	record, presented := consoleFetch()
	v := consoleViewOf([]core.GitConsoleRecord{record}, map[string]*consolePresented{record.ID: presented})

	v.flatten(text, time.UTC)
	header := v.rows[0]
	want := []string{"1:09:08:07.006:", "0: ", "2:[repo]", "4: git ", "3:-c ...", "4: fetch origin"}
	if got := consoleSpanTexts(header); !slices.Equal(got, want) {
		t.Fatalf("the closed header's spans are %q, want %q", got, want)
	}
	if !header.inline || header.toggle != text.ExpandConfiguration(1) {
		t.Fatalf("the closed header's fold is not inline: %+v", header)
	}
	if fold := v.rows[2]; fold.inline || len(fold.spans) != 0 {
		t.Fatalf("the progress fold's toggle is inline or the line is spanned: %+v", fold)
	}

	v.open = map[consoleFold]bool{header.fold: true}
	v.flatten(text, time.UTC)
	want = []string{"1:09:08:07.006:", "0: ", "2:[repo]", "4: git ", "3:-c color.ui=false", "4: fetch origin"}
	if got := consoleSpanTexts(v.rows[0]); !slices.Equal(got, want) {
		t.Fatalf("the open header's spans are %q, want %q", got, want)
	}

	// Without Core's presentation the header still has its stamp and repository.
	raw := consoleViewOf([]core.GitConsoleRecord{record}, nil)
	raw.flatten(text, time.UTC)
	want = []string{"1:09:08:07.006:", "0: ", "2:[repo]", "4: git -c color.ui=false fetch origin"}
	if got := consoleSpanTexts(raw.rows[0]); !slices.Equal(got, want) {
		t.Fatalf("the raw header's spans are %q, want %q", got, want)
	}
}

// consolePieceTexts is pieces as "line:kind:text".
func consolePieceTexts(pieces []consolePiece) []string {
	out := make([]string, 0, len(pieces))
	for _, p := range pieces {
		out = append(out, fmt.Sprintf("%d:%d:%s", p.line, p.kind, p.text))
	}
	return out
}

func TestLayoutConsoleRowBreaksAndCutsByCells(t *testing.T) {
	spans := []consoleSpan{{end: 3, kind: consoleSpanStamp}, {end: 8, kind: consoleSpanText}}
	cases := []struct {
		name  string
		text  string
		spans []consoleSpan
		cells int
		wrap  bool
		want  []string
	}{
		{name: "unknown width", text: "abcdefgh", cells: 0, want: []string{"0:0:abcdefgh"}},
		{name: "fits", text: "abcd", cells: 4, want: []string{"0:0:abcd"}},
		{name: "cut", text: "abcdef", cells: 4, want: []string{"0:0:abc", "0:0:…"}},
		{name: "cut in the second span", text: "abcdefgh", spans: spans, cells: 6, want: []string{"0:1:abc", "0:0:de", "0:0:…"}},
		{name: "wrap across spans", text: "abcdefgh", spans: spans, cells: 5, wrap: true, want: []string{"0:1:abc", "0:0:de", "1:0:fgh"}},
		{name: "wide characters", text: "中文ab", cells: 3, wrap: true, want: []string{"0:0:中", "1:0:文a", "2:0:b"}},
		{name: "cut before a wide character", text: "a中文", cells: 4, want: []string{"0:0:a中", "0:0:…"}},
		{name: "wide character wider than the row", text: "中", cells: 1, wrap: true, want: []string{"0:0:中"}},
		{name: "empty", text: "", cells: 4, want: []string{}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := consolePieceTexts(layoutConsoleRow(nil, tc.text, tc.spans, tc.cells, tc.wrap))
			if !slices.Equal(got, tc.want) {
				t.Fatalf("layoutConsoleRow(%q, %d, wrap %v) = %q, want %q", tc.text, tc.cells, tc.wrap, got, tc.want)
			}
		})
	}
}

func TestConsoleExpandTabsToTheNextStop(t *testing.T) {
	cases := map[string]string{
		"no tab":          "no tab",
		"\tmodified:   a": "        modified:   a",
		"ab\tc":           "ab      c",
		"中\tx":            "中      x",
		"12345678\ty":     "12345678        y",
	}
	for in, want := range cases {
		if got := consoleExpandTabs(in); got != want {
			t.Fatalf("consoleExpandTabs(%q) = %q, want %q", in, got, want)
		}
	}
}

// consoleQuery is a query Core reported, a log of four lines, and Core's presentation of it,
// which folds the whole output.
func consoleQuery() (core.GitConsoleRecord, *consolePresented) {
	record := core.GitConsoleRecord{
		ID:               "q1",
		Revision:         2,
		Started:          consoleStarted,
		Root:             "/work/repo",
		Arguments:        []string{"-c", "core.quotepath=false", "log", "--format=%H"},
		DisplayArguments: []string{"log", "--format=%H"},
		Query:            true,
		Lines: []core.GitConsoleLine{
			{Stream: "stdout", Text: "a1"},
			{Stream: "stdout", Text: "b2"},
			{Stream: "stdout", Text: "c3"},
			{Stream: "stdout", Text: "d4"},
		},
		State:  core.GitConsoleCompleted,
		Exited: true,
	}
	presented := &consolePresented{
		revision: 2,
		lines:    4,
		entry: core.GitConsoleEntry{
			ID:              "q1",
			RepositoryLabel: "/work/repo",
			Command: []core.GitConsoleCommandFragment{
				{ID: "argument-0", Kind: "text", Text: "log"},
				{ID: "argument-1", Kind: "text", Text: "--format=%H"},
			},
			Output: []core.GitConsoleOutputFragment{{ID: "output-0", Start: 0, End: 4, Kind: consoleFragmentQuery, Count: 4}},
		},
	}
	return record, presented
}

func TestConsoleFoldsTheWholeOutputOfAQuery(t *testing.T) {
	text := &i18n.For(i18n.English).Console
	record, presented := consoleQuery()
	v := consoleViewOf([]core.GitConsoleRecord{record}, map[string]*consolePresented{record.ID: presented})

	v.flatten(text, time.UTC)
	if len(v.rows) != 2 {
		t.Fatalf("the closed rows are %+v, want the header and the fold", v.rows)
	}
	header, fold := v.rows[0], v.rows[1]
	if header.text != "09:08:07.006: [repo] git log --format=%H" || header.tone != consoleToneSubtle {
		t.Fatalf("the query's header is %+v, want it subtle", header)
	}
	if fold.text != text.QueryOutput(4) || fold.toggle != text.Expand || !fold.folded || !fold.summary || fold.tone != consoleToneSubtle {
		t.Fatalf("the closed fold is %+v", fold)
	}

	v.open = map[consoleFold]bool{fold.fold: true}
	v.flatten(text, time.UTC)
	if len(v.rows) != 5 {
		t.Fatalf("the open rows are %+v, want the header and four lines", v.rows)
	}
	first, last := v.rows[1], v.rows[4]
	if first.text != "a1" || first.toggle != "" || first.tone != consoleToneSubtle {
		t.Fatalf("the open fold's first line is %+v", first)
	}
	if last.text != "d4" || last.toggle != text.Collapse || last.folded {
		t.Fatalf("the open fold's last line is %+v", last)
	}
	if first.key != fold.key {
		t.Fatalf("the fold's key changed from %d to %d as it opened", fold.key, first.key)
	}
}

func TestConsoleStepOpensTheFoldOfAQueryHit(t *testing.T) {
	text := &i18n.For(i18n.English).Console
	record, presented := consoleQuery()
	line := 2
	presented.search = "c3"
	presented.entry.Matches = 1
	presented.hits = []core.GitConsoleHit{{RecordID: record.ID, FragmentID: "output-0", LineIndex: &line}}
	v := consoleViewOf([]core.GitConsoleRecord{record}, map[string]*consolePresented{record.ID: presented})
	v.searchFor = "c3"

	v.flatten(text, time.UTC)
	if len(v.hits) != 1 || v.hits[0].row != 1 {
		t.Fatalf("the hits are %+v, want one on the closed fold", v.hits)
	}
	v.step(1, text, time.UTC)
	if !v.open[consoleFold{record: record.ID, fragment: "output-0"}] {
		t.Fatalf("stepping to the hit left the query's fold closed: %+v", v.open)
	}
	if v.rows[v.hitRow].text != "c3" {
		t.Fatalf("the current hit is on row %d, %+v, want the line it matched", v.hitRow, v.rows[v.hitRow])
	}
}

func TestConsoleHidesSuccessfulQueriesOnly(t *testing.T) {
	text := &i18n.For(i18n.English).Console
	query, presented := consoleQuery()
	broken := query
	broken.ID, broken.ExitCode = "q2", 128
	fetch, fetched := consoleFetch()
	v := consoleViewOf([]core.GitConsoleRecord{query, broken, fetch}, map[string]*consolePresented{query.ID: presented, fetch.ID: fetched})

	v.hideQueries = true
	v.flatten(text, time.UTC)
	records := map[string]bool{}
	for _, row := range v.rows {
		records[row.id.record] = true
	}
	if records[query.ID] || !records[broken.ID] || !records[fetch.ID] {
		t.Fatalf("hiding queries drew the records %v, want the failed query and the fetch only", records)
	}
	for _, row := range v.rows {
		if row.id.record == broken.ID && row.id.part == consolePartHeader && row.tone != consoleToneError {
			t.Fatalf("the failed query's header is %+v, want it drawn failed", row)
		}
	}
	if !consoleHasRow(v, "d4") {
		t.Fatalf("the failed query's output is folded: %+v", v.rows)
	}
}

func TestConsoleDrawsTheProjectedCommandBeforeItIsPresented(t *testing.T) {
	record, _ := consoleQuery()
	if got := consoleDrawnHeader(&record, time.UTC); got != "09:08:07.006: [repo] git log --format=%H" {
		t.Fatalf("consoleDrawnHeader() = %q, want the projected command", got)
	}
	if got := consoleRawHeader(&record, time.UTC); !strings.Contains(got, "core.quotepath=false") {
		t.Fatalf("consoleRawHeader() = %q, want the whole command for copying", got)
	}
	record.DisplayArguments = nil
	if got, want := consoleDrawnHeader(&record, time.UTC), consoleRawHeader(&record, time.UTC); got != want {
		t.Fatalf("consoleDrawnHeader() without a projection = %q, want the raw header %q", got, want)
	}
}
