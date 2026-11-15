package workbench

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

func markdownHoverResult(t *testing.T, contents string, span *core.PluginDocumentRange) json.RawMessage {
	t.Helper()
	value, err := json.Marshal(map[string]any{"hover": map[string]any{
		"contents":   contents,
		"isMarkdown": true,
		"range":      span,
	}})
	if err != nil {
		t.Fatal(err)
	}
	return value
}

// caretRectAt is the caret's rectangle with the caret at line and column of the fixture's
// document, after the view painted it there.
func (f *semanticFixture) caretRectAt(t *testing.T, line, column int) gfx.Rect {
	t.Helper()
	f.d.view.GoToNavigation(line, column, false)
	f.h.settle()
	rect, ok := f.d.view.CaretRect()
	if !ok {
		t.Fatal("the view has no caret rect")
	}
	return rect
}

func (f *semanticFixture) move(t *testing.T, x, y float32) {
	t.Helper()
	f.moveOnly(t, x, y)
	f.h.settle()
}

// moveOnly moves the pointer and paints the frame without waiting for background work, which a
// pending close of the hover keeps busy.
func (f *semanticFixture) moveOnly(t *testing.T, x, y float32) {
	t.Helper()
	if err := f.h.driver.Move(x, y); err != nil {
		t.Fatal(err)
	}
	if err := f.h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
}

// openPointerHover rests the pointer on the fixture's word "one" and answers the hover request
// with contents; it returns where the pointer rests.
func (f *semanticFixture) openPointerHover(t *testing.T, result json.RawMessage) (float32, float32) {
	t.Helper()
	rect := f.caretRectAt(t, 0, 1)
	x, y := rect.X+2, rect.Y+2
	f.move(t, x, y)
	f.waitForRequests(t, 1)
	f.deliver(t, "op-1", pluginMethodHover, result)
	if !f.h.app.semantics.hover.open {
		t.Fatal("the pointer hover did not open")
	}
	return x, y
}

func TestPointerHoverRendersMarkdownRightUnderTheRow(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.hoverDelay = -1
	x, y := f.openPointerHover(t, markdownHoverResult(t, "```java\nint one()\n```\n\n---\n\nReturns **one**.", nil))
	hover := &f.h.app.semantics.hover
	if label := hover.page.label; !strings.Contains(label, "int one()") || !strings.Contains(label, "Returns one.") {
		t.Fatalf("hover text = %q, want the rendered Markdown", label)
	}
	if !f.h.shows("int one()") || !f.h.shows("Returns") {
		t.Fatalf("hover Markdown is not painted: %v", f.h.driver.Snapshot().Labels)
	}
	if f.h.shows("```") || f.h.shows("**") || strings.Contains(hover.page.label, "**") {
		t.Fatalf("hover shows Markdown source: %q", hover.page.label)
	}
	lineHeight := f.d.view.LineHeight()
	_, fraction, ok := f.d.view.LineRowAt(y)
	if !ok {
		t.Fatal("the pointer is not on a row")
	}
	rowBottom := y - fraction*lineHeight + lineHeight
	if gap := hover.rect.Y - rowBottom; gap < -0.5 || gap > 0.5 {
		t.Fatalf("popup top = %v, want the hovered row's bottom %v", hover.rect.Y, rowBottom)
	}
	if hover.rect.X > x || hover.rect.X+hover.rect.Width < x {
		t.Fatalf("popup %+v does not start under the pointer x %v", hover.rect, x)
	}
	if hover.rect.Width > semanticHoverMaxWidth+2*semanticHoverPadX {
		t.Fatalf("popup width %v exceeds the maximum", hover.rect.Width)
	}
}

func TestPointerHoverStaysOnItsSymbolAndPopup(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.hoverDelay = -1
	// Closing at once shows that only leaving both the symbol and the popup closes it.
	f.h.app.semantics.hoverHideDelay = -1
	second := f.caretRectAt(t, 0, 2)
	_, y := f.openPointerHover(t, hoverResult(t, "int one()"))
	hover := &f.h.app.semantics.hover
	if hover.start != 0 || hover.end != 3 {
		t.Fatalf("hovered symbol = %d..%d, want the word one at 0..3", hover.start, hover.end)
	}
	f.move(t, second.X-1, y)
	if !hover.open || f.kernel.requestCount() != 1 {
		t.Fatalf("moving along the symbol: open %v, requests %d", hover.open, f.kernel.requestCount())
	}
	f.move(t, hover.rect.X+hover.rect.Width/2, hover.rect.Y+hover.rect.Height/2)
	if !hover.open || f.kernel.requestCount() != 1 {
		t.Fatalf("moving into the popup: open %v, requests %d", hover.open, f.kernel.requestCount())
	}
	f.move(t, second.X, hover.rect.Y+hover.rect.Height+20)
	if hover.open {
		t.Fatal("leaving the symbol and the popup kept the hover")
	}
}

