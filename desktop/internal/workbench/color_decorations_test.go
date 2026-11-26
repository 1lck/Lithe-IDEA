package workbench

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/gfx"
)

func canvasHasForeground(canvas *gfx.Canvas, color gfx.Color) bool {
	for _, label := range canvas.Texts() {
		for _, run := range canvas.TextRuns(label) {
			if run.Color == color {
				return true
			}
		}
	}
	return false
}

// viewHasForeground reports whether a painted frame of view draws text in color.
func viewHasForeground(view *editorview.View, color uint32) bool {
	canvas := new(gfx.Canvas)
	view.Paint(canvas, gfx.Rect{Width: 600, Height: 200}, editorview.Look{})
	return canvasHasForeground(canvas, gfx.RGB24(color))
}

func viewTextInForeground(view *editorview.View, color uint32) string {
	canvas := new(gfx.Canvas)
	view.Paint(canvas, gfx.Rect{Width: 600, Height: 200}, editorview.Look{})
	var text strings.Builder
	for _, label := range canvas.Texts() {
		start := 0
		for _, run := range canvas.TextRuns(label) {
			end := start + int(run.Bytes)
			if run.Color == gfx.RGB24(color) {
				text.WriteString(label.Value[start:end])
			}
			start = end
		}
	}
	return text.String()
}

func TestIndentGuideScopesUseOnlyMatchedStructuralBraces(t *testing.T) {
	grammar := syntax.NewRegistry().Syntax("go")
	source := `package sample
func use() {
    _ = "{literal}"
    // {comment}
    if (true) {
        _ = []int{1}
    }
}
`
	rainbow, err := resolveBuiltinRainbow(t.Context(), rope.New([]byte(source)), grammar, false, false)
	if err != nil {
		t.Fatal(err)
	}
	want := []editorview.IndentGuideScope{
		{Open: strings.Index(source, "() {") + len("() "), Close: strings.LastIndexByte(source, '}')},
		{Open: strings.Index(source, "(true) {") + len("(true) "), Close: strings.Index(source, "\n    }") + len("\n    ")},
		{Open: strings.Index(source, "{1}"), Close: strings.Index(source, "{1}") + 2},
	}
	if !slices.Equal(rainbow.indentScopes, want) {
		t.Fatalf("indent guide scopes = %+v, want %+v", rainbow.indentScopes, want)
	}
	withoutBraces, err := resolveBuiltinRainbow(t.Context(), rope.New([]byte("package sample\nvar x = (1)")), grammar, false, false)
	if err != nil || withoutBraces.indentScopes == nil || len(withoutBraces.indentScopes) != 0 {
		t.Fatalf("parentheses-only analysis = %+v, error %v, want a known empty result", withoutBraces.indentScopes, err)
	}
}

