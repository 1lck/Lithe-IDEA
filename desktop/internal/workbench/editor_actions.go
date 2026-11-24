package workbench

import (
	"context"
	"errors"
	"net/url"
	"strconv"
	"strings"
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

// A collection that times out is retried: a language server reports ready when its handshake
// ends, but a large project keeps it busy importing for minutes, and the actions it would answer
// (a main method's run and debug icons) must not stay missing until the user edits the file. Only
// a document an editor group shows is retried, so a server that every open file timed out on is
// asked again once per visible file rather than once per open file; a document behind another tab
// is collected again when it is selected (selectDocument). The waits double from
// editorActionRetryFirst up to editorActionRetryMax for at most editorActionRetryLimit retries:
// 2, 4, 8 and 16 seconds, then 30 seconds six times, three and a half minutes of waiting plus the
// collections themselves.
const (
	editorActionRetryFirst = 2 * time.Second
	editorActionRetryMax   = 30 * time.Second
	editorActionRetryLimit = 10
)

// editorActionRetryDelay is the wait before retry number attempt (1-based).
func editorActionRetryDelay(attempt int) time.Duration {
	delay := editorActionRetryFirst
	for i := 1; i < attempt && delay < editorActionRetryMax; i++ {
		delay *= 2
	}
	return min(delay, editorActionRetryMax)
}

// scheduleEditorActions drops the document's actions and collects them again once typing pauses.
// It starts a fresh retry budget: every trigger (an edit, a server becoming ready, a plugin
// registering actions, selecting a document whose collection timed out) deserves its own retries.
func (a *App) scheduleEditorActions(p *project, d *document) {
	d.actionRetries = 0
	d.actionsTimedOut = false
	a.clearEditorActions(d)
	a.collectEditorActionsAfter(p, d, editorActionDelay)
}

// collectEditorActionsAfter collects the document's actions after delay, replacing a collection
// already waiting. What the document shows stays until the new answer replaces it; an edit
// meanwhile clears it and schedules its own collection.
func (a *App) collectEditorActionsAfter(p *project, d *document, delay time.Duration) {
	if d.actionTimer != nil {
		d.actionTimer.Stop()
	}
	id := d.id
	d.actionTimer = time.AfterFunc(delay, func() {
		a.post(func(a *App) {
			if a.project == p && p.docs.find(id) == d {
				a.collectEditorActions(p, d)
			}
		})
	})
}

// documentShown reports whether an editor group shows the document.
func (p *project) documentShown(d *document) bool {
	member := documentMember(d.id)
	g := p.terms.bench.GroupOf(member)
	return g != nil && g.Selected == member
}

// clearEditorActions forgets the document's actions and their annotations.
func (a *App) clearEditorActions(d *document) {
	d.actionCollection++
	d.actionPanel = editorActionPanel{}
	d.pluginLinks = nil
	d.serverLinks = documentServerLinks{revision: d.serverLinks.revision, seen: d.serverLinks.seen, changedAt: d.serverLinks.changedAt}
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
	// The plugins of a remote workspace do not run yet (#2231): its documents name placeholder
	// paths, which have nothing on this computer.
	if a.plugins == nil || d.virtual || d.path == "" || p.remote != nil {
		return
	}
	data, _ := d.view.Text()
	d.actionCollection++
	text, version, id, path, root, language := string(data), d.view.Revision(), strconv.Itoa(d.id), d.path, p.root, d.languageID
	plugins := a.plugins
	snapshot := editorActionSnapshot{documentID: d.id, version: version, collection: d.actionCollection}
	a.background(p, 15*time.Second, func(ctx context.Context) func(*App) {
		actions, err := plugins.CollectEditorActions(ctx, root, path, id, version, text)
		// Code lenses come from the provider of the same document, as actions do, and join them.
		lenses, lensErr := plugins.PluginCodeLenses(ctx, root, path, language, id, version)
		actions = append(actions, lenses...)
		// Document links come from the same document's providers and are shown on hover.
		links, linkErr := plugins.PluginDocumentLinks(ctx, root, path, language, id, version)
		err = errors.Join(err, lensErr, linkErr)
		return func(a *App) { a.presentEditorActions(p, snapshot, actions, links, err) }
	})
}

// editorActionSnapshot identifies the presentation request, including model
// refreshes that leave the document text at the same revision.
type editorActionSnapshot struct {
	documentID int
	version    int
	collection uint64
}

func (a *App) presentEditorActions(p *project, snapshot editorActionSnapshot, actions []pluginservice.EditorAction, links []pluginservice.EditorLink, err error) {
	d := p.docs.find(snapshot.documentID)
	if a.project != p || d == nil || d.view.Revision() != snapshot.version || d.actionCollection != snapshot.collection {
		return
	}
	if err != nil {
		a.backgroundFailed("editor_actions", err)
		// A busy server answers late, not never. Keep what did answer and ask again later; other
		// failures (a refused registration, a malformed answer) would fail the same way again.
		if errors.Is(err, context.DeadlineExceeded) {
			if !p.documentShown(d) {
				d.actionsTimedOut = true
			} else if d.actionRetries < editorActionRetryLimit {
				d.actionRetries++
				a.collectEditorActionsAfter(p, d, editorActionRetryDelay(d.actionRetries))
			}
		}
	} else {
		d.actionRetries = 0
		d.actionsTimedOut = false
	}
	d.actions = actions
	a.annotateEditorActions(d)
	d.pluginLinks = links
	a.refreshDocumentLinks(d)
}

// annotateEditorActions puts icons in the gutter. The icon area has one slot per lane in use, left to
// right in editorActionLanes order, so the navigation, run, debug and test icons of a line sit side by
// side. A line shows the first action of each lane; a press on that icon opens the lane's menu, or
// runs the only choice it has. The icons are the editor's own, so they never overlap the blame
// annotations of the line.
func (a *App) annotateEditorActions(d *document) {
	dark := a.colors.Dark
	inUse := map[string]bool{}
	for _, action := range d.actions {
		lane, _, ok := editorActionPresentation(action.Icon, dark)
		if ok && action.Range.StartLine-1 >= 0 {
			inUse[lane] = true
		}
	}
	d.actionPanel.lanes = d.actionPanel.lanes[:0]
	slots := map[string]int{}
	for _, lane := range editorActionLanes {
		if inUse[lane] {
			slots[lane] = len(d.actionPanel.lanes)
			d.actionPanel.lanes = append(d.actionPanel.lanes, lane)
		}
	}
	type cell struct {
		line int
		lane string
	}
	seen := map[cell]bool{}
	var marks []editorview.LineIcon
	for _, action := range d.actions {
		line := action.Range.StartLine - 1
		lane, icon, ok := editorActionPresentation(action.Icon, dark)
		if !ok || line < 0 || seen[cell{line, lane}] {
			continue
		}
		seen[cell{line, lane}] = true
		marks = append(marks, editorview.LineIcon{Line: line, Slot: slots[lane], Icon: icon})
	}
	d.view.SetLineIcons(marks)
	d.view.SetLineIconClick(func(line, slot int, cell gfx.Rect) { a.pressEditorActionLane(d, line, slot, cell) })
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

// refreshEditorActionIcons re-applies gutter icons after a light/dark theme change.
func (a *App) refreshEditorActionIcons() {
	if a.project == nil {
		return
	}
	for _, d := range a.project.docs.list {
		if len(d.actions) > 0 {
			a.annotateEditorActions(d)
		}
	}
}

// editorActionLanes are the lanes of the gutter's icon area, in the order they are drawn from left to
// right: upward navigation, downward navigation, then run, debug and test status.
var editorActionLanes = []string{"navigate-up", "navigate-down", "run", "debug", "test"}

func isNavigationLane(lane string) bool {
	return lane == "navigate-up" || lane == "navigate-down"
}

// editorActionPresentation maps the host's action icon names to the lane they belong to and the icon
// the host draws for them. The host never starts anything because of an icon; the names only pick a
// picture. An unknown name has no lane and no icon, so its action is shown as a title.
func editorActionPresentation(name string, dark bool) (string, gfx.Icon, bool) {
	switch name {
	case "run", "run-all":
		return "run", icons.Play, true
	case "debug":
		return "debug", icons.Bug, true
	case "test":
		return "test", icons.Check, true
	case "test-passed":
		return "test", icons.CircleCheck, true
	case "test-failed":
		return "test", icons.CircleX, true
	case "test-skipped":
		return "test", icons.Minus, true
	case "navigate-implementing":
		return "navigate-up", icons.GutterImplementing(dark), true
	case "navigate-overriding":
		return "navigate-up", icons.GutterOverriding(dark), true
	case "navigate-super":
		return "navigate-up", icons.GutterNavigateUp(dark), true
	case "navigate-implemented":
		return "navigate-down", icons.GutterImplemented(dark), true
	case "navigate-overridden":
		return "navigate-down", icons.GutterOverridden(dark), true
	case "navigate-implementations":
		return "navigate-down", icons.GutterNavigateDown(dark), true
	}
	return "", gfx.Icon{}, false
}

// editorActionPanel is the state of a document's action icons beyond the actions themselves: the lane
// of each slot of the icon area, the lane menu a press has opened, and the hovered icon tooltip.
type editorActionPanel struct {
	lanes    []string
	menuOpen bool
	menuLine int
	menuLane string
	// menuAt is the cell of the icon pressed; the menu opens under it.
	menuAt gfx.Rect

	hoverOpen bool
	hoverLine int
	hoverSlot int
	hoverAt   gfx.Rect
	hoverText string
}

// editorActionChoice is one row of a lane menu: an action, or one of its alternatives (alternative is
// -1 for the action itself).
type editorActionChoice struct {
	title       string
	action      pluginservice.EditorAction
	alternative int
}

// editorActionChoices lists what the lane of a line offers: each action of that line in that lane,
// followed by its alternatives.
func editorActionChoices(actions []pluginservice.EditorAction, line int, lane string) []editorActionChoice {
	var choices []editorActionChoice
	for _, action := range actions {
		if action.Range.StartLine-1 != line {
			continue
		}
		if actionLane, _, ok := editorActionPresentation(action.Icon, false); !ok || actionLane != lane {
			continue
		}
		choices = append(choices, editorActionChoice{title: action.Title, action: action, alternative: -1})
		for index, alternative := range action.Alternatives {
			choices = append(choices, editorActionChoice{title: alternative.Title, action: action, alternative: index})
		}
	}
	return choices
}

// pressEditorActionLane handles a press on the icon of a lane on a line. A lane with one choice runs it
// at once; with several, the lane's menu opens and lists them.
func (a *App) pressEditorActionLane(d *document, line, slot int, cell gfx.Rect) {
	d.actionPanel.hoverOpen = false
	p := a.project
	if p == nil || p.docs.find(d.id) != d || slot < 0 || slot >= len(d.actionPanel.lanes) {
		return
	}
	lane := d.actionPanel.lanes[slot]
	choices := editorActionChoices(d.actions, line, lane)
	switch len(choices) {
	case 0:
		return
	case 1:
		a.runEditorActionAt(p, d, choices[0].action, choices[0].alternative, &cell)
	default:
		d.actionPanel.menuLine, d.actionPanel.menuLane, d.actionPanel.menuOpen = line, lane, true
		d.actionPanel.menuAt = cell
	}
}

// editorActionLaneMenu declares the menu a lane's icon opened: one row per choice of the lane. Choosing
// a row closes the menu and calls the plugin through runEditorActionAt.
func (a *App) editorActionLaneMenu(c ui.C, p *project, d *document) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		menu.WidthRange(240, 280)
		anchor := d.actionPanel.menuAt
		for _, choice := range editorActionChoices(d.actions, d.actionPanel.menuLine, d.actionPanel.menuLane) {
			choice := choice
			if menu.Item(choice.title).Clicked() {
				d.actionPanel.menuOpen = false
				c.After(func() {
					anchor := anchor
					a.runEditorActionAt(p, d, choice.action, choice.alternative, &anchor)
				})
			}
		}
	}
}

