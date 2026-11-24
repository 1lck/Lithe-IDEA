package workbench

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
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

// hoverContentsCase is a normalized result from the linked Core's protocol fixture.
// Core tests verify the raw server response; these cases verify its desktop presentation.
type hoverContentsCase struct {
	Name         string          `json:"name"`
	Expected     json.RawMessage `json:"expected"`
	CodeLanguage string          `json:"codeLanguage"`
	CodeLine     string          `json:"codeLine"`
}

func hoverContentsCases(t *testing.T) []hoverContentsCase {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture("lsp/hover-contents-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []hoverContentsCase `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("Core hover fixture has no cases")
	}
	return fixture.Cases
}

func (c hoverContentsCase) result(t *testing.T) json.RawMessage {
	t.Helper()
	result, err := json.Marshal(map[string]json.RawMessage{"hover": c.Expected})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestHoverContentsContractRendersLanguageCodeBlocks(t *testing.T) {
	for _, c := range hoverContentsCases(t) {
		t.Run(c.Name, func(t *testing.T) {
			f := newSemanticFixture(t)
			f.h.app.semantics.hoverDelay = -1
			if string(c.Expected) == "null" {
				rect := f.caretRectAt(t, 0, 1)
				f.move(t, rect.X+2, rect.Y+2)
				f.waitForRequests(t, 1)
				f.deliver(t, "op-1", pluginMethodHover, c.result(t))
				if f.h.app.semantics.hover.open {
					t.Fatal("an empty hover opened a popup")
				}
				return
			}
			f.openPointerHover(t, c.result(t))
			page := f.h.app.semantics.hover.page
			if c.CodeLanguage == "" {
				if c.Name == "markup-plaintext" && !strings.Contains(page.label, "literal *text* and ```rust") {
					t.Fatalf("plaintext was interpreted as Markdown: %q", page.label)
				}
				return
			}
			// The document is Java, so a Rust block must use its own declared language.
			awaitDocumentState(t, f.h, func() bool { return page.tokens != nil })
			if !strings.Contains(page.label, c.CodeLine) {
				t.Fatalf("hover does not render its code: %q", page.label)
			}
			if runs := f.h.app.hoverCodeRuns(page, c.CodeLanguage, c.CodeLine, nil); len(runs) == 0 {
				t.Fatalf("no %s colors for %q", c.CodeLanguage, c.CodeLine)
			}
			if runs := f.h.app.hoverCodeRuns(page, f.d.languageID, c.CodeLine, nil); len(runs) != 0 {
				t.Fatalf("block used the document language instead: %+v", runs)
			}
		})
	}
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

// Native views cover the page's own layer. Editor popups must therefore use
// an overlay band as well as being declared after the workbench.
func TestPointerHoverPaintsAboveTheNativeContentLayer(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.hoverDelay = -1
	f.openPointerHover(t, hoverResult(t, "Hover over native content"))
	var editorLayer uint16
	foundEditor, foundHover := false, false
	for _, hit := range f.h.driver.Snapshot().Hits {
		if hit.ID == f.d.hit {
			editorLayer, foundEditor = hit.Layer, true
		}
	}
	for _, hit := range f.h.driver.Snapshot().Hits {
		if hit.Role == gfx.RoleMenu && hit.Bounds == f.h.app.semantics.hover.rect {
			foundHover = true
			if hit.Layer <= editorLayer {
				t.Fatalf("hover layer %d does not stand above native content on editor layer %d", hit.Layer, editorLayer)
			}
		}
	}
	if !foundEditor || !foundHover {
		t.Fatalf("editor present: %v, hover present: %v", foundEditor, foundHover)
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

// documentBounds is where the fixture's document control is in the window.
func (f *semanticFixture) documentBounds(t *testing.T) gfx.Rect {
	t.Helper()
	for _, hit := range f.h.driver.Snapshot().Hits {
		if hit.ID == f.d.hit && !hit.IsLabel {
			return hit.Bounds
		}
	}
	t.Fatal("the document control is not in the frame")
	return gfx.Rect{}
}

// Leaving the text forgets the character the pointer rested on, so resting on it again asks for
// the hover again instead of waiting for an answer that was already shown or dropped (#1995).
func TestPointerHoverAsksAgainOnTheSameCharacterAfterLeavingTheText(t *testing.T) {
	cases := []struct {
		name  string
		leave func(t *testing.T, f *semanticFixture, x, y float32)
	}{
		{"escape", func(t *testing.T, f *semanticFixture, _, _ float32) {
			if err := f.h.driver.Key(gfx.KeyEscape, 0); err != nil {
				t.Fatal(err)
			}
			f.h.settle()
		}},
		{"out of the window", func(t *testing.T, f *semanticFixture, _, _ float32) {
			if err := f.h.driver.Leave(); err != nil {
				t.Fatal(err)
			}
			f.h.settle()
		}},
		{"over the tab bar", func(t *testing.T, f *semanticFixture, x, _ float32) {
			f.move(t, x, f.documentBounds(t).Y-4)
		}},
		{"scroll", func(t *testing.T, f *semanticFixture, x, y float32) {
			if err := f.h.driver.Scroll(gfx.ScrollEvent{X: x, Y: y, DeltaY: 1}); err != nil {
				t.Fatal(err)
			}
			f.h.settle()
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newSemanticFixture(t)
			f.h.app.semantics.hoverDelay = -1
			f.h.app.semantics.hoverHideDelay = -1
			x, y := f.openPointerHover(t, hoverResult(t, "int one()"))
			c.leave(t, f, x, y)
			if f.h.app.semantics.hover.open {
				t.Fatal("leaving the text kept the hover")
			}
			f.move(t, x+1, y)
			f.waitForRequests(t, 2)
			f.deliver(t, "op-2", pluginMethodHover, hoverResult(t, "int one()"))
			if !f.h.app.semantics.hover.open {
				t.Fatal("the hover asked again did not open")
			}
		})
	}
}

// The pointer leaving the text before the wait for its hover ends drops the wait, so no popup
// opens where the pointer no longer is.
func TestPointerHoverLeavingTheTextDropsTheWait(t *testing.T) {
	f := newSemanticFixture(t)
	// The wait outlasts the test, so only leaving the text ends it.
	f.h.app.semantics.hoverDelay = time.Hour
	rect := f.caretRectAt(t, 0, 1)
	x, y := rect.X+2, rect.Y+2
	f.moveOnly(t, x, y)
	if candidate := f.h.app.semantics.candidate; !candidate.active || candidate.cancel == nil {
		t.Fatalf("resting on the text armed no hover: %+v", candidate)
	}
	f.moveOnly(t, x, f.documentBounds(t).Y-4)
	if candidate := f.h.app.semantics.candidate; candidate.active || candidate.cancel != nil {
		t.Fatalf("leaving the text kept the wait: %+v", candidate)
	}
	// settle returns only once the dropped wait has ended.
	f.h.settle()
	if f.kernel.requestCount() != 0 {
		t.Fatalf("requests = %d, want none", f.kernel.requestCount())
	}
}

// The pointer moving within a character the server had nothing to say about does not ask again.
func TestPointerHoverDoesNotAskAgainWithinACharacterWithoutHover(t *testing.T) {
	f := newSemanticFixture(t)
	f.h.app.semantics.hoverDelay = -1
	rect := f.caretRectAt(t, 0, 1)
	x, y := rect.X+2, rect.Y+2
	f.move(t, x, y)
	f.waitForRequests(t, 1)
	f.deliver(t, "op-1", pluginMethodHover, json.RawMessage(`{"hover":null}`))
	f.move(t, x+1, y)
	if f.h.app.semantics.hover.open || f.kernel.requestCount() != 1 {
		t.Fatalf("moving within the character: open %v, requests %d", f.h.app.semantics.hover.open, f.kernel.requestCount())
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
