package workbench

import (
	"context"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// Back and forward through the places the caret jumped from.
//
// Core owns the history rules (identity, de-duplication, the cap, what a step does with the
// live caret). This file records the jumps the editor makes (definition, references, outline
// and search results, Go to Line), takes a step and opens the destination, restoring the
// previous history when the destination cannot be opened. The document identity is the file's
// path; Core compares it as an opaque string.

// navigationHistoryState is the history of the open project; it starts empty when another
// project is opened.
type navigationHistoryState struct {
	project *project
	history core.NavigationHistory
}

// navigationLocation is the live caret of the selected document of the project.
func (a *App) navigationLocation(p *project) (core.NavigationLocation, bool) {
	d := p.selectedDocument(p.docs.group)
	if d == nil || d.virtual {
		return core.NavigationLocation{}, false
	}
	line, column := d.view.CaretUTF16()
	return core.NavigationLocation{Document: d.path, Line: line, Column: column}, true
}

// navigationHistoryOf is the history of p, dropped when it belongs to another project.
func (a *App) navigationHistoryOf(p *project) *navigationHistoryState {
	s := &a.editor.nav
	if s.project != p {
		*s = navigationHistoryState{project: p}
	}
	return s
}

// recordNavigationJump records that the caret is about to leave its place for the destination.
// It does nothing while a history step is opening its own destination.
func (a *App) recordNavigationJump(p *project, path string, line, column int) {
	kernel, ok := a.kernel.(editorKernel)
	if !ok || p == nil {
		return
	}
	departure, ok := a.navigationLocation(p)
	if !ok {
		return
	}
	s := a.navigationHistoryOf(p)
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	destination := core.NavigationLocation{Document: path, Line: line, Column: column}
	next, _, err := kernel.ReduceNavigationHistory(ctx, s.history, core.NavigationHistoryRecord(departure, &destination))
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_navigation_history", err))
		return
	}
	s.history = next
}

// stepNavigation goes back or forward one place.
func (a *App) stepNavigation(p *project, forward bool) {
	kernel, ok := a.kernel.(editorKernel)
	if !ok || p == nil {
		return
	}
	current, ok := a.navigationLocation(p)
	if !ok {
		return
	}
	s := a.navigationHistoryOf(p)
	event := core.NavigationHistoryBack(current)
	if forward {
		event = core.NavigationHistoryForward(current)
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	next, destination, err := kernel.ReduceNavigationHistory(ctx, s.history, event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_navigation_history", err))
		return
	}
	if destination == nil {
		s.history = next
		return
	}
	// A destination that no longer exists keeps the history as it was, so the entry is not lost.
	if _, err := os.Stat(destination.Document); err != nil {
		a.notifyError(i18n.Shared(a.language(), "desktop.navigation.historyUnavailable"))
		return
	}
	s.history = next
	a.openStepDestination(p, *destination)
}

// openStepDestination opens a history destination without recording it as a jump.
func (a *App) openStepDestination(p *project, destination core.NavigationLocation) {
	if d := p.docs.byPath(destination.Document); d != nil {
		a.selectDocument(p, d.id)
		d.view.GoToNavigation(destination.Line, destination.Column, false)
		return
	}
	if p.docs.locations == nil {
		p.docs.locations = make(map[string]documentLocation)
	}
	p.docs.locations[destination.Document] = documentLocation{line: destination.Line + 1, column: destination.Column, columnSet: true}
	a.openFile(p, destination.Document)
}

// navigationHistoryShortcut handles Control-Alt-Left and Control-Alt-Right, the chords of the
// previous clients on both platforms.
func (a *App) navigationHistoryShortcut(event gfx.KeyEvent) gfx.EventResult {
	if event.Release || (event.Key != gfx.KeyLeft && event.Key != gfx.KeyRight) {
		return gfx.EventResult{}
	}
	if event.Modifiers != gfx.ModifierControl|gfx.ModifierAlt {
		return gfx.EventResult{}
	}
	p := a.project
	if p == nil || a.focusedTerminal(event.Target) != nil {
		return gfx.EventResult{}
	}
	a.stepNavigation(p, event.Key == gfx.KeyRight)
	return gfx.EventResult{Handled: true, Repaint: true}
}