func TestBracketPairHighlightsEitherEndWithRainbowOff(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pairs.go")
	source := "package sample\nfunc use() {\n    if true {\n        println(\"}\")\n        call(foo())\n    }\n}\n"
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), lightThemeStore(t), "test")
	options.OpenFile = path
	h := newHarnessWithOptions(t, options)
	h.app.openStandaloneFile(path)
	h.await("standalone editor opened", func() bool {
		return h.app.project != nil && h.app.project.docs.byPath(path) != nil
	})
	p := h.app.project
	d := p.docs.byPath(path)
	if h.app.editorPreferences.RainbowBrackets {
		t.Fatal("rainbow foreground preference should start disabled")
	}

	canvas := new(gfx.Canvas)
	area := gfx.Rect{Width: 600, Height: 260}
	foreground := gfx.RGB24(0x112233)
	underline := foreground
	underline.Alpha *= 0.55
	paint := func() []gfx.Rect {
		canvas.Reset()
		d.view.Paint(canvas, area, editorview.Look{Foreground: foreground})
		var rects []gfx.Rect
		for _, rect := range canvas.Rectangles() {
			if rect.Color == underline {
				rects = append(rects, rect.Bounds)
			}
		}
		return rects
	}
	gestureAt := func(offset int, press, release float32) {
		t.Helper()
		d.view.SetSelection(offset, offset)
		paint()
		caret, ok := d.view.CaretRect()
		if !ok {
			t.Fatalf("could not locate offset %d", offset)
		}
		result := h.app.documentPointer(p, d, gfx.PointerEvent{
			Target: d.hit, Kind: gfx.PointerDown, Button: gfx.PointerButtonPrimary,
			X: caret.X + d.view.CellWidth()*press, Y: caret.Y + caret.Height/2,
		})
		if press != release {
			h.app.documentPointer(p, d, gfx.PointerEvent{
				Target: d.hit, Kind: gfx.PointerMove,
				X: caret.X + d.view.CellWidth()*release, Y: caret.Y + caret.Height/2,
			})
		}
		h.app.documentPointer(p, d, gfx.PointerEvent{
			Target: d.hit, Kind: gfx.PointerUp, Button: gfx.PointerButtonPrimary,
			X: caret.X + d.view.CellWidth()*release, Y: caret.Y + caret.Height/2,
		})
		if !result.Handled {
			t.Fatalf("click on offset %d was not handled", offset)
		}
	}
	click := func(offset int) { gestureAt(offset, 0.125, 0.125) }
	opener := strings.Index(source, "true {") + len("true ")
	closer := strings.Index(source, "\n    }") + len("\n    ")
	click(opener)
	h.await("the matching cross-line pair painted", func() bool { return len(paint()) == 2 })
	expected := paint()
	if expected[0].Y >= expected[1].Y {
		t.Fatalf("pair should paint on different lines: %v", expected)
	}
	click(closer)
	if got := paint(); !slices.Equal(got, expected) {
		t.Fatalf("clicking the closer painted %v, want the same pair %v", got, expected)
	}
	innerClose := strings.Index(source, "())") + 1
	click(innerClose)
	inner := paint()
	if len(inner) != 2 {
		t.Fatalf("clicking the inner closer painted %v, want one complete pair", inner)
	}
	gestureAt(innerClose, 0.75, 0.75)
	if got := paint(); !slices.Equal(got, inner) {
		t.Fatalf("right half of the inner closer painted %v, want the clicked pair %v", got, inner)
	}
	gestureAt(innerClose, 0.75, 0.875)
	if start, end := d.view.Selection(); start != innerClose+1 || end != start {
		t.Fatalf("small mouse movement changed selection to %d..%d, want caret at %d", start, end, innerClose+1)
	}
	if got := paint(); !slices.Equal(got, inner) {
		t.Fatalf("small mouse movement painted %v, want the clicked pair %v", got, inner)
	}
	gestureAt(innerClose, 0.75, -0.125)
	if start, end := d.view.Selection(); start != innerClose || end != innerClose+1 {
		t.Fatalf("drag selected %d..%d, want the inner closer at %d..%d", start, end, innerClose, innerClose+1)
	}
	if got := paint(); len(got) != 0 {
		t.Fatalf("drag selection left the bracket pair highlighted: %v", got)
	}
	click(strings.Index(source, "\"}\"") + 1)
	if got := paint(); len(got) != 0 {
		t.Fatalf("brace inside string highlighted %v", got)
	}
	click(opener)
	target := strings.Index(source, "sample")
	d.find.matches = []core.EditorByteRange{{Start: target, End: target + len("sample")}}
	h.app.stepEditorFind(d, 0)
	if got := paint(); len(got) != 0 {
		t.Fatalf("editor find left a stale bracket highlight %v", got)
	}
	d.view.SetSelection(closer, closer)
	if got := paint(); !slices.Equal(got, expected) {
		t.Fatalf("programmatic movement to the closer painted %v, want %v", got, expected)
	}
	if err := d.view.ApplyEdits([]editorview.TextEdit{{
		Range: editorview.Range{Start: closer, End: closer + 1},
	}}); err != nil {
		t.Fatal(err)
	}
	if got := paint(); len(got) != 0 {
		t.Fatalf("removed delimiter left a stale highlight %v", got)
	}
}

