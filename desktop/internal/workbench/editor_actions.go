package workbench

import (
	"context"
	"errors"
	"net/url"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
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
	d.links = nil
	d.view.SetLinks(nil)
	d.view.SetHoveredLink(nil)
	if len(d.actions) == 0 {
		return
	}
	d.actions = nil
	d.view.SetLineIcons(nil)
	if d.actionAnnotated {
		d.view.SetLineAnnotations(nil)
		d.actionAnnotated = false
	}
}

// collectEditorActions asks the plugins for the actions of the document's current text. An answer
// that arrives after the text changed is dropped, since its ranges no longer name the document.
func (a *App) collectEditorActions(p *project, d *document) {
	if a.plugins == nil || d.virtual || d.path == "" {
		return
	}
	data, _ := d.view.Text()
	text, version, id, path, root, language := string(data), d.view.Revision(), strconv.Itoa(d.id), d.path, p.root, d.languageID
	plugins := a.plugins
	a.background(p, 15*time.Second, func(ctx context.Context) func(*App) {
		actions, err := plugins.CollectEditorActions(ctx, root, path, id, version, text)
		// Code lenses come from the provider of the same document, as actions do, and join them.
		lenses, lensErr := plugins.PluginCodeLenses(ctx, root, path, language, id, version)
		actions = append(actions, lenses...)
		// Document links come from the same document's providers and are shown on hover.
		links, linkErr := plugins.PluginDocumentLinks(ctx, root, path, language, id, version)
		err = errors.Join(err, lensErr, linkErr)
		return func(a *App) {
			if p.docs.find(d.id) != d || d.view.Revision() != version {
				return
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_actions", err))
			}
			d.actions = actions
			a.annotateEditorActions(d)
			d.links = links
			a.annotateDocumentLinks(d)
		}
	})
}

// annotateEditorActions puts an icon in the gutter of each line that starts an action; the first action
// of a line stands for it, and a press on the icon runs that action. The icons are the editor's own,
// so they never overlap the blame annotations of the line.
func (a *App) annotateEditorActions(d *document) {
	seen := map[int]bool{}
	var icons []editorview.LineIcon
	for _, action := range d.actions {
		line := action.Range.StartLine - 1
		if line < 0 || seen[line] {
			continue
		}
		seen[line] = true
		if icon, ok := editorActionIcon(action.Icon); ok {
			icons = append(icons, editorview.LineIcon{Line: line, Icon: icon})
		}
	}
	d.view.SetLineIcons(icons)
	d.view.SetLineIconClick(func(line int) { a.runFirstActionOnLine(d, line) })
	// Actions without an icon are code lenses: their titles show at their line.
	var titles []editorview.LineAnnotation
	titled := map[int]bool{}
	for _, action := range d.actions {
		line := action.Range.StartLine - 1
		if action.Icon != "" || line < 0 || titled[line] {
			continue
		}
		titled[line] = true
		titles = append(titles, editorview.LineAnnotation{Line: line, Text: action.Title})
	}
	if len(titles) > 0 || d.actionAnnotated {
		d.view.SetLineAnnotations(titles)
	}
	d.actionAnnotated = len(titles) > 0
}

// editorActionIcon maps the host's action icon names to the icons it draws. An unknown name has no icon.
func editorActionIcon(name string) (gfx.Icon, bool) {
	switch name {
	case "run", "run-all":
		return icons.Play, true
	case "debug":
		return icons.Bug, true
	case "test", "test-passed", "test-failed", "test-skipped":
		return icons.Check, true
	}
	return gfx.Icon{}, false
}

// runFirstActionOnLine runs the first action that starts on a line, the one its gutter icon shows.
func (a *App) runFirstActionOnLine(d *document, line int) {
	for _, action := range d.actions {
		if action.Range.StartLine-1 == line {
			p := a.project
			if p != nil && p.docs.find(d.id) == d {
				a.runEditorAction(p, d, action, -1)
			}
			return
		}
	}
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
			a.revealEditorLocations(p, d, root, locations)
		}
	})
}

// revealEditorLocations shows the locations a result named. One opens directly; several go to the
// definition list, the same popup a language server's several definitions use. Files and other URIs
// both qualify: a URI the host cannot serve is dropped by the usable filter.
func (a *App) revealEditorLocations(p *project, d *document, root string, locations []pluginservice.EditorLocation) {
	targets := make([]core.PluginSemanticLocation, 0, len(locations))
	for _, location := range locations {
		item := core.PluginSemanticLocation{
			URI: location.URI,
			Range: core.PluginDocumentRange{
				Start: core.PluginDocumentPosition{Line: location.StartLine, UTF16Column: location.StartCharacter},
				End:   core.PluginDocumentPosition{Line: location.EndLine, UTF16Column: location.EndCharacter},
			},
		}
		if parsed, err := url.Parse(location.URI); err == nil && parsed.Scheme == "file" {
			item.FilePath = parsed.Path
		}
		targets = append(targets, item)
	}
	if len(targets) == 1 && targets[0].FilePath != "" {
		a.revealEditorLocation(p, root, locations[0])
		return
	}
	a.presentDefinitionTargets(p, d, pluginSemanticDefinition, a.usableDefinitionTargets(targets, maxDefinitionTargets), len(targets), d.view.Revision())
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
