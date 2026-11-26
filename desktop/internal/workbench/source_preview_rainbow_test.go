package workbench

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

func rainbowPreviewFixture(t *testing.T) (*harness, *document, *sourcePreview) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "preview.go")
	if err := os.WriteFile(path, []byte("package sample\nfunc use(value int) int {\n    local := value + 1\n    return local + value\n}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	on := true
	prefs := store.At(t.TempDir())
	if err := prefs.Save(settingsFile, settings{Theme: themeLight, EditorPreferences: core.EditorStoredPreferences{
		RainbowBrackets: &on, RainbowVariables: &on, IndentGuides: &on, RainbowIndentGuides: &on,
		RainbowLightColors: []string{"#ABCDEF", "#654321", "#4729AD", "#DD7831", "#2879BD", "#D23878"},
		RainbowDarkColors:  []string{"#DCBAFE", "#123456", "#DA9274", "#1387DD"},
	}}); err != nil {
		t.Fatal(err)
	}
	options := DesktopOptions(core.NewClient(), prefs, "test")
	options.OpenFile = path
	h := newHarnessWithOptions(t, options)
	h.app.openStandaloneFile(path)
	h.await("source preview document opened", func() bool {
		return h.app.project != nil && h.app.project.docs.byPath(path) != nil
	})
	d := h.app.project.docs.byPath(path)
	h.await("document rainbow colors installed", func() bool {
		return viewTextInForeground(d.view, 0xDD7831) == "valuevaluevalue"
	})
	sp := &h.app.problems.preview
	sp.path, sp.line = path, 1
	h.app.bindSourcePreview(h.app.project, sp, d)
	t.Cleanup(func() { h.app.closeSourcePreview(sp) })
	return h, d, sp
}

func TestEditableSourcePreviewKeepsRainbowColorsThroughEditsAndDisable(t *testing.T) {
	h, d, sp := rainbowPreviewFixture(t)
	assertColors := func() {
		t.Helper()
		if got := viewTextInForeground(sp.view, 0xDD7831); got != "valuevaluevalue" {
			t.Fatalf("preview variable colors = %q, want all occurrences of value", got)
		}
		if got, want := viewTextInForeground(sp.view, 0xABCDEF), viewTextInForeground(d.view, 0xABCDEF); got != want {
			t.Fatalf("preview bracket/local colors = %q, document = %q", got, want)
		}
	}
	assertColors()
	for _, view := range []*editorview.View{d.view, sp.view} {
		if !view.ApplyEdit(editorview.Edit{Text: "\n"}, true) {
			t.Fatal("could not edit the mirrored source")
		}
		assertColors()
		h.app.scheduleColorDecorations(h.app.project, d, 0)
		h.await("mirrored preview rainbow colors refreshed", func() bool {
			return viewTextInForeground(sp.view, 0xDD7831) == "valuevaluevalue"
		})
		assertColors()
	}
	// Use a different palette so the assertion needs the fresh worker result, rather than the
	// foreground ranges moved by either mirrored edit.
	h.app.editorPreferences.RainbowLightColors = []string{"#2879BD"}
	h.app.refreshBuiltinRainbowColors()
	h.await("edited preview received a fresh palette", func() bool {
		return viewHasForeground(sp.view, 0x2879BD)
	})
	h.app.editorPreferences.RainbowBrackets, h.app.editorPreferences.RainbowVariables = false, false
	h.app.refreshBuiltinRainbowColors()
	if viewHasForeground(sp.view, 0x2879BD) {
		t.Fatal("disabling rainbow colors left the preview's old foreground ranges")
	}
}

func TestSourcePreviewUsesEditorIndentGuidePresentation(t *testing.T) {
	h, _, sp := rainbowPreviewFixture(t)
	canvas := new(gfx.Canvas)
	paintGuides := func() []gfx.Color {
		canvas.Reset()
		sp.draw(&ui.DrawContext{Canvas: canvas, Rect: gfx.Rect{Width: 600, Height: 260}})
		var colors []gfx.Color
		for _, rect := range canvas.Rectangles() {
			if rect.Bounds.Width == 1 && rect.Bounds.Height > 2 && rect.Color.Alpha > 0 {
				colors = append(colors, rect.Color)
			}
		}
		return colors
	}
	if guides := paintGuides(); len(guides) == 0 {
		t.Fatal("the source preview does not paint the enabled indent guides")
	}
	h.app.editorPreferences.IndentGuides = false
	if guides := paintGuides(); len(guides) != 0 {
		t.Fatalf("the source preview kept indent guides after disabling them: %v", guides)
	}
	for _, dark := range []bool{false, true} {
		h.app.colors.Dark = dark
		h.app.editorPreferences.IndentGuides = true
		want := gfx.RGB24(0xABCDEF)
		if dark {
			want = gfx.RGB24(0xDCBAFE)
		}
		found := false
		for _, color := range paintGuides() {
			if color.Red == want.Red && color.Green == want.Green && color.Blue == want.Blue {
				found = true
			}
		}
		if !found {
			t.Fatalf("dark=%t: preview indent guides do not use the current theme's rainbow palette", dark)
		}
	}
}

func TestSourcePreviewDropsUnsupportedBracketIndexBeforeProviderAnswer(t *testing.T) {
	h, d, sp := rainbowPreviewFixture(t)
	text := sp.view.TextSnapshot()
	source, _ := text.Substring(0, text.Len())
	opener := strings.Index(source, "() {")
	if opener < 0 {
		// This fixture has parameters, so the first structural brace follows its return type.
		opener = strings.IndexByte(source, '{')
	} else {
		opener += len("() ")
	}
	sp.view.SetSelection(opener, opener)
	foreground := gfx.RGB24(0x123123)
	underline := foreground
	underline.Alpha *= 0.55
	paintPairs := func() int {
		canvas := new(gfx.Canvas)
		sp.view.Paint(canvas, gfx.Rect{Width: 600, Height: 260}, editorview.Look{Foreground: foreground})
		count := 0
		for _, rect := range canvas.Rectangles() {
			if rect.Color == underline && rect.Bounds.Height == 1 {
				count++
			}
		}
		return count
	}
	if got := paintPairs(); got != 2 {
		t.Fatalf("preview bracket pair markers = %d, want 2", got)
	}
	// The grammar is withdrawn while an already-discovered provider continues to serve colors.
	// Its answer stays pending: the hour timer is owned by the request and cancelled in cleanup,
	// so this verifies immediate withdrawal without depending on a timer firing or a real plugin.
	state := h.app.editor.colorDecorations.docs[d.id]
	state.provided = true
	d.grammar = nil
	h.app.scheduleColorDecorations(h.app.project, d, time.Hour)
	if got := paintPairs(); got != 0 {
		t.Fatalf("preview kept %d obsolete bracket pair markers while the provider answer is pending", got)
	}
	if !viewHasForeground(sp.view, 0xDD7831) {
		t.Fatal("withdrawing the grammar also dropped the provider colors it should preserve")
	}
}