func TestBuiltInRainbowVariablesShareColorByNameWithoutPluginServices(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rainbow.go")
	source := "package sample\nfunc use(value int) int {\n    local := value + 1\n    return local + value\n}\n"
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	enabled := true
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeLight, EditorPreferences: core.EditorStoredPreferences{
		RainbowVariables:   &enabled,
		RainbowLightColors: []string{"#ABCDEF", "#654321", "#4729AD", "#DD7831", "#2879BD", "#D23878"},
	}}); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), prefs, "test")
	options.OpenFile = path
	h := newHarnessWithOptions(t, options)
	h.app.openStandaloneFile(path)
	h.await("standalone editor opened", func() bool {
		return h.app.project != nil && h.app.project.docs.byPath(path) != nil
	})
	d := h.app.project.docs.byPath(path)
	if h.app.plugins != nil {
		t.Fatal("standalone editor assembled a plugin service")
	}
	h.await("rainbow variables applied", func() bool {
		return viewTextInForeground(d.view, 0xDD7831) != ""
	})
	if got := viewTextInForeground(d.view, 0xDD7831); got != "valuevaluevalue" {
		t.Errorf("colored text for value = %q", got)
	}
	if got := viewTextInForeground(d.view, 0xD23878); got != "locallocal" {
		t.Errorf("colored text for local = %q", got)
	}

	h.app.editorPreferences.RainbowBrackets = true
	h.app.refreshBuiltinRainbowColors()
	h.await("variables and brackets applied together", func() bool {
		return strings.Contains(viewTextInForeground(d.view, 0xABCDEF), "}")
	})
	if got := viewTextInForeground(d.view, 0xDD7831); got != "valuevaluevalue" {
		t.Errorf("brackets changed the variable colors: %q", got)
	}
	h.app.editorPreferences.RainbowVariables = false
	h.app.refreshBuiltinRainbowColors()
	h.await("brackets reapplied without variables", func() bool {
		return strings.Contains(viewTextInForeground(d.view, 0xABCDEF), "}")
	})
	if got := viewTextInForeground(d.view, 0xDD7831); got != "" {
		t.Errorf("variables still colored after disabling: %q", got)
	}
}

func TestBuiltInRainbowBracketsWithoutPluginServices(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rainbow.go")
	source := "package sample\nvar value = len([]int{1})\n"
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	enabled := true
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeLight, EditorPreferences: core.EditorStoredPreferences{
		RainbowBrackets:    &enabled,
		RainbowLightColors: []string{"#ABCDEF", "#123456"},
	}}); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), prefs, "test")
	options.OpenFile = path
	h := newHarnessWithOptions(t, options)
	h.app.openStandaloneFile(path)
	h.await("standalone editor opened", func() bool {
		return h.app.project != nil && h.app.project.docs.byPath(path) != nil
	})
	d := h.app.project.docs.byPath(path)
	if h.app.plugins != nil {
		t.Fatal("standalone editor assembled a plugin service")
	}
	h.await("configured bracket colors", func() bool {
		return viewHasForeground(d.view, 0xABCDEF) && viewHasForeground(d.view, 0x123456)
	})

	// A changed configured palette takes effect on the already-open document.
	h.app.editorPreferences.RainbowLightColors = []string{"#DD7831"}
	h.app.refreshBuiltinRainbowColors()
	h.await("updated bracket palette", func() bool { return viewHasForeground(d.view, 0xDD7831) })

	// Remove both bracket groups, then add nesting. Standalone typing must request fresh colors.
	if err := d.view.ApplyEdits([]editorview.TextEdit{{
		Range: editorview.Range{Start: 0, End: d.view.TextSnapshot().Len()}, Text: "package sample\n",
	}}); err != nil {
		t.Fatal(err)
	}
	if err := d.view.ApplyEdits([]editorview.TextEdit{{
		Range: editorview.Range{}, Text: source,
	}}); err != nil {
		t.Fatal(err)
	}
	h.await("bracket colors refreshed after typing", func() bool { return viewHasForeground(d.view, 0xDD7831) })

	h.app.editorPreferences.RainbowBrackets = false
	h.app.refreshBuiltinRainbowColors()
	if viewHasForeground(d.view, 0xDD7831) {
		t.Fatal("disabling rainbow brackets left its old overlay visible")
	}
}