func editorActionTooltipText(choices []editorActionChoice) string {
	var parts []string
	seen := make(map[string]bool, len(choices))
	for _, choice := range choices {
		title := truncateDisplayText(choice.title, 120)
		if title == "" || seen[title] {
			continue
		}
		seen[title] = true
		parts = append(parts, title)
		if len(parts) == 4 {
			break
		}
	}
	return strings.Join(parts, "\n")
}

func (a *App) clearEditorActionHover(d *document) bool {
	if d == nil || !d.actionPanel.hoverOpen {
		return false
	}
	d.actionPanel.hoverOpen = false
	d.actionPanel.hoverText = ""
	return true
}

// trackEditorActionHover closes any open gutter action tooltip as soon as the pointer moves
// off its gutter icon cell, presses a button, or leaves the window. Running at the window
// root catches moves onto sibling widgets or the tooltip card itself that give no editor exit.
func (a *App) trackEditorActionHover(event gfx.PointerEvent) {
	p := a.project
	if p == nil {
		return
	}
	switch event.Kind {
	case gfx.PointerMove:
		changed := false
		for _, d := range p.docs.list {
			if d.actionPanel.hoverOpen && !pointInRect(d.actionPanel.hoverAt, event.X, event.Y) {
				if a.clearEditorActionHover(d) {
					changed = true
				}
			}
		}
		if changed {
			a.invalidator.Invalidate()
		}
	case gfx.PointerDown, gfx.PointerExit:
		changed := false
		for _, d := range p.docs.list {
			if a.clearEditorActionHover(d) {
				changed = true
			}
		}
		if changed {
			a.invalidator.Invalidate()
		}
	}
}

