package windowcontrols

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// TestStyleDrawsTheButtonsInTheTitleBarInk covers the light look: Viva takes the default
// glyph color from the clear color, which is dark, so the glyphs came out white on the
// light title bar. The buttons must take the title bar's ink, and their tints with it.
func TestStyleDrawsTheButtonsInTheTitleBarInk(t *testing.T) {
	ink := gfx.RGB24(0x1F2328)
	style := Style(ink, i18n.For(i18n.English))
	if style.Foreground != ink {
		t.Fatalf("glyph color = %v, want the title bar's ink %v", style.Foreground, ink)
	}
	if style.Hover != ink.WithAlpha(hoverAlpha) || style.Pressed != ink.WithAlpha(pressedAlpha) {
		t.Fatalf("hover and press tints = %v and %v, want the ink at %v and %v", style.Hover, style.Pressed, hoverAlpha, pressedAlpha)
	}
	if style.Close != (gfx.Color{}) || style.CloseForeground != (gfx.Color{}) {
		t.Fatalf("close button colors = %v and %v, want them left to Viva's red", style.Close, style.CloseForeground)
	}
}

func TestStyleNamesTheButtonsInTheUsersLanguage(t *testing.T) {
	for _, test := range []struct {
		language i18n.Language
		want     [4]string
	}{
		{i18n.English, [4]string{"Minimize", "Maximize", "Restore", "Close"}},
		{i18n.Chinese, [4]string{"最小化", "最大化", "还原", "关闭"}},
	} {
		style := Style(gfx.RGB24(0x1F2328), i18n.For(test.language))
		got := [4]string{style.Minimize, style.Maximize, style.Restore, style.CloseName}
		if got != test.want {
			t.Fatalf("language %s: button names = %q, want %q", test.language.Code(), got, test.want)
		}
	}
}

// TestStyleLeavesToVivaWhatItIsNotGiven covers a window asked for its style before its first
// paint, when it has no ink and no catalog yet: Viva's defaults must stand, not black glyphs
// on black tints or nameless buttons.
func TestStyleLeavesToVivaWhatItIsNotGiven(t *testing.T) {
	if style := Style(gfx.Color{}, nil); style != (app.WindowControlsStyle{}) {
		t.Fatalf("style without ink or catalog = %+v, want the zero style", style)
	}
}