// Typing must not make a rainbow flicker: the colors the view moved with the edit stay while the
// pause before the next request restarts, the edit looks no provider up again, and only the
// answer of the latest request replaces them. A change of the color providers looks them up again
// at once and drops what an unserved document showed. The pause is an hour, so the timer is only
// ever stopped, never fired, and the test never waits on the clock.
func TestColorDecorationEditKeepsMovedColorsUntilLatestAnswer(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	p := &project{ctx: ctx}
	view := editorview.New(editorview.Config{Content: editorview.Prepare([]byte("(a) [b]"))})
	t.Cleanup(view.Close)
	d := &document{id: 1, path: "/work/sample.src", languageID: "sample", view: view}
	p.docs.list = []*document{d}
	a := &App{project: p}
	// The providers were looked up when the document opened. No plugin service is attached, so a
	// second lookup would find no provider and clear the colors.
	state := &documentColorDecorations{path: d.path, language: d.languageID, known: true, provided: true}
	a.editor.colorDecorations.docs = map[int]*documentColorDecorations{d.id: state}
	t.Cleanup(func() { a.dropColorDecorations(d) })
	view.SetPreparedColorDecorations(editorview.PrepareColorDecorations(view.TextSnapshot(), []editorview.ColorDecoration{
		{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 1, Light: "#C00050", Dark: "#C00050"},
	}))

	view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: 0}, Text: "x"}})
	a.scheduleColorDecorations(p, d, time.Hour)
	first, stale := state.timer, state.generation
	if first == nil || !state.provided {
		t.Fatalf("the edit should restart the pause from the cached lookup: timer %v, provided %t", first, state.provided)
	}
	if !viewHasForeground(view, 0xC00050) {
		t.Fatal("the edit cleared the colors it should have moved")
	}
	a.scheduleColorDecorations(p, d, time.Hour)
	if first.Stop() {
		t.Fatal("the next keystroke left the earlier pause running")
	}
	answer := editorview.PrepareColorDecorations(view.TextSnapshot(), []editorview.ColorDecoration{
		{StartLine: 0, StartCharacter: 1, EndLine: 0, EndCharacter: 2, Light: "#0050C0", Dark: "#0050C0"},
	})
	a.finishColorDecorations(p, d, state, stale, view, view.Revision(), answer, nil)
	if viewHasForeground(view, 0x0050C0) || !viewHasForeground(view, 0xC00050) {
		t.Fatal("an answer to an overtaken request replaced the colors")
	}
	a.finishColorDecorations(p, d, state, state.generation, view, view.Revision(), answer, nil)
	if !viewHasForeground(view, 0x0050C0) || viewHasForeground(view, 0xC00050) {
		t.Fatal("the latest answer did not replace the moved colors")
	}

	a.colorProvidersChanged(p)
	if !state.known || state.provided || state.timer != nil || viewHasForeground(view, 0x0050C0) {
		t.Fatalf("a provider change should look the providers up again and clear an unserved document: known %t, provided %t", state.known, state.provided)
	}
}

// A valid worker result may already be queued when an edit or provider withdrawal wins the
// next window turn. Reapplying that result must never resurrect its old range positions.
func TestColorDecorationWorkerResultRejectsEditWithdrawalAndClosedDocument(t *testing.T) {
	for _, transition := range []string{"current", "edit", "overtaken", "withdrawal", "replacement", "closed"} {
		t.Run(transition, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			p := &project{ctx: ctx}
			view := editorview.New(editorview.Config{Content: editorview.Prepare([]byte("first second"))})
			t.Cleanup(view.Close)
			d := &document{id: 1, view: view}
			p.docs.list = []*document{d}
			a := &App{project: p}
			request := &documentColorDecorations{cancel: cancel}
			a.editor.colorDecorations.docs = map[int]*documentColorDecorations{1: request}
			generation, revision := request.generation, view.Revision()
			prepared := editorview.PrepareColorDecorations(view.TextSnapshot(), []editorview.ColorDecoration{{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 5, Light: "#C00050", Dark: "#FF80B0"}})
			switch transition {
			case "edit":
				view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: 0}, Text: "x"}})
			case "overtaken":
				request.revoke()
			case "withdrawal":
				a.dropColorDecorations(d)
			case "replacement":
				a.editor.colorDecorations.docs[1] = &documentColorDecorations{cancel: func() {}}
			case "closed":
				p.docs.list = nil
			}
			a.finishColorDecorations(p, d, request, generation, view, revision, prepared, nil)
			if got := viewHasForeground(view, 0xC00050); got != (transition == "current") {
				t.Fatalf("%s: color result applied=%t", transition, got)
			}
		})
	}
}