// editorActionHoverPointer updates the gutter icon tooltip on pointer motion and clears it
// when leaving the icon or pressing a button. It requests a repaint only when visibility or target changes.
func (a *App) editorActionHoverPointer(event gfx.PointerEvent, p *project, d *document) (gfx.EventResult, bool) {
	if p == nil || d == nil {
		return gfx.EventResult{}, false
	}
	switch event.Kind {
	case gfx.PointerMove:
		if d.actionPanel.menuOpen || len(d.actions) == 0 {
			if a.clearEditorActionHover(d) {
				a.invalidator.Invalidate()
			}
			return gfx.EventResult{}, false
		}
		line, slot, cell, ok := d.view.LineIconAt(event.X, event.Y)
		if !ok || slot < 0 || slot >= len(d.actionPanel.lanes) {
			if a.clearEditorActionHover(d) {
				a.invalidator.Invalidate()
			}
			return gfx.EventResult{}, false
		}
		text := editorActionTooltipText(editorActionChoices(d.actions, line, d.actionPanel.lanes[slot]))
		if text == "" {
			if a.clearEditorActionHover(d) {
				a.invalidator.Invalidate()
			}
			return gfx.EventResult{}, false
		}
		panel := &d.actionPanel
		if !panel.hoverOpen || panel.hoverLine != line || panel.hoverSlot != slot || panel.hoverAt != cell || panel.hoverText != text {
			panel.hoverOpen = true
			panel.hoverLine = line
			panel.hoverSlot = slot
			panel.hoverAt = cell
			panel.hoverText = text
			a.invalidator.Invalidate()
		}
		return gfx.EventResult{}, false
	case gfx.PointerDown:
		if a.clearEditorActionHover(d) {
			a.invalidator.Invalidate()
		}
	case gfx.PointerExit:
		if a.clearEditorActionHover(d) {
			a.invalidator.Invalidate()
		}
	}
	return gfx.EventResult{}, false
}

