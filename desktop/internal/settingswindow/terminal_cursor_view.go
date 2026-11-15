package settingswindow

import (
	"github.com/vivaui/viva/ui"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// The terminal cursor shapes Values.TerminalCursorShape holds. The empty string is the block a
// terminal starts with.
const (
	CursorShapeBlock     = ""
	CursorShapeBar       = "bar"
	CursorShapeUnderline = "underline"
)

// The terminal cursor thicknesses Values.TerminalCursorThickness holds. The empty string is
// the normal thickness.
const (
	CursorThicknessThin   = "thin"
	CursorThicknessNormal = ""
	CursorThicknessThick  = "thick"
)

var (
	cursorShapeChoices     = []string{CursorShapeBlock, CursorShapeBar, CursorShapeUnderline}
	cursorThicknessChoices = []string{CursorThicknessThin, CursorThicknessNormal, CursorThicknessThick}
)

// NormalCursorShape is shape when it is one of the shapes above and the block otherwise, so a
// value an older or newer build stored draws a cursor and shows as one choice of the page.
func NormalCursorShape(shape string) string {
	if shape == CursorShapeBar || shape == CursorShapeUnderline {
		return shape
	}
	return CursorShapeBlock
}

// NormalCursorThickness is thickness when it is one of the thicknesses above and the normal
// one otherwise.
func NormalCursorThickness(thickness string) string {
	if thickness == CursorThicknessThin || thickness == CursorThicknessThick {
		return thickness
	}
	return CursorThicknessNormal
}

// cursorCard is the Terminal page's cursor setting: the shape the cursor takes until a
// program asks for its own, and how thick a bar or an underline draws. The thickness stays
// open with the block chosen, as it is also the thickness of a bar or an underline a program
// asks for. Open terminals take a change at their next paint.
func (w *window) cursorCard(c ui.C) {
	language := w.marketLanguage()
	shape := NormalCursorShape(w.sess.values.TerminalCursorShape)
	thickness := NormalCursorThickness(w.sess.values.TerminalCursorThickness)
	shapeTitle := i18n.Shared(language, "desktop.settings.terminal.cursorShape")
	thicknessTitle := i18n.Shared(language, "desktop.settings.terminal.cursorThickness")
	w.card(c, i18n.Shared(language, "desktop.settings.terminal.cursor"), i18n.Shared(language, "desktop.settings.terminal.cursorHelp"), func() {
		w.settingsRow(c, shapeTitle, "", func() {
			if ui.Select(c.Part("cursor-shape"), &shape, cursorShapeChoices, func(choice string) string {
				switch choice {
				case CursorShapeBar:
					return i18n.Shared(language, "desktop.settings.terminal.cursorShapeBar")
				case CursorShapeUnderline:
					return i18n.Shared(language, "desktop.settings.terminal.cursorShapeUnderline")
				}
				return i18n.Shared(language, "desktop.settings.terminal.cursorShapeBlock")
			}).Width(selectWidth).Label(shapeTitle).Changed() {
				w.setTerminalCursor(shape, thickness)
			}
		})
		w.settingsRow(c, thicknessTitle, "", func() {
			if ui.Select(c.Part("cursor-thickness"), &thickness, cursorThicknessChoices, func(choice string) string {
				switch choice {
				case CursorThicknessThin:
					return i18n.Shared(language, "desktop.settings.terminal.cursorThin")
				case CursorThicknessThick:
					return i18n.Shared(language, "desktop.settings.terminal.cursorThick")
				}
				return i18n.Shared(language, "desktop.settings.terminal.cursorNormal")
			}).Width(selectWidth).Label(thicknessTitle).Changed() {
				w.setTerminalCursor(shape, thickness)
			}
		})
	})
}

// setTerminalCursor stores the cursor chosen and hands it to the settings owner.
func (w *window) setTerminalCursor(shape, thickness string) {
	if w.sess.finished.Load() {
		return
	}
	shape, thickness = NormalCursorShape(shape), NormalCursorThickness(thickness)
	if shape == NormalCursorShape(w.sess.values.TerminalCursorShape) && thickness == NormalCursorThickness(w.sess.values.TerminalCursorThickness) {
		return
	}
	w.sess.values.TerminalCursorShape, w.sess.values.TerminalCursorThickness = shape, thickness
	if w.ctrl.opts.SetTerminalCursor != nil {
		w.ctrl.opts.SetTerminalCursor(shape, thickness)
	}
}
