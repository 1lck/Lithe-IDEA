package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/textview"
	"github.com/vivaui/viva/gfx"
)

// showRunConsole shows a run whose console holds text, in the Run window.
func showRunConsole(t *testing.T, text string) (*harness, *runEntry) {
	t.Helper()
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	p := h.app.project
	run := &runEntry{id: "run-1", label: "Serve", output: newOutputBuffer(runOutputMaxLines, runOutputBytes)}
	chunk, err := newOutputDecoder(h.app.kernel).decode(text)
	if err != nil {
		t.Fatal(err)
	}
	run.output.apply(chunk)
	p.build.runs = append(p.build.runs, run)
	p.build.view = run.id
	if !h.app.chrome.isOpen(catalogIndex[itemRun]) {
		h.app.reduceChrome(core.SetChromeOpen(itemRun, true))
	}
	h.settle()
	return h, run
}

// consolePoint is where the console of run drew byte at of its line n, counting from its
// first line.
func consolePoint(t *testing.T, run *runEntry, n, at int) gfx.Point {
	t.Helper()
	point, ok := run.console.PointOf(textview.Point{Line: run.output.start + n, Byte: at})
	if !ok {
		t.Fatalf("line %d is not on screen", n)
	}
	return point
}

// copyShortcut presses Primary+C and returns what the clipboard holds after it.
func (h *harness) copyShortcut() string {
	h.t.Helper()
	h.driver.SetClipboard("")
	if _, err := h.driver.ShortcutChord(primaryModifier(), 'c'); err != nil {
		h.t.Fatal(err)
	}
	h.settle()
	return h.driver.Clipboard()
}

const stackTrace = "Exception in thread \"main\" java.lang.IllegalStateException: boom\n" +
	"\tat demo.Main.run(Main.java:12)\n" +
	"\tat demo.Main.main(Main.java:5)\n"

// A drag across the lines of the Run console selects them, and Primary+C copies them, so a
// stack trace pastes as it was printed (#2073).
func TestRunConsoleDragSelectsAcrossLinesAndCopies(t *testing.T) {
	h, run := showRunConsole(t, stackTrace)
	from := consolePoint(t, run, 0, len("Exception in thread \"main\" "))
	to := consolePoint(t, run, 2, len("\tat demo.Main.main"))
	h.drag(from, to)
	h.settle()
	want := "java.lang.IllegalStateException: boom\n\tat demo.Main.run(Main.java:12)\n\tat demo.Main.main"
	if got := run.console.Text(); got != want {
		t.Fatalf("the drag selected %q, want %q", got, want)
	}
	if got := h.copyShortcut(); got != want {
		t.Fatalf("Primary+C copied %q, want %q", got, want)
	}
	// Escape drops the selection, as in the editor.
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if run.console.Has() {
		t.Fatalf("Escape left %q selected", run.console.Text())
	}
}