func (a *App) editorActionHoverPopup(c ui.C, p *project, d *document) {
	if p == nil || d == nil || a.project != p || !d.actionPanel.hoverOpen || d.actionPanel.menuOpen || d.actionPanel.hoverText == "" {
		return
	}
	anchor := d.actionPanel.hoverAt
	bounds := c.Bounds()
	canvas := c.Canvas()
	maxTextWidth := float32(340)
	textWidth := float32(0)
	for _, line := range strings.Split(d.actionPanel.hoverText, "\n") {
		textWidth = max(textWidth, canvas.TextWidth(line, 11.5))
	}
	width := min(max(textWidth+18, 110), maxTextWidth)
	if width > bounds.Width-8 {
		width = bounds.Width - 8
	}
	x, y := popupOrigin(anchor.Right()+6, anchor.Y, width, bounds)
	lang := a.language()
	label := i18n.Shared(lang, "desktop.editorActions.tooltip")
	ui.Stack(c.Part("editor-action-hover-layer")).Fill().Children(func() {
		hc := c.Part("editor-action-hover-card")
		ui.Column(hc).Absolute().Left(x).Top(y).Width(width).PadX(8).PadY(5).Gap(2).
			Background(a.theme.Popover).Border(1, a.theme.Border).
			Radius(a.theme.Metrics.RadiusPopup()).Shadow(gfx.ShadowMD).
			HitWith(ui.ID(hc), label, gfx.HitOptions{Role: gfx.RoleGroup, SkipFocus: true}).
			Children(func() {
				for _, line := range strings.Split(d.actionPanel.hoverText, "\n") {
					ui.Wrap(hc, line).FontSize(11.5).Color(a.colors.Text)
				}
			})
	})
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

// runCurrentFileEditorAction presents the same plugin invocation the gutter
// offers. An absent cached action may mean its initial collection is still in flight.
func (a *App) runCurrentFileEditorAction(p *project, d *document, mode titleAction, discoveryErr error) {
	fallback := func(a *App) {
		if discoveryErr != nil {
			a.notifyError(discoveryErr.Error())
			return
		}
		if mode == titleActionDebug {
			a.whenDebugAdaptersLoaded(p, func() {
				if p.selectedDocument(p.docs.group) == d {
					a.startDebug(p)
				}
			})
			return
		}
		a.operationRejected("title_run_current_file", "no_entrypoint")
		a.notifyInfo(i18n.Shared(a.language(), "desktop.title.currentFileNotRunnable"))
	}
	if d == nil || d.virtual || d.path == "" || a.plugins == nil {
		fallback(a)
		return
	}
	if p.runConfigs.findingEntrypoint {
		return
	}
	start := func() {
		if a.project != p || p.selectedDocument(p.docs.group) != d {
			return
		}
		invoke := func(a *App, actions []pluginservice.EditorAction) bool {
			choice := currentFileEditorChoice(actions, d.view.Revision(), mode)
			if choice == nil {
				return false
			}
			a.runEditorAction(p, d, choice.action, choice.alternative)
			return true
		}
		if invoke(a, d.actions) {
			return
		}
		p.runConfigs.findingEntrypoint = true
		plugins := a.plugins
		path, revision := d.path, d.view.Revision()
		data, _ := d.view.Text()
		text := string(data)
		id := strconv.Itoa(d.id)
		a.background(p, 10*time.Second, func(ctx context.Context) func(*App) {
			actions, err := plugins.CollectEditorActions(ctx, p.root, path, id, revision, text)
			return func(a *App) {
				p.runConfigs.findingEntrypoint = false
				if p.selectedDocument(p.docs.group) != d || d.path != path || d.view.Revision() != revision {
					return
				}
				if invoke(a, actions) {
					if err != nil {
						a.backgroundFailed("editor_actions", err)
					}
					return
				}
				if err != nil {
					if discoveryErr != nil {
						a.backgroundFailed("editor_actions", err)
						fallback(a)
						return
					}
					a.operationFailed("title_run_current_file", err)
					a.notifyError(i18n.Shared(a.language(), "desktop.editorActions.failed"))
					return
				}
				fallback(a)
			}
		})
	}
	if d.dirty() || d.saving || d.conflicted {
		p.runConfigs.findingEntrypoint = true
		a.saveBeforeClose(p, d, func(ok bool) {
			p.runConfigs.findingEntrypoint = false
			if ok {
				start()
			}
		})
		return
	}
	start()
}

// currentFileEditorChoice selects the first source-order action in the Run lane.
// Debug uses its Debug alternative, or a standalone Debug action if it has none.
func currentFileEditorChoice(actions []pluginservice.EditorAction, revision int, mode titleAction) *editorActionChoice {
	var run, debug *pluginservice.EditorAction
	first := func(current *pluginservice.EditorAction, action *pluginservice.EditorAction) *pluginservice.EditorAction {
		if current == nil || action.Range.StartLine < current.Range.StartLine ||
			(action.Range.StartLine == current.Range.StartLine && action.Range.StartColumn < current.Range.StartColumn) {
			return action
		}
		return current
	}
	for index := range actions {
		action := &actions[index]
		if action.Version() != revision {
			continue
		}
		lane, _, _ := editorActionPresentation(action.Icon, false)
		switch lane {
		case "run":
			run = first(run, action)
		case "debug":
			debug = first(debug, action)
		}
	}
	if run != nil {
		if mode == titleActionRun {
			return &editorActionChoice{action: *run, alternative: -1}
		}
		for index, alternative := range run.Alternatives {
			if alternative.Icon == "debug" {
				return &editorActionChoice{action: *run, alternative: index}
			}
		}
	}
	if mode == titleActionDebug && debug != nil {
		return &editorActionChoice{action: *debug, alternative: -1}
	}
	return nil
}

// runEditorAction calls the plugin for one action or alternative without an explicit popup anchor.
func (a *App) runEditorAction(p *project, d *document, action pluginservice.EditorAction, alternative int) {
	a.runEditorActionAt(p, d, action, alternative, nil)
}

// runEditorActionAt calls the plugin for one action or alternative. The call is refused when the
// document changed since the action was collected. Locations the result asks to reveal are opened
// directly when there is one, or listed in a navigation popup anchored near anchor (or the caret).
func (a *App) runEditorActionAt(p *project, d *document, action pluginservice.EditorAction, alternative int, anchor *gfx.Rect) {
	if a.plugins == nil {
		return
	}
	if d.view.Revision() != action.Version() {
		a.notify(i18n.Shared(a.language(), "desktop.editorActions.stale"))
		return
	}
	lane, _, _ := editorActionPresentation(action.Icon, false)
	if alternative >= 0 && alternative < len(action.Alternatives) {
		if altLane, _, ok := editorActionPresentation(action.Alternatives[alternative].Icon, false); ok {
			lane = altLane
		}
	}
	label := action.Title
	if alternative >= 0 && alternative < len(action.Alternatives) {
		label = action.Alternatives[alternative].Title
	}
	a.performed("editor.action.invoke", surfaceButton)
	if label != "" && !isNavigationLane(lane) {
		a.notifyInfo(i18n.SharedFormat(a.language(), "desktop.editorActions.starting", map[string]string{"label": label}))
	}
	plugins, root := a.plugins, p.root
	var anchorCopy *gfx.Rect
	if anchor != nil {
		rect := *anchor
		anchorCopy = &rect
	}
	a.background(p, 100*time.Second, func(ctx context.Context) func(*App) {
		locations, err := plugins.InvokeEditorAction(ctx, action, alternative)
		return func(a *App) {
			if err != nil {
				a.notifyError(i18n.Shared(a.language(), "desktop.editorActions.failed"))
				a.operationFailed("editor_action", err)
				return
			}
			if len(locations) == 0 {
				switch lane {
				case "navigate-down":
					a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noImplementations"))
				case "navigate-up":
					a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noSuperDeclaration"))
				}
				return
			}
			a.revealEditorLocationsAt(p, d, root, locations, lane, anchorCopy)
		}
	})
}

// revealEditorLocations shows the locations a result named, anchored at the caret.
func (a *App) revealEditorLocations(p *project, d *document, root string, locations []pluginservice.EditorLocation) {
	a.revealEditorLocationsAt(p, d, root, locations, "", nil)
}

// revealEditorLocationsAt shows the locations a result named. One opens directly; several go to the
// definition/implementation list anchored beside anchor (or the caret). Files and other URIs both
// qualify: a URI the host cannot serve is dropped by the usable filter.
func (a *App) revealEditorLocationsAt(p *project, d *document, root string, locations []pluginservice.EditorLocation, lane string, anchor *gfx.Rect) {
	targets := make([]core.PluginSemanticLocation, 0, len(locations))
	for _, location := range locations {
		item := core.PluginSemanticLocation{
			URI: location.URI,
			Range: core.PluginDocumentRange{
				Start: core.PluginDocumentPosition{Line: location.StartLine, UTF16Column: location.StartCharacter},
				End:   core.PluginDocumentPosition{Line: location.EndLine, UTF16Column: location.EndCharacter},
			},
		}
		if parsed, err := url.Parse(location.URI); err == nil && strings.EqualFold(parsed.Scheme, "file") {
			item.FilePath = fileURIPath(parsed)
		}
		targets = append(targets, item)
	}
	kind := semanticKind(pluginSemanticDefinition)
	if lane == "navigate-down" {
		kind = pluginSemanticImplementation
	}
	a.presentDefinitionTargetsAt(p, d, kind, a.usableDefinitionTargets(targets, maxDefinitionTargets), len(locations), d.view.Revision(), anchor)
}