func TestPointerHoverWaitsBeforeClosingAndThePointerComingBackKeepsIt(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.hoverDelay = -1
	// The close waits far longer than the test runs, so only the pointer's return ends it.
	f.h.app.semantics.hoverHideDelay = time.Hour
	f.openPointerHover(t, hoverResult(t, "int one()"))
	hover := &f.h.app.semantics.hover
	popup := hover.rect
	// On its way the pointer crosses another place of the editor, which arms a new hover.
	f.moveOnly(t, popup.X+2, popup.Y+popup.Height+20)
	f.waitForRequests(t, 2)
	if !hover.open || f.h.app.semantics.hideCancel == nil {
		t.Fatalf("leaving the symbol closed the hover at once: open %v", hover.open)
	}
	f.moveOnly(t, popup.X+popup.Width/2, popup.Y+popup.Height/2)
	if !hover.open || f.h.app.semantics.hideCancel != nil {
		t.Fatalf("the pointer in the popup did not keep it: open %v", hover.open)
	}
	// The hover armed on the way was dropped, so its late answer cannot replace this one.
	f.deliver(t, "op-2", pluginMethodHover, hoverResult(t, "another symbol"))
	if hover.contents != "int one()" {
		t.Fatalf("hover contents = %q, want the kept hover", hover.contents)
	}
}

func TestHoverColorsItsCodeWithTheEditorGrammar(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.hoverDelay = -1
	code := "int one() { return 1; }"
	f.openPointerHover(t, markdownHoverResult(t, "```java\n"+code+"\n```", nil))
	page := f.h.app.semantics.hover.page
	awaitDocumentState(t, f.h, func() bool { return page.tokens != nil })
	if runs := f.h.app.hoverCodeRuns(page, "java", code, nil); len(runs) == 0 {
		t.Fatalf("no colored runs for %q", code)
	}
	if runs := f.h.app.hoverCodeRuns(page, "", "plain words", nil); len(runs) != 0 {
		t.Fatalf("a line the page has no tokens for was colored: %+v", runs)
	}
}

func TestHoverSpanPrefersTheAnswersRangeOnTheLine(t *testing.T) {
	f := newSemanticFixture(t)
	span := &core.PluginDocumentRange{
		Start: core.PluginDocumentPosition{Line: 0, UTF16Column: 1},
		End:   core.PluginDocumentPosition{Line: 0, UTF16Column: 2},
	}
	if start, end := hoverSpan(f.d, 0, 1, span); start != 1 || end != 2 {
		t.Fatalf("span = %d..%d, want the answer's range 1..2", start, end)
	}
	elsewhere := &core.PluginDocumentRange{
		Start: core.PluginDocumentPosition{Line: 3, UTF16Column: 0},
		End:   core.PluginDocumentPosition{Line: 3, UTF16Column: 4},
	}
	if start, end := hoverSpan(f.d, 0, 1, elsewhere); start != 0 || end != 3 {
		t.Fatalf("span = %d..%d, want the word one at 0..3", start, end)
	}
}

func TestHoverWordSpanCountsUTF16Columns(t *testing.T) {
	text := "a 😀 foo_bar(x)"
	cases := []struct {
		column, start, end int
	}{
		{0, 0, 1},
		{1, 0, 1},
		{2, 2, 2},
		{5, 5, 12},
		{12, 5, 12},
		{13, 13, 14},
		{15, 15, 15},
	}
	for _, c := range cases {
		if start, end := hoverWordSpan(text, c.column); start != c.start || end != c.end {
			t.Errorf("hoverWordSpan(%q, %d) = %d..%d, want %d..%d", text, c.column, start, end, c.start, c.end)
		}
	}
}

func TestHoverMarkdownFencesPlainTextAndSpreadsTabs(t *testing.T) {
	if got := hoverMarkdown("a\tb\r\nc", true); got != "a   b\nc" {
		t.Fatalf("markdown = %q", got)
	}
	if got := hoverMarkdown("x ``` y\n", false); got != "````\nx ``` y\n````" {
		t.Fatalf("plain = %q, want a fence longer than the text's backticks", got)
	}
	if got := hoverMarkdown("int add()", false); got != "```\nint add()\n```" {
		t.Fatalf("plain = %q", got)
	}
}