// A double click selects the word under it, a triple click the whole line with its newline,
// as IntelliJ IDEA's console does.
func TestRunConsoleDoubleClickSelectsAWordAndTripleClickALine(t *testing.T) {
	h, run := showRunConsole(t, stackTrace)
	at := consolePoint(t, run, 0, len("Exception in thread \"main\" java.lang.Ill"))
	if err := h.driver.DoubleClick(at.X, at.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if got := run.console.Text(); got != "IllegalStateException" {
		t.Fatalf("the double click selected %q, want the word", got)
	}
	at = consolePoint(t, run, 1, 4)
	if err := h.driver.ClickCount(at.X, at.Y, 3); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if got, want := h.copyShortcut(), "\tat demo.Main.run(Main.java:12)\n"; got != want {
		t.Fatalf("the triple click copied %q, want the line %q", got, want)
	}
}

// Shift with a click extends the selection from where the last click put it, and Primary+A
// selects the whole console.
func TestRunConsoleShiftClickExtendsAndSelectAllTakesEverything(t *testing.T) {
	h, run := showRunConsole(t, "first line\nsecond line\nthird line\n")
	start := consolePoint(t, run, 0, len("first "))
	h.click(start)
	if run.console.Has() {
		t.Fatalf("a single click selected %q", run.console.Text())
	}
	end := consolePoint(t, run, 1, len("second"))
	if err := h.driver.KeyDown(gfx.KeyShiftLeft, ""); err != nil {
		t.Fatal(err)
	}
	h.click(end)
	if err := h.driver.KeyUp(gfx.KeyShiftLeft, ""); err != nil {
		t.Fatal(err)
	}
	if got, want := h.copyShortcut(), "line\nsecond"; got != want {
		t.Fatalf("Shift-click copied %q, want %q", got, want)
	}
	if _, err := h.driver.ShortcutChord(primaryModifier(), 'a'); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if got, want := h.copyShortcut(), "first line\nsecond line\nthird line"; got != want {
		t.Fatalf("Primary+A then Primary+C copied %q, want %q", got, want)
	}
}

// The console menu's Copy takes the selection when there is one, and its Select All selects
// every line.
func TestRunConsoleMenuCopiesTheSelectionAndSelectsAll(t *testing.T) {
	h, run := showRunConsole(t, "first line\nsecond line\n")
	h.drag(consolePoint(t, run, 0, len("first ")), consolePoint(t, run, 1, len("second")))
	h.settle()
	line, ok := run.console.RowRect(run.output.start + 1)
	if !ok {
		t.Fatal("the second line is not on screen")
	}
	h.driver.SetClipboard("")
	h.rightClickAt(line)
	h.click(center(h.popupHit(h.shared("menu.copy"))))
	if got, want := h.driver.Clipboard(), "line\nsecond"; got != want {
		t.Fatalf("Copy put %q on the clipboard, want the selection %q", got, want)
	}
	h.rightClickAt(line)
	h.click(center(h.popupHit(h.shared("menu.selectAll"))))
	if got, want := run.console.Text(), "first line\nsecond line"; got != want {
		t.Fatalf("Select All selected %q, want %q", got, want)
	}
}

// showFetchInConsole opens a repository's Git console and puts a fetch in it, with Core's
// presentation of it: a header, a line and a closed fold of progress lines.
func showFetchInConsole(t *testing.T) (*harness, *consoleView) {
	t.Helper()
	h := newHarness(t, gitKernel{core.NewClient()})
	h.openConsole(t, newTestRepository(t))
	v := &h.app.consoleView
	record, presented := consoleFetch()
	presented.search, presented.display = v.searchFor, v.display
	v.snapshot.Records = []core.GitConsoleRecord{record}
	v.presented[record.ID] = presented
	v.dirty = true
	h.app.invalidator.Invalidate()
	h.settle()
	if len(v.rows) != 3 || v.rows[1].text != "From origin" {
		t.Fatalf("the console's rows are %+v, want the fetch's header, line and fold", v.rows)
	}
	return h, v
}

// gitConsolePoint is where the Git console drew byte at of its row n.
func gitConsolePoint(t *testing.T, v *consoleView, n, at int) gfx.Point {
	t.Helper()
	point, ok := v.text.PointOf(textview.Point{Line: n, Byte: at})
	if !ok {
		t.Fatalf("row %d is not on screen", n)
	}
	return point
}

// The Git console is read-only text as the Run console is: a drag across its rows selects
// them and Primary+C copies them, the menu's Copy takes the row right-clicked when nothing is
// selected and its Select All every row, without the toggles after them, and a fold's toggle
// still opens it (#2082).
func TestGitConsoleSelectsAndCopiesItsRows(t *testing.T) {
	h, v := showFetchInConsole(t)
	toggle := h.app.text.Console.ExpandLines(3)

	h.drag(gitConsolePoint(t, v, 1, len("From ")), gitConsolePoint(t, v, 2, len("Receiving")))
	h.settle()
	if got, want := h.copyShortcut(), "origin\nReceiving"; got != want {
		t.Fatalf("the drag then Primary+C copied %q, want %q", got, want)
	}
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if v.text.Has() {
		t.Fatalf("Escape left %q selected", v.text.Text())
	}

	line, ok := v.text.RowRect(1)
	if !ok {
		t.Fatal("the line row is not on screen")
	}
	h.driver.SetClipboard("")
	h.rightClickAt(line)
	h.click(center(h.popupHit(h.shared("menu.copy"))))
	if got := h.driver.Clipboard(); got != "From origin" {
		t.Fatalf("Copy with nothing selected put %q on the clipboard, want the row", got)
	}
	h.rightClickAt(line)
	h.click(center(h.popupHit(h.shared("menu.selectAll"))))
	if got, want := v.text.Text(), v.rows[0].text+"\nFrom origin\nReceiving 100%"; got != want {
		t.Fatalf("Select All selected %q, want %q", got, want)
	}

	h.clickNamed(toggle)
	h.settle()
	if !consoleHasRow(v, "Receiving 10%") {
		t.Fatalf("the fold's toggle %q left the rows %+v", toggle, v.rows)
	}
}
