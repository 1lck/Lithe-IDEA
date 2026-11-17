package settingswindow

import (
	"slices"
	"testing"

	"github.com/vivaui/viva/gfx"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
)

// TestTerminalCursorChoicesApplyWhenChosen covers the Terminal page's cursor card: a stored
// value the page does not offer shows as the default and is not rewritten by opening the
// page, and each choice reaches the settings owner at once with the other half kept.
func TestTerminalCursorChoicesApplyWhenChosen(t *testing.T) {
	var changed [][2]string
	w := newWindow(NewController(Options{
		TerminalShells: func() ([]localshell.Choice, string) {
			return []localshell.Choice{{Name: "zsh", Path: "/bin/zsh", Default: true}}, "/bin/zsh"
		},
		SetTerminalCursor: func(shape, thickness string) { changed = append(changed, [2]string{shape, thickness}) },
	}), Values{TerminalCursorShape: "beam", TerminalCursorThickness: CursorThicknessThin})
	w.sess.page = pageTerminal
	d := openWindow(t, w)
	language := w.marketLanguage()
	word := func(key string) string { return i18n.Shared(language, "desktop.settings.terminal."+key) }

	if hit := d.hit(word("cursorShape")); hit.Role != gfx.RoleCombobox || hit.Value != word("cursorShapeBlock") {
		t.Fatalf("an unknown shape did not show the block: %+v", hit)
	}
	if hit := d.hit(word("cursorThickness")); hit.Value != word("cursorThin") {
		t.Fatalf("the stored thickness is not chosen: %+v", hit)
	}
	if len(changed) != 0 {
		t.Fatalf("opening the page wrote %v", changed)
	}

	d.click(word("cursorShape"))
	d.click(word("cursorShapeBar"))
	d.click(word("cursorThickness"))
	d.click(word("cursorThick"))
	d.click(word("cursorShape"))
	d.click(word("cursorShapeBlock"))
	want := [][2]string{{CursorShapeBar, CursorThicknessThin}, {CursorShapeBar, CursorThicknessThick}, {CursorShapeBlock, CursorThicknessThick}}
	if !slices.Equal(changed, want) {
		t.Fatalf("choices wrote %v, want %v", changed, want)
	}
	if hit := d.hit(word("cursorThickness")); hit.Value != word("cursorThick") || hit.Disabled {
		t.Fatalf("with the block chosen the thickness is %+v, want the thick one still open", hit)
	}
}
