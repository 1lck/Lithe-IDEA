package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
)

// This file holds what the status bar's editor items do when they are clicked: switch the
// indentation Tab inserts, switch the line break of the whole file, and lock the document
// against changes. Each one changes only the open document; the file on disk is written by Save.

// indentUnits are the two indentations the status item switches between.
const statusIndentSpaceCount = 4

// toggleIndentation switches what Tab inserts between spaces and a tab.
func (a *App) toggleIndentation(d *document) {
	if d == nil || d.virtual {
		return
	}
	insertsSpaces := func() bool {
		_, spaces := d.view.IndentSettings()
		return spaces
	}()
	if insertsSpaces {
		d.view.SetIndentUnit("\t")
		return
	}
	d.view.SetIndentUnit(strings.Repeat(" ", statusIndentSpaceCount))
}

// toggleLineEnding converts every line break of the document to the other style, as one undoable
// edit. A document that is already consistent with the other style changes nothing, and a read-only
// document is left alone.
func (a *App) toggleLineEnding(d *document) {
	if d == nil || d.virtual || d.view.ReadOnly() {
		return
	}
	text, _ := d.view.Text()
	current := string(text)
	plain := strings.ReplaceAll(current, "\r\n", "\n")
	next := plain
	if d.view.LineEnding() == "lf" {
		next = strings.ReplaceAll(plain, "\n", "\r\n")
	}
	if next == current {
		return
	}
	if err := d.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: len(text)}, Text: next}}); err != nil {
		a.notifyError(a.text.Errors.OpenFailed(err.Error()))
	}
}

// toggleReadOnly locks or unlocks the document against changes. Virtual documents are read-only
// by their nature and keep that.
func (a *App) toggleReadOnly(d *document) {
	if d == nil || d.virtual {
		return
	}
	d.view.SetReadOnly(!d.view.ReadOnly())
}
