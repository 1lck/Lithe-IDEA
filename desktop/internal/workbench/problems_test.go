package workbench

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugindiag"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// problemSet builds the per-plugin store a running server would publish. Records
// of one file form a single batch, because Replace swaps a file's whole list.
func problemSet(t *testing.T, records ...plugindiag.Diagnostic) *plugindiag.Set {
	t.Helper()
	set := plugindiag.NewSet()
	byFile := make(map[string][]plugindiag.Diagnostic)
	for _, record := range records {
		byFile[record.FileKey] = append(byFile[record.FileKey], record)
	}
	for file, batch := range byFile {
		if err := set.Replace(file, batch); err != nil {
			t.Fatal(err)
		}
	}
	return set
}

// openProblemsPanel clicks the stripe button and paints until the background
// Core query has been applied.
func openProblemsPanel(t *testing.T, h *harness) {
	t.Helper()
	h.click(center(h.button(itemProblems)))
	awaitDocumentState(t, h, func() bool { return h.app.problems.loaded && !h.app.problems.querying })
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
}

func TestProblemsPanelUsesCoreOrderAndOpensPosition(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	file2 := filepath.Join(root, "src", "File2.java")
	content := "class File2 {\n  int value = 1;\n}\n"
	if err := os.WriteFile(file2, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	h.open(root)

	// Submit File10 before File2. Core's natural file order must put File2 first
	// regardless of submission order.
	file10 := filepath.Join(root, "src", "File10.java")
	h.app.pluginDiagnostics = map[string]*plugindiag.Set{"java": problemSet(t,
		plugindiag.Diagnostic{FileKey: file10, DisplayPath: "src/File10.java", Line: 0, Column: 0, Severity: plugindiag.SeverityWarning, Message: "unused"},
		plugindiag.Diagnostic{FileKey: file2, DisplayPath: "src/File2.java", Line: 1, Column: 2, EndLine: 1, EndColumn: 7, Severity: plugindiag.SeverityError, Message: "type mismatch"},
	)}
	h.app.markProblemsChanged()

	openProblemsPanel(t, h)
	if got := h.app.problems.result.Groups; len(got) != 2 {
		t.Fatalf("groups = %+v", got)
	}
	if got := h.app.problems.result.Groups[0].DisplayPath; got != "src/File2.java" {
		t.Fatalf("first group = %q, want Core's natural file order", got)
	}
	if !h.shows("src/File2.java") {
		t.Fatal("the panel does not show the first file header")
	}
	if got := h.app.problems.rows; got != 4 {
		t.Fatalf("flat rows = %d, want two headers and two diagnostics", got)
	}

	// Flat row 0 is the File2 header and row 1 is its diagnostic.
	at := center(h.hit(problemsRows.At(1)))
	if err := h.driver.Click(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(file2) != nil })
	document := h.app.project.docs.byPath(file2)
	if document == nil {
		t.Fatal("the clicked diagnostic did not open its document")
	}
	if line, column := document.view.Caret(); line != 1 || column != 2 {
		t.Fatalf("caret = %d:%d, want the diagnostic's zero-based 1:2", line, column)
	}
}

func TestProblemsPanelVirtualizesLongList(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	path := filepath.Join(root, "Many.java")
	records := make([]plugindiag.Diagnostic, 400)
	for i := range records {
		records[i] = plugindiag.Diagnostic{FileKey: path, DisplayPath: "Many.java", Line: i, Column: 0, Severity: plugindiag.SeverityWarning, Message: "problem"}
	}
	h.open(root)
	h.app.pluginDiagnostics = map[string]*plugindiag.Set{"java": problemSet(t, records...)}
	h.app.markProblemsChanged()

	openProblemsPanel(t, h)
	if got := h.app.problems.rows; got != len(records)+1 {
		t.Fatalf("flat rows = %d, want %d", got, len(records)+1)
	}
	declared := 0
	for _, hit := range h.driver.Snapshot().Hits {
		if _, ok := hit.ID.In(problemsRows); ok {
			declared++
		}
	}
	if declared == 0 {
		t.Fatal("the panel declared no diagnostic rows")
	}
	// The list window is a few rows tall, so only a small slice is declared even
	// though the model holds 400 diagnostics.
	if declared >= 60 {
		t.Fatalf("declared %d of %d rows; the list is not virtualized", declared, len(records))
	}
}

func TestProblemsViewDropsStaleAnswer(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	h.app.chrome.open[slotBottomLeft] = catalogIndex[itemProblems]
	h.app.problems.generation = 7
	h.app.problems.querying = true
	h.app.applyProblemsQuery(p, 6, nil, core.ProblemsResult{}, nil)
	if h.app.problems.loaded || h.app.problems.querying {
		t.Fatalf("a stale answer was applied: %+v", h.app.problems)
	}
	// The current answer is accepted and replaces any previous failure.
	h.app.problems.failure = errors.New("old")
	h.app.applyProblemsQuery(p, 7, nil, core.ProblemsResult{
		Groups: []core.ProblemsGroup{{Key: "all", Kind: "all", Indices: []int{0}, Counts: core.ProblemsSeverityCounts{Error: 1}}},
	}, nil)
	if !h.app.problems.loaded || h.app.problems.failure != nil {
		t.Fatalf("the current answer was not applied: %+v", h.app.problems)
	}
	if h.app.problems.rows != 2 {
		t.Fatalf("rows = %d, want a header and one diagnostic", h.app.problems.rows)
	}
}

