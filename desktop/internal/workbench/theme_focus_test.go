package workbench

import (
	"testing"
)

// The selection of a list stays marked but greys while another window has the keyboard,
// and comes back when this window is activated again.
func TestSelectionGreysWhileAnotherWindowHasTheKeyboard(t *testing.T) {
	a := &App{}
	a.applyLook(themeLight)
	if a.theme.Selection != a.colors.Selection {
		t.Fatalf("active selection = %+v, want %+v", a.theme.Selection, a.colors.Selection)
	}

	a.windowInactive = true
	a.applySelectionFocus()
	if a.theme.Selection != a.colors.SelectionIdle {
		t.Fatalf("inactive selection = %+v, want the idle %+v", a.theme.Selection, a.colors.SelectionIdle)
	}

	// A look change while the window stays inactive keeps the idle color.
	a.applyLook(themeDark)
	if a.theme.Selection != a.colors.SelectionIdle {
		t.Fatalf("inactive selection after a look change = %+v, want the idle one", a.theme.Selection)
	}

	a.windowInactive = false
	a.applySelectionFocus()
	if a.theme.Selection != a.colors.Selection {
		t.Fatalf("selection after activation = %+v, want %+v", a.theme.Selection, a.colors.Selection)
	}
}

// The idle colors are the ones IDEA's expUI schemes dim an unfocused tree with, and they
// differ from the focused pair in both looks.
func TestIdleSelectionDiffersFromTheFocusedOne(t *testing.T) {
	light, lightPalette := lightLook()
	dark, darkPalette := darkLook()
	if lightPalette.SelectionIdle == lightPalette.Selection || darkPalette.SelectionIdle == darkPalette.Selection {
		t.Fatal("an idle selection color must differ from the focused one in both looks")
	}
	if light.Selection != lightPalette.Selection || dark.Selection != darkPalette.Selection {
		t.Fatal("a look starts with the focused selection color")
	}
}
