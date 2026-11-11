package workbench

import (
	"context"
	"net/url"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/ui"
)

// Plugin editor actions in the editor. A document's actions are collected from its text after the
// user stops typing, and dropped as soon as the text changes: an action's range and its
// document version belong to one text. An action shows as a line annotation on its line and as an
// entry of the editor's menu for that line; choosing it calls the plugin again.
const editorActionDelay = 600 * time.Millisecond

// scheduleEditorActions drops the document's actions and collects them again once typing pauses.
func (a *App) scheduleEditorActions(p *project, d *document) {
	a.clearEditorActions(d)
	if d.actionTimer != nil {
		d.actionTimer.Stop()
	}
	id := d.id
	d.actionTimer = time.AfterFunc(editorActionDelay, func() {
		a.post(func(a *App) {
			if a.project == p && p.docs.find(id) == d {
				a.collectEditorActions(p, d)
			}
		})
	})
}

// clearEditorActions forgets the document's actions and their annotations.
func (a *App) clearEditorActions(d *document) {
	if len(d.actions) == 0 {
		return
	}
	d.actions = nil
	d.view.SetLineAnnotations(nil)
}

// collectEditorActions asks the plugins for the actions of the document's current text. An answer
// that arrives after the text changed is dropped, since its ranges no longer name the document.
func (a *App) collectEditorActions(p *project, d *document) {
	if a.plugins == nil || d.virtual || d.path == "" {
		return
	}
	data, _ := d.view.Text()
	text, version, id, path, root := string(data), d.view.Revision(), strconv.Itoa(d.id), d.path, p.root
	plugins := a.plugins
	a.background(p, 15*time.Second, func(ctx context.Context) func(*App) {
		actions, err := plugins.CollectEditorActions(ctx, root, path, id, version, text)
		return func(a *App) {
			if p.docs.find(d.id) != d || d.view.Revision() != version {
				return
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_actions", err))
			}
			d.actions = actions
			a.annotateEditorActions(d)
		}
	})
}

// annotateEditorActions shows the first action of each line at the end of that line.
func (a *App) annotateEditorActions(d *document) {
	seen := map[int]bool{}
	var annotations []editorview.LineAnnotation
	for _, action := range d.actions {
		line := action.Range.StartLine - 1
		if line < 0 || seen[line] {
			continue
		}
		seen[line] = true
		annotations = append(annotations, editorview.LineAnnotation{Line: line, Text: action.Title})
	}
	d.view.SetLineAnnotations(annotations)
}

// editorActionMenuItems declares the actions that start on the caret line as menu entries, each
// alternative as its own entry after its action.
func (a *App) editorActionMenuItems(c ui.C, p *project, d *document, menu *ui.MenuItems) {
	if len(d.actions) == 0 {
		return
	}
	line, _ := d.view.CaretUTF16()
	shown := false
	for index := range d.actions {
		action := d.actions[index]
		if action.Range.StartLine-1 != line {
			continue
		}
		if !shown {
			menu.Separator()
			shown = true
		}
		if menu.Item(action.Title).Clicked() {
			c.After(func() { a.runEditorAction(p, d, action, -1) })
		}
		for alternative, choice := range action.Alternatives {
			alternative := alternative
			if menu.Item(choice.Title).Clicked() {
				c.After(func() { a.runEditorAction(p, d, action, alternative) })
			}
		}
	}
}

// runEditorAction calls the plugin for one action or alternative. The call is refused when the
// document changed since the action was collected. Locations the result asks to reveal are opened;
// only the first is opened for now, the others wait for the navigation list.
func (a *App) runEditorAction(p *project, d *document, action pluginservice.EditorAction, alternative int) {
	if a.plugins == nil {
		return
	}
	if d.view.Revision() != action.Version() {
		a.notify(i18n.Shared(a.language(), "desktop.editorActions.stale"))
		return
	}
	plugins, root := a.plugins, p.root
	a.background(p, 100*time.Second, func(ctx context.Context) func(*App) {
		locations, err := plugins.InvokeEditorAction(ctx, action, alternative)
		return func(a *App) {
			if err != nil {
				a.notify(i18n.Shared(a.language(), "desktop.editorActions.failed"))
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_action", err))
				return
			}
			if len(locations) == 0 {
				return
			}
			a.revealEditorLocation(p, root, locations[0])
		}
	})
}

// revealEditorLocation opens a location a result named: a file opens at its position, another URI
// goes through the plugin's content provider.
func (a *App) revealEditorLocation(p *project, root string, location pluginservice.EditorLocation) {
	parsed, err := url.Parse(location.URI)
	if err != nil {
		a.notify(i18n.Shared(a.language(), "desktop.editorActions.failed"))
		return
	}
	if parsed.Scheme == "file" {
		a.openFileAtPosition(p, parsed.Path, location.StartLine, location.StartCharacter)
		return
	}
	if a.plugins != nil {
		uri, line, column := location.URI, location.StartLine, location.StartCharacter
		a.background(p, 30*time.Second, func(ctx context.Context) func(*App) {
			if err := a.plugins.OpenContentURI(ctx, root, uri, line, column); err != nil {
				return func(a *App) { a.notify(i18n.Shared(a.language(), "desktop.editorActions.failed")) }
			}
			return nil
		})
	}
}