func TestProblemsRowLayout(t *testing.T) {
	v := problemsView{
		result: core.ProblemsResult{Groups: []core.ProblemsGroup{
			{Indices: []int{0, 1}},
			{Indices: []int{2}},
		}},
		starts: []int{0, 3},
		rows:   5,
	}
	want := []struct {
		group, index int
		header       bool
	}{
		{0, 0, true},
		{0, 0, false},
		{0, 1, false},
		{1, 0, true},
		{1, 0, false},
	}
	for row, expected := range want {
		group, index, header := v.rowAt(row)
		if group != expected.group || index != expected.index || header != expected.header {
			t.Fatalf("row %d = group %d index %d header %v, want %+v", row, group, index, header, expected)
		}
	}
	if _, _, header := v.rowAt(v.rows); header {
		t.Fatalf("row %d is past the end", v.rows)
	}
}

func TestStoppingAServerWithdrawsOnlyItsDiagnostics(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	file := filepath.Join(t.TempDir(), "A.java")
	h.app.pluginDiagnostics = map[string]*plugindiag.Set{
		"java":  problemSet(t, plugindiag.Diagnostic{FileKey: file, DisplayPath: "A.java", Line: 0, Column: 0, Severity: plugindiag.SeverityError, Message: "java"}),
		"other": problemSet(t, plugindiag.Diagnostic{FileKey: file, DisplayPath: "A.java", Line: 1, Column: 0, Severity: plugindiag.SeverityWarning, Message: "other"}),
	}
	if got := h.app.pluginProblemCount(); got != 2 {
		t.Fatalf("problem count = %d, want both plugins' diagnostics", got)
	}
	h.app.stopPluginServer("java")
	if _, ok := h.app.pluginDiagnostics["java"]; ok {
		t.Fatal("the stopped plugin kept diagnostics")
	}
	if h.app.pluginDiagnostics["other"] == nil {
		t.Fatal("stopping one server withdrew another plugin's diagnostics")
	}
	h.app.clearAllPluginDiagnostics()
	if h.app.pluginDiagnostics != nil {
		t.Fatalf("diagnostics = %v, want every store cleared", h.app.pluginDiagnostics)
	}
}

// A server restart must not keep the previous process's problems while the new
// one has not published anything yet.
func TestRestartedServerStartsWithNoDiagnostics(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	file := filepath.Join(t.TempDir(), "A.java")
	h.app.pluginDiagnostics = map[string]*plugindiag.Set{
		"java": problemSet(t, plugindiag.Diagnostic{FileKey: file, DisplayPath: "A.java", Line: 0, Column: 0, Severity: plugindiag.SeverityError, Message: "old"}),
	}
	h.app.clearPluginDiagnostics("java")
	if len(h.app.pluginDiagnostics) != 0 {
		t.Fatalf("diagnostics = %v", h.app.pluginDiagnostics)
	}
	if h.app.pluginProblemCount() != 0 {
		t.Fatalf("problem count = %d", h.app.pluginProblemCount())
	}
}

// A diagnostics event from a server the window already replaced or from another
// project must not repopulate the list.
func TestProblemsDropStaleServerEvents(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	oldProject := &project{root: t.TempDir()}
	cancel := func() {}
	server := &pluginServer{session: &pluginservice.LanguageSession{PluginID: "java"}, project: oldProject, cancel: cancel}
	h.app.pluginServers = map[string]*pluginServer{"java": {session: &pluginservice.LanguageSession{PluginID: "java"}, cancel: cancel}}
	h.app.applyServerDiagnostics(server, core.PluginDiagnosticsEvent{URI: "file:///a.java"})
	if h.app.pluginDiagnostics != nil {
		t.Fatalf("a retired server's event was stored: %v", h.app.pluginDiagnostics)
	}
}

// Closing the tool window releases the copy of the diagnostics it submitted.
func TestProblemsCacheIsDroppedWhenThePanelCloses(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	path := filepath.Join(h.app.project.root, "A.java")
	h.app.pluginDiagnostics = map[string]*plugindiag.Set{"java": problemSet(t,
		plugindiag.Diagnostic{FileKey: path, DisplayPath: "A.java", Line: 0, Column: 0, Severity: plugindiag.SeverityError, Message: "boom"},
	)}
	h.app.markProblemsChanged()
	openProblemsPanel(t, h)
	if !h.app.problems.loaded {
		t.Fatal("the panel did not load its query")
	}
	h.click(center(h.button(itemProblems)))
	if h.app.problems.loaded || h.app.problems.rows != 0 || len(h.app.problems.diagnostics) != 0 {
		t.Fatalf("closing the panel kept its cached answer: %+v", h.app.problems)
	}
}

// A serve loop that ends without an explicit stop (a crash or self-exit) still
// withdraws the diagnostics its process published.
func TestExitedServerWithdrawsDiagnostics(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	file := filepath.Join(t.TempDir(), "A.java")
	server := &pluginServer{session: &pluginservice.LanguageSession{PluginID: "java"}, cancel: func() {}}
	h.app.pluginServers = map[string]*pluginServer{"java": server}
	h.app.pluginServerLanguages = map[string]string{"java": "java"}
	h.app.pluginDiagnostics = map[string]*plugindiag.Set{"java": problemSet(t,
		plugindiag.Diagnostic{FileKey: file, DisplayPath: "A.java", Line: 0, Column: 0, Severity: plugindiag.SeverityError, Message: "boom"},
	)}
	h.app.pluginServerExited("java", server)
	if _, ok := h.app.pluginServers["java"]; ok {
		t.Fatal("the exited server is still registered")
	}
	if len(h.app.pluginDiagnostics) != 0 {
		t.Fatalf("diagnostics = %v, want the exited server's list withdrawn", h.app.pluginDiagnostics)
	}
}
