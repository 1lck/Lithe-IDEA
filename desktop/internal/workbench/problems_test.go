package workbench

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
	awaitProblems(t, h)
}

// awaitProblems paints until the answer for the tree's current state and the current file has
// been applied, then paints it.
func awaitProblems(t *testing.T, h *harness) {
	t.Helper()
	v := &h.app.problems
	awaitDocumentState(t, h, func() bool {
		return v.loaded && !v.querying && v.queried == v.generation && v.file == h.app.problemsCurrentFile()
	})
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
}

// problemsRowKeys is the keys of the tree's visible rows.
func problemsRowKeys(v *problemsView) []string {
	keys := make([]string, len(v.result.Rows))
	for i, r := range v.result.Rows {
		keys[i] = r.Key
	}
	return keys
}

// problemsRowNamed is the name of the visible row with key, which the tree's control for it
// carries.
func problemsRowNamed(t *testing.T, h *harness, key string) string {
	t.Helper()
	i := h.app.problems.rowOf(key)
	if i < 0 {
		t.Fatalf("row %q does not show; rows %v", key, problemsRowKeys(&h.app.problems))
	}
	return h.app.problemsRowLabel(i)
}

// problemsDiagnosticRow is the key of the visible row of the diagnostic with message.
func problemsDiagnosticRow(t *testing.T, h *harness, message string) string {
	t.Helper()
	v := &h.app.problems
	for _, r := range v.result.Rows {
		if r.Kind == core.ProblemsRowDiagnostic && v.diagnostics[r.Shows].Message == message {
			return r.Key
		}
	}
	t.Fatalf("no row shows %q; rows %v", message, problemsRowKeys(v))
	return ""
}

// problemsTab is the header tab's name for a count, as the File or Project tab shows it.
func problemsTab(h *harness, project bool, count int) string {
	if project {
		return problemsProjectTabText(h.app.language(), count)
	}
	return problemsFileTabText(h.app.language(), count)
}