func TestMoveOpenDocumentInvalidatesColorDecorations(t *testing.T) {
	root := t.TempDir()
	oldPath, newPath := filepath.Join(root, "sample.src"), filepath.Join(root, "sample.txt")
	if err := os.WriteFile(oldPath, []byte("sample"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	h.app.openFile(p, oldPath)
	h.await("document open", func() bool { return p.docs.byPath(oldPath) != nil })
	d := p.docs.byPath(oldPath)
	ctx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	request := &documentColorDecorations{cancel: cancel}
	h.app.editor.colorDecorations.docs = map[int]*documentColorDecorations{d.id: request}
	generation, revision := request.generation, d.view.Revision()
	prepared := editorview.PrepareColorDecorations(d.view.TextSnapshot(), []editorview.ColorDecoration{
		{StartLine: 0, StartCharacter: 0, EndLine: 0, EndCharacter: 6, Light: "#C00050", Dark: "#FF80B0"},
	})
	d.view.SetPreparedColorDecorations(prepared)
	if err := os.Rename(oldPath, newPath); err != nil {
		t.Fatal(err)
	}
	h.app.moveOpenDocuments(p, oldPath, newPath)
	if p.docs.byPath(newPath) != d {
		t.Fatal("the same document should stay open at its new path")
	}
	if ctx.Err() != context.Canceled {
		t.Error("the provider request for the old path is still running")
	}
	h.app.finishColorDecorations(p, d, request, generation, d.view, revision, prepared, nil)
	if viewHasForeground(d.view, 0xC00050) {
		t.Error("the renamed document kept colors selected for its old path")
	}
}

func resolveBuiltinRainbow(ctx context.Context, text rope.Rope, grammar *syntax.Syntax, colorBrackets, colorVariables bool) (builtinRainbow, error) {
	brackets, variables := syntax.RainbowCandidates(ctx, text, grammar, true, colorVariables)
	resolved, err := resolveRainbowCandidates(ctx, syntax.CandidateSnapshot{Brackets: brackets, Variables: variables}, colorBrackets, colorVariables, nil)
	if resolved == nil {
		return builtinRainbow{}, err
	}
	return resolved.result, err
}

func TestRainbowCandidatesReuseResolvedCoreResult(t *testing.T) {
	candidates := syntax.CandidateSnapshot{Brackets: []syntax.Bracket{{Offset: 0, Bracket: "{"}, {Offset: 1, Bracket: "}"}}}
	first, err := resolveRainbowCandidates(t.Context(), candidates, false, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	// A cancelled request cannot call Core, so reusing its complete answer still succeeds.
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	next, err := resolveRainbowCandidates(ctx, candidates, false, false, first)
	if err != nil || next != first {
		t.Fatalf("unchanged candidates were not reused: %v", err)
	}
	if len(next.result.matches) != 2 || len(next.result.indentScopes) != 1 {
		t.Fatalf("pairing lost while colors disabled: %+v", next.result)
	}
	_, err = resolveRainbowCandidates(ctx, candidates, true, false, first)
	if err == nil {
		t.Fatal("changed options reused an incompatible Core result")
	}
}

func TestRainbowCandidatesReuseMovedCoreResult(t *testing.T) {
	for _, colors := range []struct{ brackets, variables bool }{{}, {true, false}, {false, true}, {true, true}} {
		original := syntax.CandidateSnapshot{
			Brackets:  []syntax.Bracket{{Offset: 0, Bracket: "]"}, {Offset: 1, Bracket: "{"}, {Offset: 8, Bracket: "("}, {Offset: 10, Bracket: ")"}, {Offset: 20, Bracket: "}"}},
			Variables: []syntax.Variable{{Start: 3, End: 7, Name: "same"}, {Start: 13, End: 17, Name: "same"}},
		}
		moved := syntax.CandidateSnapshot{
			Brackets:  []syntax.Bracket{{Offset: 3, Bracket: "]"}, {Offset: 4, Bracket: "{"}, {Offset: 18, Bracket: "("}, {Offset: 20, Bracket: ")"}, {Offset: 42, Bracket: "}"}},
			Variables: []syntax.Variable{{Start: 8, End: 12, Name: "same"}, {Start: 13, End: 17, Name: "same"}},
		}
		first, err := resolveRainbowCandidates(t.Context(), original, colors.brackets, colors.variables, nil)
		if err != nil {
			t.Fatal(err)
		}
		fresh, err := resolveRainbowCandidates(t.Context(), moved, colors.brackets, colors.variables, nil)
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(t.Context())
		cancel()
		reused, err := resolveRainbowCandidates(ctx, moved, colors.brackets, colors.variables, first)
		if err != nil {
			t.Fatalf("offset-only edits called Core (brackets=%v variables=%v): %v", colors.brackets, colors.variables, err)
		}
		if !slices.Equal(reused.result.colors, fresh.result.colors) || !slices.Equal(reused.result.matches, fresh.result.matches) || !slices.Equal(reused.result.indentScopes, fresh.result.indentScopes) {
			t.Fatalf("moved result differs from fresh Core: got %+v, want %+v", reused.result, fresh.result)
		}
		if first.brackets[1].Offset != 1 || first.result.matches[0].Offset != 1 {
			t.Fatal("reprojection mutated the previous immutable result")
		}
		changed := moved
		changed.Brackets = slices.Clone(moved.Brackets)
		changed.Brackets[0].Bracket = "["
		if _, err := resolveRainbowCandidates(ctx, changed, colors.brackets, colors.variables, reused); err == nil {
			t.Fatal("changed bracket sequence reused old pairing")
		}
		if colors.variables {
			changed = moved
			changed.Variables = slices.Clone(moved.Variables)
			changed.Variables[0].Name = "else"
			if _, err := resolveRainbowCandidates(ctx, changed, colors.brackets, true, reused); err == nil {
				t.Fatal("changed variable name reused old colors")
			}
		}
	}
}

func TestRainbowDegradationLogsOnlyWhenReasonsChange(t *testing.T) {
	path := filepath.Join(t.TempDir(), "many.go")
	source := "package sample\n" + strings.Repeat("var _ = []int{}\n", 5_001)
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	log := &faultLog{}
	options := DesktopOptions(core.NewClient(), lightThemeStore(t), "test")
	options.Logs = log
	h := newHarnessWithOptions(t, options)
	h.app.openStandaloneFile(path)
	h.await("standalone editor opened", func() bool {
		return h.app.project != nil && h.app.project.docs.byPath(path) != nil
	})
	h.settle()
	p := h.app.project
	d := p.docs.byPath(path)
	count := func() int {
		log.mu.Lock()
		defer log.mu.Unlock()
		n := 0
		for _, event := range log.events {
			if event.event == backgroundFailedEvent && event.fields["operation"] == "editor_rainbow_bracket_limit" {
				n++
			}
		}
		return n
	}
	if got := count(); got != 1 {
		t.Fatalf("initial bracket degradation logs = %d, want 1", got)
	}
	for range 3 {
		d.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{}, Text: " "}})
		h.app.scheduleColorDecorations(p, d, 0)
		h.settle()
	}
	if got := count(); got != 1 {
		t.Fatalf("unchanged degradation logged %d times after edits, want 1", got)
	}
	d.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{End: d.view.TextSnapshot().Len()}, Text: "package sample\n"}})
	h.app.scheduleColorDecorations(p, d, 0)
	h.settle()
	d.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{}, Text: source}})
	h.app.scheduleColorDecorations(p, d, 0)
	h.settle()
	if got := count(); got != 2 {
		t.Fatalf("degradation recurring after recovery logs = %d, want 2", got)
	}
}

func TestRainbowDegradationTracksReasonSet(t *testing.T) {
	log := &faultLog{}
	a := &App{logSink: log}
	state := &documentColorDecorations{}
	for _, step := range []struct {
		reasons []string
		want    int
	}{
		{[]string{"bracket_limit", "variable_limit"}, 2},
		{[]string{"variable_limit", "bracket_limit"}, 2},
		{[]string{"variable_limit"}, 2},
		{[]string{"variable_limit", "long_line"}, 3},
		{nil, 3},
		{[]string{"variable_limit"}, 4},
	} {
		a.reportRainbowDegradation(state, step.reasons)
		if len(log.events) != step.want {
			t.Fatalf("reasons %v: got %d logs, want %d", step.reasons, len(log.events), step.want)
		}
	}
}

// lightThemeStore is an empty settings store with an explicit theme, which keeps New from
// asking the system for its appearance; that blocks when no application is running.
func lightThemeStore(t *testing.T) *store.Store {
	t.Helper()
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeLight}); err != nil {
		t.Fatal(err)
	}
	return prefs
}