func TestProblemsTabsCountTheCurrentFileAndTheProject(t *testing.T) {
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

	// The window opens on the File tab, as IDEA's does; no file is open yet.
	openProblemsPanel(t, h)
	v := &h.app.problems
	lang := h.app.language()
	if v.project || v.fileCount != 0 || v.projectCount != 2 || len(v.result.Rows) != 0 {
		t.Fatalf("project %v, counts %d/%d, rows %v", v.project, v.fileCount, v.projectCount, problemsRowKeys(v))
	}
	if !h.shows(i18n.Shared(lang, "desktop.problems.noOpenFile")) {
		t.Fatal("the File tab does not say that no file is open")
	}

	h.clickNamed(problemsTab(h, true, 2))
	awaitProblems(t, h)
	if !v.project {
		t.Fatal("the Project tab was not chosen")
	}
	if got := v.result.Groups; len(got) != 2 || got[0].DisplayPath != "src/File2.java" || got[0].Name != "File2.java" || got[0].Folder != "src" {
		t.Fatalf("groups = %+v, want Core's natural file order with File2 first", got)
	}
	file2Node, file10Node := "file:"+file2, "file:"+file10
	if keys := problemsRowKeys(v); len(keys) != 4 || keys[0] != file2Node || keys[2] != file10Node {
		t.Fatalf("rows = %v, want each file's node over its diagnostic", keys)
	}
	if n := v.node(0); n.Depth != 0 || !n.Branch || !n.Expanded {
		t.Fatalf("file node = %+v", n)
	}
	if n := v.node(1); n.Depth != 1 || n.Branch {
		t.Fatalf("diagnostic = %+v", n)
	}
	if !h.shows("File2.java") {
		t.Fatal("the panel does not show the first file's node")
	}

	// With the preview off, a click on a diagnostic opens it at its position.
	h.clickNamed(problemsRowNamed(t, h, v.result.Rows[1].Key))
	awaitDocumentState(t, h, func() bool { return h.app.project.docs.byPath(file2) != nil })
	document := h.app.project.docs.byPath(file2)
	if line, column := document.view.Caret(); line != 1 || column != 2 {
		t.Fatalf("caret = %d:%d, want the diagnostic's zero-based 1:2", line, column)
	}

	// The opened file is the current one now, so the File tab counts and shows its problem.
	awaitProblems(t, h)
	if v.fileCount != 1 || v.projectCount != 2 {
		t.Fatalf("counts = %d/%d after opening File2", v.fileCount, v.projectCount)
	}
	h.clickNamed(problemsTab(h, false, 1))
	awaitProblems(t, h)
	if keys := problemsRowKeys(v); v.project || len(keys) != 2 || keys[0] != file2Node {
		t.Fatalf("File tab rows = %v", keys)
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
	h.app.problems.project = true

	openProblemsPanel(t, h)
	if got := len(h.app.problems.result.Rows); got != len(records)+1 {
		t.Fatalf("rows = %d, want %d", got, len(records)+1)
	}
	declared := 0
	for _, hit := range h.driver.Snapshot().Hits {
		if strings.HasPrefix(hit.Label, "Many.java:") && !hit.IsLabel {
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
	h.app.applyProblemsQuery(p, problemsAnswer{generation: 6})
	if h.app.problems.loaded || h.app.problems.querying {
		t.Fatalf("a stale answer was applied: %+v", h.app.problems)
	}
	// The current answer is accepted and replaces any previous failure.
	h.app.problems.failure = errors.New("old")
	selected := 1
	h.app.applyProblemsQuery(p, problemsAnswer{generation: 7, projectCount: 1, result: core.ProblemsResult{
		Groups: []core.ProblemsGroup{{Key: "all", Kind: "all", Indices: []int{0}, Counts: core.ProblemsSeverityCounts{Error: 1}}},
		Rows: []core.ProblemsRow{
			{Key: "file:a", Kind: core.ProblemsRowGroup},
			{Key: "diagnostic:0:0:0:a", Kind: core.ProblemsRowDiagnostic, Depth: 1},
		},
		Selected: "diagnostic:0:0:0:a", SelectedRow: &selected,
	}})
	v := &h.app.problems
	if !v.loaded || v.failure != nil || v.projectCount != 1 {
		t.Fatalf("the current answer was not applied: %+v", v)
	}
	if len(v.result.Rows) != 2 || v.selected != "diagnostic:0:0:0:a" || v.selectedRow != 1 {
		t.Fatalf("rows %v, selected %q at %d; want Core's selection", problemsRowKeys(v), v.selected, v.selectedRow)
	}
}

// A row the user selects while a query is in flight stays selected over the selection Core
// answers for the state that query was asked with.
func TestProblemsKeepsASelectionMadeWhileAQueryRuns(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	p := h.app.project
	h.app.chrome.open[slotBottomLeft] = catalogIndex[itemProblems]
	v := &h.app.problems
	v.querying, v.asked, v.selected = true, "", "diagnostic:1:0:0:a"
	first := 0
	h.app.applyProblemsQuery(p, problemsAnswer{result: core.ProblemsResult{
		Rows: []core.ProblemsRow{
			{Key: "diagnostic:0:0:0:a", Kind: core.ProblemsRowDiagnostic},
			{Key: "diagnostic:1:0:0:a", Kind: core.ProblemsRowDiagnostic, Shows: 1},
		},
		Selected: "diagnostic:0:0:0:a", SelectedRow: &first,
	}})
	if v.selected != "diagnostic:1:0:0:a" || v.selectedRow != 1 {
		t.Fatalf("selected %q at %d, want the row the user chose", v.selected, v.selectedRow)
	}
}

// problemsTreeFixture opens a project with two files' problems on the Project tab: a.txt has an
// error and a warning, b.txt an information. The preview is on, so a click only selects.
func problemsTreeFixture(t *testing.T) (*harness, string, string) {
	t.Helper()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	a, b := filepath.Join(root, "a.txt"), filepath.Join(root, "b.txt")
	for _, file := range []string{a, b} {
		if err := os.WriteFile(file, []byte("zero\none\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	h.open(root)
	h.app.pluginDiagnostics = map[string]*plugindiag.Set{"demo": problemSet(t,
		plugindiag.Diagnostic{FileKey: a, DisplayPath: "a.txt", Line: 0, Column: 0, Severity: plugindiag.SeverityError, Message: "broken"},
		plugindiag.Diagnostic{FileKey: a, DisplayPath: "a.txt", Line: 1, Column: 0, Severity: plugindiag.SeverityWarning, Message: "unused"},
		plugindiag.Diagnostic{FileKey: b, DisplayPath: "b.txt", Line: 1, Column: 0, Severity: plugindiag.SeverityInformation, Message: "note"},
	)}
	h.app.markProblemsChanged()
	h.app.problems.project, h.app.problems.show = true, true
	openProblemsPanel(t, h)
	return h, "file:" + a, "file:" + b
}

func TestClosingAProblemsNodeHandsItTheSelectionOfADiagnosticUnderIt(t *testing.T) {
	h, a, b := problemsTreeFixture(t)
	v := &h.app.problems
	if keys := problemsRowKeys(v); len(keys) != 5 || keys[0] != a || keys[3] != b {
		t.Fatalf("rows = %v", keys)
	}
	unused := v.result.Rows[2].Key
	h.clickNamed(problemsRowNamed(t, h, unused))
	if v.selected != unused || v.selectedRow != 2 {
		t.Fatalf("selected %q at %d after a click", v.selected, v.selectedRow)
	}
	if h.app.project.docs.byPath(v.diagnostics[v.result.Rows[2].Shows].FileKey) != nil {
		t.Fatal("a click with the preview on opened the file")
	}

	h.app.toggleProblemsNode(a)
	awaitProblems(t, h)
	if keys := problemsRowKeys(v); len(keys) != 3 || v.selected != a || v.selectedRow != 0 || v.node(0).Expanded {
		t.Fatalf("rows %v, selected %q at %d after closing a.txt", keys, v.selected, v.selectedRow)
	}
	// A node's row previews its first diagnostic.
	if path, line, ok := v.selectedProblemLocation(); !ok || path != v.result.Groups[0].FileKey || line != 0 {
		t.Fatalf("node shows %q:%d (%v)", path, line, ok)
	}

	h.app.expandProblems(false)
	awaitProblems(t, h)
	if keys := problemsRowKeys(v); len(keys) != 2 || keys[0] != a || keys[1] != b {
		t.Fatalf("rows after collapse all = %v", keys)
	}
	h.app.expandProblems(true)
	awaitProblems(t, h)
	if keys := problemsRowKeys(v); len(keys) != 5 || v.selected != a {
		t.Fatalf("rows %v, selected %q after expand all", keys, v.selected)
	}
}

func TestProblemsViewOptionsGroupBySeverityAndHideASeverity(t *testing.T) {
	h, _, _ := problemsTreeFixture(t)
	v := &h.app.problems
	lang := h.app.language()
	h.clickNamed(i18n.Shared(lang, "desktop.problems.viewOptions"))
	h.clickNamed(i18n.Shared(lang, "desktop.problems.group.severity"))
	awaitProblems(t, h)
	if keys := problemsRowKeys(v); v.grouping() != core.ProblemsGroupBySeverity || len(keys) != 6 || keys[0] != "severity:1" {
		t.Fatalf("grouping %q, rows %v", v.grouping(), keys)
	}
	if !h.shows(problemsSeverityText(lang, 1)) {
		t.Fatal("the severity node is not named")
	}
	// Under a severity node, a diagnostic names its file.
	if label := h.app.problemsRowLabel(1); !strings.HasPrefix(label, "a.txt:1 ") {
		t.Fatalf("diagnostic label = %q", label)
	}

	h.clickNamed(i18n.Shared(lang, "desktop.problems.viewOptions"))
	h.clickNamed(i18n.Shared(lang, "desktop.problems.showErrors"))
	awaitProblems(t, h)
	if keys := problemsRowKeys(v); !v.hideErrors || len(keys) != 4 || keys[0] != "severity:2" || v.projectCount != 2 {
		t.Fatalf("hide errors %v, rows %v, project count %d", v.hideErrors, keys, v.projectCount)
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
	if h.app.problems.loaded || len(h.app.problems.result.Rows) != 0 || len(h.app.problems.diagnostics) != 0 {
		t.Fatalf("closing the panel kept its cached answer: %+v", h.app.problems)
	}
}

// With the preview on, a click on a diagnostic only selects it: the shared source preview shows its
// file at its line without opening an editor, and a file that cannot be read shows why.
func TestProblemsPreviewFollowsTheSelectedDiagnostic(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	root := t.TempDir()
	present := filepath.Join(root, "present.txt")
	if err := os.WriteFile(present, []byte("zero\none\ntwo\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(root, "missing.txt")
	h.open(root)
	h.app.pluginDiagnostics = map[string]*plugindiag.Set{"demo": problemSet(t,
		plugindiag.Diagnostic{FileKey: present, DisplayPath: "present.txt", Line: 2, Column: 0, Severity: plugindiag.SeverityError, Message: "on two"},
		plugindiag.Diagnostic{FileKey: missing, DisplayPath: "missing.txt", Line: 0, Column: 0, Severity: plugindiag.SeverityWarning, Message: "gone"},
	)}
	h.app.markProblemsChanged()
	h.app.problems.show, h.app.problems.project = true, true
	openProblemsPanel(t, h)

	preview := &h.app.problems.preview
	onTwo, gone := problemsDiagnosticRow(t, h, "on two"), problemsDiagnosticRow(t, h, "gone")
	h.clickNamed(problemsRowNamed(t, h, onTwo))
	awaitDocumentState(t, h, func() bool { return preview.view != nil && preview.path == present })
	if line, _ := preview.view.Caret(); line != 2 || preview.line != 3 {
		t.Fatalf("preview at line %d (asked %d), want the diagnostic's zero-based 2", line, preview.line)
	}
	if h.app.project.docs.byPath(present) != nil {
		t.Fatal("selecting a diagnostic with the preview on opened its file")
	}

	h.clickNamed(problemsRowNamed(t, h, gone))
	awaitDocumentState(t, h, func() bool { return preview.failure != nil })
	if preview.path != missing || preview.view != nil {
		t.Fatalf("preview of an unreadable file = %q, view %v", preview.path, preview.view != nil)
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
	h.app.pluginServerExited("java", server, nil)
	if _, ok := h.app.pluginServers["java"]; ok {
		t.Fatal("the exited server is still registered")
	}
	if len(h.app.pluginDiagnostics) != 0 {
		t.Fatalf("diagnostics = %v, want the exited server's list withdrawn", h.app.pluginDiagnostics)
	}
}
