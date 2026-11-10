package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"runtime"
	"strconv"
	"time"
	"unicode"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// Language semantics for the editor: definition, hover and explicit completion.
//
// Core owns the language-server protocol and normalises every answer
// (locations, hover contents and completion items). This file only decides when
// to ask, how to present the normalised answer, and which answers are stale. It
// never parses a raw LSP Location and never derives completion rules: the
// completion list keeps Core's order and Core applies the accepted text edits.

const (
	// pluginSemanticCompleted is the Core runtime event carrying a finished
	// semantic operation.
	pluginSemanticCompleted = "requestCompleted"
	// pluginFeaturesChanged is the Core runtime event carrying the session's offered
	// features and, with completion, its completionOptions.
	pluginFeaturesChanged = "featuresChanged"
	// The semantic operations the editor asks for.
	pluginSemanticDefinition      = "definition"
	pluginSemanticHover           = "hover"
	pluginSemanticCompletion      = "completion"
	pluginSemanticReferences      = "references"
	pluginSemanticFormatting      = "formatting"
	pluginSemanticRangeFormatting = "rangeFormatting"
	pluginSemanticRename          = "rename"
	// The LSP methods Core reports on a completed event. They are matched only
	// against the host's own pending operation, never used to derive a rule.
	pluginMethodDefinition      = "textDocument/definition"
	pluginMethodHover           = "textDocument/hover"
	pluginMethodCompletion      = "textDocument/completion"
	pluginMethodReferences      = "textDocument/references"
	pluginMethodFormatting      = "textDocument/formatting"
	pluginMethodRangeFormatting = "textDocument/rangeFormatting"
	pluginMethodRename          = "textDocument/rename"

	// semanticStartTimeout bounds one asynchronous request submission. The
	// request only enters Core's queue, so this is a failure bound, not a wait.
	semanticStartTimeout = 10 * time.Second
	// semanticEditTimeout bounds snippet conversion and Core's edit validation
	// when a completion is accepted.
	semanticEditTimeout = 10 * time.Second
	// semanticCancelTimeout bounds one cancellation write.
	semanticCancelTimeout = 5 * time.Second
	// maxCompletionItems bounds the completion list the window keeps. Core's
	// answer is already normalised; excess candidates are dropped instead of
	// growing an unbounded popup.
	maxCompletionItems = 500
	// maxDefinitionTargets bounds a multi-target list the same way.
	maxDefinitionTargets = 50
	// maxReferenceTargets bounds a find-references list. The popup lays out
	// only visibleSemanticRows of them, so the bound limits memory, not views.
	maxReferenceTargets = 500
	// visibleSemanticRows is how many rows of a list are laid out, whatever the
	// candidate count, so a large answer never declares one view per item.
	visibleSemanticRows = 10
	// maxHoverBytes bounds the hover text the window keeps and paints.
	maxHoverBytes = 8 * 1024
	// maxSemanticPending bounds outstanding semantic operations. One per
	// operation kind is enough; a newer request cancels the older one.
	maxSemanticPending = 3

	semanticPopupWidth      = float32(360)
	semanticDefinitionWidth = float32(480)
	semanticRowHeight       = float32(24)
	semanticPopupPad        = float32(4)
	semanticHoverWidth      = float32(420)
	semanticHoverMaxHeight  = float32(240)
	// semanticHoverDelay is how long the pointer rests on a symbol before the
	// hover request starts. Negative lets tests exercise it without a clock wait.
	semanticHoverDelay = 500 * time.Millisecond
	// semanticAutoCompletionDelay is the typing pause before automatic
	// completion asks. Negative lets tests skip the clock wait.
	semanticAutoCompletionDelay = 120 * time.Millisecond
)

// semanticKind is one editor semantic operation.
type semanticKind string

func (k semanticKind) method() string {
	switch k {
	case pluginSemanticDefinition:
		return pluginMethodDefinition
	case pluginSemanticHover:
		return pluginMethodHover
	case pluginSemanticReferences:
		return pluginMethodReferences
	case pluginSemanticFormatting:
		return pluginMethodFormatting
	case pluginSemanticRangeFormatting:
		return pluginMethodRangeFormatting
	case pluginSemanticRename:
		return pluginMethodRename
	case pluginSemanticDocumentSymbols:
		return pluginMethodDocumentSymbols
	case pluginSemanticTokens:
		return pluginMethodSemanticTokens
	default:
		return pluginMethodCompletion
	}
}

// semanticPending is one submitted request whose answer has not arrived. The
// generation is checked on every hand-off so a result from a replaced document,
// session or trigger cannot change the window.
type semanticPending struct {
	kind         semanticKind
	generation   uint64
	project      *project
	server       *pluginServer
	documentID   int
	path         string
	uri          string
	revision     int
	line, column int
	// requireCaret says the request was placed at the caret, so a caret move
	// makes the answer stale. A modifier-click request uses the pointer instead.
	requireCaret bool
	// fromPointer marks a hover started by pointer movement; its anchor is the
	// pointer point rather than the caret cell.
	fromPointer bool
	anchor      gfx.Rect
	operation   string
}

// completionState is the explicit completion popup.
type completionState struct {
	open         bool
	items        []core.PluginSemanticCompletionItem
	selected     int
	offset       int
	documentID   int
	revision     int
	line, column int
}

// definitionState is the multi-target definition popup.
type definitionState struct {
	open    bool
	targets []core.PluginSemanticLocation
	// references marks a find-references list, which is shown even for a
	// single result instead of jumping.
	references bool
	selected   int
	offset     int
	documentID int
	revision   int
}

// hoverState is the hover popup.
type hoverState struct {
	open     bool
	contents string
	anchor   gfx.Rect
}

// hoverCandidate is the symbol under the resting pointer.
type hoverCandidate struct {
	active       bool
	documentID   int
	line, column int
	anchor       gfx.Rect
	// cancel ends the delay before the request. It is replaced or called when
	// the pointer moves, the document changes or the window closes.
	cancel context.CancelFunc
}

// pluginSemantics is the window's semantic state. It is touched only on the
// window thread; background work only reports back through post.
type pluginSemantics struct {
	project    *project
	documentID int
	generation uint64
	pending    []*semanticPending
	// deferred starts the user's request once the document's pending changes
	// have reached Core, so a definition never asks about stale text.
	deferred   func(*App)
	completion completionState
	definition definitionState
	hover      hoverState
	rename     renameState
	candidate  hoverCandidate
	hoverDelay time.Duration
	// autoDelay and autoCancel debounce automatic completion while typing.
	autoDelay  time.Duration
	autoCancel context.CancelFunc
	// autoGeneration names the newest debounce; an older wait that already
	// fired is ignored.
	autoGeneration uint64
}

// pluginSemanticHit is the open document whose text is id.
func (a *App) pluginSemanticHit(id gfx.ID) (*project, *document) {
	p := a.project
	if p == nil || id.IsZero() {
		return nil, nil
	}
	for _, d := range p.docs.list {
		if d.hit == id {
			return p, d
		}
	}
	return nil, nil
}

// currentSemanticDocument is the document a popup belongs to, and nil when the
// project, tab or session was replaced.
func (a *App) currentSemanticDocument(id int) (*project, *document) {
	p := a.project
	if p == nil || id <= 0 {
		return nil, nil
	}
	return p, p.docs.find(id)
}

// pluginSemanticsKey handles the keys an open semantic popup consumes. It is
// called before the editor, so a completion list can own Up, Down, Enter, Tab
// and Escape without changing how the text editor treats them.
func (a *App) pluginSemanticsKey(event gfx.KeyEvent) gfx.EventResult {
	if event.Release {
		return gfx.EventResult{}
	}
	if a.semantics.completion.open {
		return a.completionKey(event)
	}
	if a.semantics.definition.open {
		return a.definitionKey(event)
	}
	if a.semantics.hover.open && event.Key == gfx.KeyEscape {
		a.closeSemanticHover()
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	return gfx.EventResult{}
}

func (a *App) completionKey(event gfx.KeyEvent) gfx.EventResult {
	state := &a.semantics.completion
	switch event.Key {
	case gfx.KeyEscape:
		a.closeSemanticCompletion()
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyUp:
		if state.selected > 0 {
			state.selected--
			a.scrollCompletionWindow()
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyDown:
		if state.selected+1 < len(state.items) {
			state.selected++
			a.scrollCompletionWindow()
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyPageUp:
		state.selected = max(state.selected-visibleSemanticRows, 0)
		a.scrollCompletionWindow()
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyPageDown:
		state.selected = min(state.selected+visibleSemanticRows, max(len(state.items)-1, 0))
		a.scrollCompletionWindow()
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyEnter, gfx.KeyTab:
		if len(state.items) > 0 {
			a.acceptPluginCompletion(state.selected)
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		a.closeSemanticCompletion()
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	// Any other key ends the list and belongs to the editor.
	a.closeSemanticCompletion()
	return gfx.EventResult{}
}

func (a *App) definitionKey(event gfx.KeyEvent) gfx.EventResult {
	state := &a.semantics.definition
	switch event.Key {
	case gfx.KeyEscape:
		a.closeSemanticDefinition()
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyUp:
		if state.selected > 0 {
			state.selected--
			a.scrollDefinitionWindow()
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyDown:
		if state.selected+1 < len(state.targets) {
			state.selected++
			a.scrollDefinitionWindow()
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyPageUp:
		state.selected = max(state.selected-visibleSemanticRows, 0)
		a.scrollDefinitionWindow()
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyPageDown:
		state.selected = min(state.selected+visibleSemanticRows, max(len(state.targets)-1, 0))
		a.scrollDefinitionWindow()
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.KeyEnter, gfx.KeyTab:
		if len(state.targets) > 0 {
			a.choosePluginDefinition(state.selected)
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		a.closeSemanticDefinition()
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	return gfx.EventResult{}
}

// pluginSemanticsTrigger handles the unmodified keys that start a semantic
// operation for the editor that owns the keyboard.
func (a *App) pluginSemanticsTrigger(event gfx.KeyEvent, p *project, d *document) (gfx.EventResult, bool) {
	if event.Release || (event.Modifiers != 0 && event.Modifiers != gfx.ModifierShift) {
		return gfx.EventResult{}, false
	}
	if d == nil || d.view.IsComposing() {
		return gfx.EventResult{}, false
	}
	if event.Modifiers == gfx.ModifierShift {
		switch event.Key {
		case gfx.KeyF12:
			line, column := d.view.CaretUTF16()
			a.startPluginReferences(p, d, line, column)
			return gfx.EventResult{Handled: true, Repaint: true}, true
		case gfx.KeyF6:
			a.openPluginRename(p, d)
			return gfx.EventResult{Handled: true, Repaint: true}, true
		}
		return gfx.EventResult{}, false
	}
	switch event.Key {
	case gfx.KeyF12:
		line, column := d.view.CaretUTF16()
		a.startPluginDefinition(p, d, line, column, true)
		return gfx.EventResult{Handled: true, Repaint: true}, true
	case gfx.KeyF2:
		a.openPluginRename(p, d)
		return gfx.EventResult{Handled: true, Repaint: true}, true
	case gfx.KeyF1:
		line, column := d.view.CaretUTF16()
		rect, _ := d.view.CaretRect()
		a.startPluginHover(p, d, line, column, rect, false, true)
		return gfx.EventResult{Handled: true, Repaint: true}, true
	}
	return gfx.EventResult{}, false
}

// pluginSemanticsShortcut handles Control+Space, the explicit completion
// trigger. A platform may deliver it as a shortcut text without the key code,
// so the space text is accepted as well as KeySpace.
func (a *App) pluginSemanticsShortcut(event gfx.KeyEvent) gfx.EventResult {
	if result := a.pluginEditShortcut(event); result.Handled {
		return result
	}
	if event.Release || (event.Key != gfx.KeySpace && event.Text != " ") {
		return gfx.EventResult{}
	}
	if event.Modifiers != gfx.ModifierControl {
		return gfx.EventResult{}
	}
	p, d := a.pluginSemanticHit(event.Target)
	if d == nil || d.view.IsComposing() {
		return gfx.EventResult{}
	}
	line, column := d.view.CaretUTF16()
	a.startPluginCompletion(p, d, line, column)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// pluginSemanticsPointer handles modifier-click definition and pointer hover.
// It runs before the editor's own pointer handling.
func (a *App) pluginSemanticsPointer(event gfx.PointerEvent, p *project, d *document) (gfx.EventResult, bool) {
	switch event.Kind {
	case gfx.PointerDown:
		if a.semantics.completion.open || a.semantics.definition.open || a.semantics.hover.open {
			a.closePluginSemantics()
		}
		if d == nil || event.Button != gfx.PointerButtonPrimary {
			return gfx.EventResult{}, false
		}
		modifier := gfx.ModifierControl
		if runtime.GOOS == "darwin" {
			modifier = gfx.ModifierMeta
		}
		if event.Modifiers&modifier == 0 {
			return gfx.EventResult{}, false
		}
		line, column, ok := d.view.PositionAt(event.X, event.Y)
		if !ok {
			return gfx.EventResult{}, false
		}
		a.startPluginDefinition(p, d, line, column, false)
		return gfx.EventResult{Handled: true, Repaint: true}, true
	case gfx.PointerMove:
		if a.semantics.completion.open || a.semantics.definition.open {
			return gfx.EventResult{}, false
		}
		if d == nil {
			a.closeSemanticHover()
			a.cancelSemanticKind(pluginSemanticHover)
			return gfx.EventResult{}, false
		}
		line, column, ok := d.view.PositionAt(event.X, event.Y)
		if !ok {
			return gfx.EventResult{}, false
		}
		a.pointPluginHover(p, d, line, column, gfx.Rect{X: event.X + 12, Y: event.Y + 18})
		return gfx.EventResult{}, false
	case gfx.PointerExit:
		a.closeSemanticHover()
		a.cancelSemanticKind(pluginSemanticHover)
	}
	return gfx.EventResult{}, false
}

// scrollCompletionWindow keeps the selected row inside the virtualised window.
func (a *App) scrollCompletionWindow() {
	a.semantics.completion.offset = choiceOffset(a.semantics.completion.selected, len(a.semantics.completion.items), a.semantics.completion.offset)
}

func (a *App) scrollDefinitionWindow() {
	a.semantics.definition.offset = choiceOffset(a.semantics.definition.selected, len(a.semantics.definition.targets), a.semantics.definition.offset)
}

// choiceOffset is the first visible row for selected among total rows.
func choiceOffset(selected, total, current int) int {
	if total <= visibleSemanticRows {
		return 0
	}
	first := min(max(current, 0), total-visibleSemanticRows)
	if selected < first {
		first = selected
	} else if selected >= first+visibleSemanticRows {
		first = selected - visibleSemanticRows + 1
	}
	return min(max(first, 0), max(total-visibleSemanticRows, 0))
}

// startPluginDefinition asks for the definition at a position. A request that
// would race the document's pending changes waits for them first.
func (a *App) startPluginDefinition(p *project, d *document, line, column int, requireCaret bool) {
	a.startPluginLocations(pluginSemanticDefinition, p, d, line, column, requireCaret)
}

// startPluginReferences asks for every reference to the symbol at the caret.
func (a *App) startPluginReferences(p *project, d *document, line, column int) {
	a.startPluginLocations(pluginSemanticReferences, p, d, line, column, true)
}

// startPluginLocations asks for a location list (definition or references).
func (a *App) startPluginLocations(kind semanticKind, p *project, d *document, line, column int, requireCaret bool) {
	if a.plugins == nil || p == nil || d == nil || a.project != p {
		return
	}
	if d.view.IsComposing() {
		return
	}
	a.closeSemanticHover()
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	if !a.semanticDocumentReady(d) {
		a.deferSemantic(p, d, func(a *App) { a.startPluginLocations(kind, p, d, line, column, requireCaret) })
		a.startDocumentSync(p, d)
		return
	}
	server, ok := a.semanticServer(d)
	if !ok {
		return
	}
	if !server.isReady() {
		a.deferSemantic(p, d, func(a *App) { a.startPluginLocations(kind, p, d, line, column, requireCaret) })
		return
	}
	position := core.PluginDocumentPosition{Line: line, UTF16Column: column}
	a.cancelSemanticKind(kind)
	pending := a.newSemanticPending(kind, p, d, server, line, column, requireCaret, false)
	a.semantics.pending = append(a.semantics.pending, pending)
	request := core.PluginSemanticRequest{
		Operation: string(kind),
		URI:       d.sync.uri,
		Position:  &position,
	}
	a.submitSemantic(pending, request)
}

// startPluginHover asks for hover contents at a caret position.
func (a *App) startPluginHover(p *project, d *document, line, column int, anchor gfx.Rect, fromPointer, requireCaret bool) {
	if a.plugins == nil || p == nil || d == nil || a.project != p {
		return
	}
	if d.view.IsComposing() {
		return
	}
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	if !a.semanticDocumentReady(d) {
		a.deferSemantic(p, d, func(a *App) {
			a.startPluginHover(p, d, line, column, anchor, fromPointer, requireCaret)
		})
		a.startDocumentSync(p, d)
		return
	}
	server, ok := a.semanticServer(d)
	if !ok {
		return
	}
	if !server.isReady() {
		a.deferSemantic(p, d, func(a *App) {
			a.startPluginHover(p, d, line, column, anchor, fromPointer, requireCaret)
		})
		return
	}
	position := core.PluginDocumentPosition{Line: line, UTF16Column: column}
	a.cancelSemanticKind(pluginSemanticHover)
	pending := a.newSemanticPending(pluginSemanticHover, p, d, server, line, column, requireCaret, fromPointer)
	pending.anchor = anchor
	a.semantics.pending = append(a.semantics.pending, pending)
	request := core.PluginSemanticRequest{
		Operation: pluginSemanticHover,
		URI:       d.sync.uri,
		Position:  &position,
	}
	a.submitSemantic(pending, request)
}

// startPluginCompletion asks for an explicit completion list.
func (a *App) startPluginCompletion(p *project, d *document, line, column int) {
	a.requestPluginCompletion(p, d, line, column, completionTriggerContext(), false)
}

// requestPluginCompletion asks for a completion list with the given LSP trigger
// context. An automatic request (typing) is dropped instead of deferred when
// the caret has moved on, so a slow synchronization never opens a stale list.
func (a *App) requestPluginCompletion(p *project, d *document, line, column int, triggerContext json.RawMessage, automatic bool) {
	if a.plugins == nil || p == nil || d == nil || a.project != p {
		return
	}
	if d.view.IsComposing() {
		return
	}
	if automatic {
		if caretLine, caretColumn := d.view.CaretUTF16(); caretLine != line || caretColumn != column {
			return
		}
	}
	a.closeSemanticHover()
	a.closeSemanticDefinition()
	a.closeSemanticCompletion()
	retry := func(a *App) { a.requestPluginCompletion(p, d, line, column, triggerContext, automatic) }
	if !a.semanticDocumentReady(d) {
		a.deferSemantic(p, d, retry)
		a.startDocumentSync(p, d)
		return
	}
	server, ok := a.semanticServer(d)
	if !ok {
		return
	}
	if !server.isReady() {
		a.deferSemantic(p, d, retry)
		return
	}
	position := core.PluginDocumentPosition{Line: line, UTF16Column: column}
	a.cancelSemanticKind(pluginSemanticCompletion)
	pending := a.newSemanticPending(pluginSemanticCompletion, p, d, server, line, column, true, false)
	a.semantics.pending = append(a.semantics.pending, pending)
	request := core.PluginSemanticRequest{
		Operation:         pluginSemanticCompletion,
		URI:               d.sync.uri,
		Position:          &position,
		CompletionContext: triggerContext,
	}
	a.submitSemantic(pending, request)
}

// autoCompletionContext decides whether one edit is typing that should open
// completion. A character the server declared as a trigger asks as a trigger
// character; otherwise a single inserted identifier character asks for the
// invoked list. A server that declared no trigger characters is therefore asked
// only while an identifier is typed.
func autoCompletionContext(edit editorview.Edit, triggers []string) (json.RawMessage, bool) {
	if edit.StartLine != edit.EndLine || edit.StartColumn != edit.EndColumn {
		return nil, false
	}
	runes := []rune(edit.Text)
	if len(runes) != 1 {
		return nil, false
	}
	r := runes[0]
	for _, trigger := range triggers {
		if trigger == edit.Text {
			quoted, err := json.Marshal(trigger)
			if err != nil {
				return nil, false
			}
			return json.RawMessage(`{"triggerKind":2,"triggerCharacter":` + string(quoted) + `}`), true
		}
	}
	if r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) {
		return completionTriggerContext(), true
	}
	return nil, false
}

// applyServerFeatures records the completion trigger characters one session
// declared. Core re-sends the event when dynamic registrations change them, and
// leaves completionOptions out when completion is no longer offered.
func (a *App) applyServerFeatures(server *pluginServer, event core.BackendEvent) {
	if server == nil || server.session == nil || !a.isCurrentPluginServer(server.session.PluginID, server) {
		return
	}
	server.features = make(map[string]bool, len(event.Capabilities))
	for _, feature := range event.Capabilities {
		server.features[feature] = true
	}
	server.completionTriggers = nil
	if event.CompletionOptions != nil {
		server.completionTriggers = event.CompletionOptions.TriggerCharacters
	}
}

// scheduleAutoCompletion starts the debounce for one typed character. Each new
// edit cancels the previous wait, and the request is placed only if the caret
// is still where typing left it.
func (a *App) scheduleAutoCompletion(p *project, d *document, edit editorview.Edit) {
	if a.semantics.autoCancel != nil {
		a.semantics.autoCancel()
		a.semantics.autoCancel = nil
	}
	if a.plugins == nil || a.project != p || d.view.IsComposing() {
		return
	}
	server, ok := a.semanticServer(d)
	if !ok {
		return
	}
	trigger, ok := autoCompletionContext(edit, server.completionTriggers)
	if !ok {
		return
	}
	line, column := d.view.CaretUTF16()
	delay := a.semantics.autoDelay
	if delay == 0 {
		delay = semanticAutoCompletionDelay
	}
	ctx, cancel := context.WithCancel(p.ctx)
	a.semantics.autoCancel = cancel
	a.semantics.autoGeneration++
	generation := a.semantics.autoGeneration
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		if delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-ctx.Done():
				// log-exempt: 用户取消：继续输入、切换文档或关闭项目会取消防抖等待。
				return nil
			}
		}
		return func(a *App) {
			if a.semantics.autoGeneration != generation {
				return
			}
			a.requestPluginCompletion(p, d, line, column, trigger, true)
		}
	})
}

// completionTriggerContext asks the server for an explicit invocation. Core
// validates the context; the host does not decide which server feature answers.
func completionTriggerContext() json.RawMessage {
	return json.RawMessage(`{"triggerKind":1}`)
}

func (a *App) newSemanticPending(kind semanticKind, p *project, d *document, server *pluginServer, line, column int, requireCaret, fromPointer bool) *semanticPending {
	a.semantics.generation++
	a.semantics.project = p
	a.semantics.documentID = d.id
	return &semanticPending{
		kind:         kind,
		generation:   a.semantics.generation,
		project:      p,
		server:       server,
		documentID:   d.id,
		path:         d.path,
		uri:          d.sync.uri,
		revision:     d.view.Revision(),
		line:         line,
		column:       column,
		requireCaret: requireCaret,
		fromPointer:  fromPointer,
	}
}

func (a *App) submitSemantic(pending *semanticPending, request core.PluginSemanticRequest) {
	a.performed("editor.semantics."+string(pending.kind), surfaceShortcut)
	a.background(pending.project, semanticStartTimeout, func(ctx context.Context) func(*App) {
		operation, err := a.plugins.RequestLanguageSession(ctx, pending.server.session, request)
		return func(a *App) { a.semanticRequestStarted(pending, operation, err, ctx.Err()) }
	})
}

// semanticRequestStarted records Core's operation ID. An answer may have
// arrived before this hand-off; that answer settled the pending request and the
// late ID is cancelled instead of leaving a pending server operation.
func (a *App) semanticRequestStarted(pending *semanticPending, operation string, err, ctxErr error) {
	if !a.hasPending(pending) {
		if operation != "" {
			a.cancelSemanticOperation(pending, operation)
		}
		return
	}
	pending.operation = operation
	if err != nil {
		a.removePending(pending)
		if errors.Is(err, context.Canceled) || errors.Is(ctxErr, context.Canceled) {
			return
		}
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_semantics", err))
	}
}

// applyPluginSemanticEvent takes one completed request from a language server.
func (a *App) applyPluginSemanticEvent(server *pluginServer, event core.BackendEvent) {
	if a.project == nil || server == nil || server.session == nil {
		return
	}
	pending := a.matchPending(server, event)
	if pending == nil {
		// A late answer from a cancelled or replaced request. Core already
		// dropped operations it timed out; nothing may reopen a popup.
		return
	}
	a.removePending(pending)
	if pending.project != a.project || !a.isCurrentPluginServer(server.session.PluginID, server) {
		return
	}
	if len(event.Error) != 0 && string(event.Error) != "null" {
		a.logSemanticError(pending.kind, event.Error)
		if !a.applyEditorEvent(pending, event, true) {
			a.semanticOperationFailed(pending.kind)
		}
		return
	}
	if a.applyEditorEvent(pending, event, false) {
		return
	}
	switch pending.kind {
	case pluginSemanticDefinition, pluginSemanticReferences:
		a.applySemanticDefinition(pending, event)
	case pluginSemanticHover:
		a.applySemanticHover(pending, event)
	case pluginSemanticCompletion:
		a.applySemanticCompletion(pending, event)
	case pluginSemanticFormatting, pluginSemanticRangeFormatting:
		a.applySemanticFormatting(pending, event)
	case pluginSemanticRename:
		a.applySemanticRename(pending, event)
	}
}

func (a *App) matchPending(server *pluginServer, event core.BackendEvent) *semanticPending {
	if event.OperationID != "" {
		for _, pending := range a.semantics.pending {
			if pending.server == server && pending.operation == event.OperationID {
				return pending
			}
		}
	}
	for _, pending := range a.semantics.pending {
		if pending.server == server && pending.kind.method() == event.Method &&
			(pending.operation == "" || pending.operation == event.OperationID) {
			return pending
		}
	}
	return nil
}

func (a *App) applySemanticDefinition(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.view.Revision() != pending.revision || !a.semanticPositionCurrent(pending, d) {
		return
	}
	locations, err := core.PluginSemanticLocations(event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_semantics", err))
		return
	}
	references := pending.kind == pluginSemanticReferences
	limit := maxDefinitionTargets
	if references {
		limit = maxReferenceTargets
	}
	targets := a.usableDefinitionTargets(locations, limit)
	if len(targets) == 0 {
		switch {
		case len(locations) > 0:
			// Every target is outside the file system (a class in a jar):
			// say so instead of looking like an empty answer.
			a.notify(i18n.Shared(a.language(), "desktop.semantics.targetUnavailable"))
		case references:
			a.notify(i18n.Shared(a.language(), "desktop.semantics.noReferences"))
		default:
			a.notify(i18n.Shared(a.language(), "desktop.semantics.noDefinition"))
		}
		return
	}
	if len(targets) == 1 && !references {
		a.openDefinitionTarget(targets[0])
		return
	}
	a.semantics.definition = definitionState{
		open:       true,
		references: references,
		targets:    targets,
		documentID: d.id,
		revision:   pending.revision,
	}
}

func (a *App) applySemanticHover(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.view.Revision() != pending.revision || !a.semanticPositionCurrent(pending, d) {
		return
	}
	hover, err := core.PluginSemanticHoverFromEvent(event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_semantics", err))
		return
	}
	if hover == nil || hover.Contents == "" {
		a.closeSemanticHover()
		return
	}
	a.semantics.hover = hoverState{open: true, contents: truncateHover(hover.Contents), anchor: pending.anchor}
}

func (a *App) applySemanticCompletion(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.view.Revision() != pending.revision || !a.semanticPositionCurrent(pending, d) {
		return
	}
	items, _, err := core.PluginSemanticCompletions(event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_semantics", err))
		return
	}
	if len(items) > maxCompletionItems {
		items = items[:maxCompletionItems]
	}
	if len(items) == 0 {
		a.closeSemanticCompletion()
		return
	}
	a.semantics.completion = completionState{
		open:       true,
		items:      items,
		documentID: d.id,
		revision:   pending.revision,
		line:       pending.line,
		column:     pending.column,
	}
}

// semanticPositionCurrent says the trigger position still names the same place.
func (a *App) semanticPositionCurrent(pending *semanticPending, d *document) bool {
	if !pending.requireCaret {
		return true
	}
	line, column := d.view.CaretUTF16()
	return line == pending.line && column == pending.column
}

// usableDefinitionTargets drops targets this editor cannot open and collapses
// exact duplicates. A non-file URI (a class inside a jar) has no FilePath and
// is kept when a plugin registered a content provider for its scheme.
func (a *App) usableDefinitionTargets(locations []core.PluginSemanticLocation, limit int) []core.PluginSemanticLocation {
	targets := make([]core.PluginSemanticLocation, 0, min(len(locations), limit))
	seen := make(map[string]struct{}, len(locations))
	for _, location := range locations {
		if location.FilePath == "" && a.servedByContentProvider(location.URI) {
			// A class inside a jar: a plugin provides its text, shown read-only.
			key := location.URI + "\x00" + strconv.FormatInt(int64(location.Range.Start.Line), 10) + "\x00" + strconv.FormatInt(int64(location.Range.Start.UTF16Column), 10)
			if _, duplicate := seen[key]; !duplicate {
				seen[key] = struct{}{}
				targets = append(targets, location)
			}
			if len(targets) >= limit {
				break
			}
			continue
		}
		if location.FilePath == "" || !filepath.IsAbs(location.FilePath) {
			continue
		}
		key := location.FilePath + "\x00" + strconv.FormatInt(int64(location.Range.Start.Line), 10) + "\x00" + strconv.FormatInt(int64(location.Range.Start.UTF16Column), 10)
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		targets = append(targets, location)
		if len(targets) >= limit {
			break
		}
	}
	return targets
}

func (a *App) openDefinitionTarget(target core.PluginSemanticLocation) {
	p := a.project
	if p == nil {
		return
	}
	a.closePluginSemantics()
	if target.FilePath == "" {
		a.openContentTarget(p, target.URI, int(target.Range.Start.Line), int(target.Range.Start.UTF16Column))
		return
	}
	a.openFileAtPosition(p, target.FilePath, int(target.Range.Start.Line), int(target.Range.Start.UTF16Column))
}

func (a *App) choosePluginDefinition(index int) {
	state := &a.semantics.definition
	if index < 0 || index >= len(state.targets) {
		a.closeSemanticDefinition()
		return
	}
	a.openDefinitionTarget(state.targets[index])
}

// acceptPluginCompletion applies the selected completion through Core and
// closes the list. The submission runs off the window thread; the answer is
// applied only while the same document revision is still showing.
func (a *App) acceptPluginCompletion(index int) {
	state := &a.semantics.completion
	if index < 0 || index >= len(state.items) {
		a.closeSemanticCompletion()
		return
	}
	p, d := a.currentSemanticDocument(state.documentID)
	if d == nil || a.project != p {
		a.closeSemanticCompletion()
		return
	}
	item := state.items[index]
	documentID := state.documentID
	line, column := state.line, state.column
	revision := d.view.Revision()
	snapshot := d.view.TextSnapshot()
	a.closeSemanticCompletion()
	edits := a.prepareCompletionEdits(d, item, line, column)
	if len(edits) == 0 {
		return
	}
	a.background(p, semanticEditTimeout, func(ctx context.Context) func(*App) {
		applied, caret, err := a.applyCompletionEdits(ctx, snapshot.String(), edits)
		var change editorview.TextChange
		if err == nil {
			change = editorview.PrepareTextChange(snapshot, applied, caret)
		}
		return func(a *App) {
			current, document := a.currentSemanticDocument(documentID)
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_completion_apply", err))
				a.notify(i18n.Shared(a.language(), "desktop.semantics.completionFailed"))
				return
			}
			if current != p || document == nil || a.project != p || document.view.Revision() != revision {
				return
			}
			document.view.ApplyTextChange(change)
		}
	})
}

// preparedEdit is one completion edit with its original byte range, so the
// final caret survives edits that land before the primary edit (imports).
type preparedEdit struct {
	start, end int
	editRange  core.PluginDocumentRange
	text       string
	snippet    bool
	primary    bool
}

func (a *App) prepareCompletionEdits(d *document, item core.PluginSemanticCompletionItem, line, column int) []preparedEdit {
	snippet := item.InsertTextFormat == 2
	edits := make([]preparedEdit, 0, len(item.AdditionalTextEdits)+1)
	if item.TextEdit != nil {
		edit := item.TextEdit
		start, okStart := d.view.ByteOffset(int(edit.Range.Start.Line), int(edit.Range.Start.UTF16Column))
		end, okEnd := d.view.ByteOffset(int(edit.Range.End.Line), int(edit.Range.End.UTF16Column))
		if !okStart || !okEnd {
			return nil
		}
		edits = append(edits, preparedEdit{start: start, end: end, editRange: edit.Range, text: edit.NewText, snippet: snippet, primary: true})
	} else {
		at, ok := d.view.ByteOffset(line, column)
		if !ok {
			return nil
		}
		text := item.InsertText
		if text == "" {
			text = item.Label
		}
		position := core.PluginDocumentPosition{Line: line, UTF16Column: column}
		edits = append(edits, preparedEdit{
			start: at, end: at,
			editRange: core.PluginDocumentRange{Start: position, End: position},
			text:      text, snippet: snippet, primary: true,
		})
	}
	for _, additional := range item.AdditionalTextEdits {
		start, okStart := d.view.ByteOffset(int(additional.Range.Start.Line), int(additional.Range.Start.UTF16Column))
		end, okEnd := d.view.ByteOffset(int(additional.Range.End.Line), int(additional.Range.End.UTF16Column))
		if !okStart || !okEnd {
			continue
		}
		edits = append(edits, preparedEdit{start: start, end: end, editRange: additional.Range, text: additional.NewText, snippet: snippet})
	}
	return edits
}

// applyCompletionEdits converts snippets and applies the batch through Core.
// The caret is the primary edit's start shifted by every edit before it and the
// primary replacement itself.
func (a *App) applyCompletionEdits(ctx context.Context, text string, prepared []preparedEdit) (string, int, error) {
	edits := make([]core.PluginTextEdit, 0, len(prepared))
	replacements := make([]string, len(prepared))
	primaryStart := -1
	for i := range prepared {
		edit := &prepared[i]
		replacement := edit.text
		if edit.snippet {
			converted, err := a.kernel.PlainPluginSnippet(ctx, replacement)
			if err != nil {
				return "", 0, err
			}
			replacement = converted
		}
		replacements[i] = replacement
		if edit.primary {
			primaryStart = edit.start
		}
		edits = append(edits, core.PluginTextEdit{Range: edit.editRange, NewText: replacement})
	}
	if primaryStart < 0 {
		return "", 0, errors.New("completion has no primary edit")
	}
	applied, err := a.kernel.ApplyPluginTextEdits(ctx, text, edits)
	if err != nil {
		return "", 0, err
	}
	caret := primaryStart
	for i := range prepared {
		if prepared[i].primary {
			caret = primaryStart + len(replacements[i])
			break
		}
	}
	for i := range prepared {
		if prepared[i].primary {
			continue
		}
		if prepared[i].start == primaryStart && prepared[i].end == primaryStart {
			// A zero-length insertion at the primary start, such as an import
			// completion's additional edit, lands before the replacement and
			// shifts the caret with it.
			caret += len(replacements[i])
			continue
		}
		if prepared[i].start >= primaryStart {
			continue
		}
		caret += len(replacements[i]) - (prepared[i].end - prepared[i].start)
	}
	caret = min(max(caret, 0), len(applied))
	return applied, caret, nil
}

func (a *App) semanticDocumentReady(d *document) bool {
	if d == nil || !d.sync.opened || d.sync.uri == "" {
		return false
	}
	return !d.sync.running && !d.sync.full && len(d.sync.pending) == 0
}

func (a *App) semanticServer(d *document) (*pluginServer, bool) {
	if a.plugins == nil || d == nil {
		return nil, false
	}
	server, _ := a.documentSyncServer(d)
	if server == nil || server.session == nil || server.session.Documents == nil {
		return nil, false
	}
	return server, true
}

// deferSemantic runs one request after the document's pending changes reach
// Core. Only the newest request is kept; an older one is included in the newer
// request anyway.
func (a *App) deferSemantic(p *project, d *document, run func(*App)) {
	if p == nil || d == nil {
		return
	}
	a.semantics.project = p
	a.semantics.documentID = d.id
	a.semantics.deferred = run
}

// resumeDeferredSemantics is called when a document synchronization finishes.
func (a *App) resumeDeferredSemantics() {
	// The outline waits for the synchronization too, and asks again on the next frame.
	a.invalidator.Invalidate()
	run := a.semantics.deferred
	if run == nil {
		return
	}
	p, d := a.currentSemanticDocument(a.semantics.documentID)
	if p == nil || d == nil || !a.semanticDocumentReady(d) {
		return
	}
	server, ok := a.semanticServer(d)
	if !ok || !server.isReady() {
		return
	}
	a.semantics.deferred = nil
	run(a)
}

func (a *App) pointPluginHover(p *project, d *document, line, column int, anchor gfx.Rect) {
	candidate := &a.semantics.candidate
	if candidate.active && candidate.documentID == d.id && candidate.line == line && candidate.column == column {
		return
	}
	a.cancelSemanticKind(pluginSemanticHover)
	if candidate.cancel != nil {
		candidate.cancel()
	}
	*candidate = hoverCandidate{active: true, documentID: d.id, line: line, column: column, anchor: anchor}
	delay := a.semantics.hoverDelay
	if delay == 0 {
		delay = semanticHoverDelay
	}
	ctx, cancel := context.WithCancel(p.ctx)
	candidate.cancel = cancel
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		if delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-ctx.Done():
				// log-exempt: 用户取消：指针移动、切换文档或关闭项目会取消等待。
				return nil
			}
		}
		return func(a *App) {
			candidate := &a.semantics.candidate
			if !candidate.active || candidate.documentID != d.id || candidate.line != line || candidate.column != column {
				return
			}
			candidate.cancel = nil
			a.startPluginHover(p, d, line, column, anchor, true, false)
		}
	})
}

// pluginSemanticsCaretSync runs after keyboard and pointer work. A popup or
// request belongs to the caret it was opened at; moving the caret makes it
// stale and closes it.
func (a *App) pluginSemanticsCaretSync() {
	state := &a.semantics
	if state.project == nil || a.project != state.project {
		return
	}
	if state.completion.open {
		p, d := a.currentSemanticDocument(state.completion.documentID)
		if d == nil || p != a.project {
			a.closeSemanticCompletion()
			return
		}
		line, column := d.view.CaretUTF16()
		if d.view.Revision() != state.completion.revision || line != state.completion.line || column != state.completion.column {
			a.closeSemanticCompletion()
		}
	}
	if state.definition.open {
		p, d := a.currentSemanticDocument(state.definition.documentID)
		if d == nil || p != a.project || d.view.Revision() != state.definition.revision {
			a.closeSemanticDefinition()
		}
	}
	for _, pending := range append([]*semanticPending(nil), state.pending...) {
		if !pending.requireCaret {
			continue
		}
		p, d := a.currentSemanticDocument(pending.documentID)
		if d == nil || p != pending.project {
			a.cancelSemantic(pending)
			continue
		}
		if d.view.Revision() != pending.revision || !a.semanticPositionCurrent(pending, d) {
			a.cancelSemantic(pending)
		}
	}
}

// pluginSemanticsScrolled closes popups whose screen position the scroll moved.
func (a *App) pluginSemanticsScrolled(_ *document) {
	a.closeSemanticHover()
	a.cancelSemanticKind(pluginSemanticHover)
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
}

// pluginSemanticsEdited closes popups and requests when one document's text
// changes. The request's original positions no longer describe the document.
func (a *App) pluginSemanticsEdited(d *document) {
	if d == nil || a.semantics.documentID != d.id {
		return
	}
	a.closePluginSemantics()
}

// pluginSemanticsDocumentClosed drops state that belonged to a closed tab.
func (a *App) pluginSemanticsDocumentClosed(d *document) {
	if d == nil || a.semantics.documentID != d.id {
		return
	}
	a.closePluginSemantics()
}

// pluginSemanticsReset drops every popup, deferred request and pending
// operation, for a project switch or a stopped server.
func (a *App) pluginSemanticsReset() {
	a.closePluginSemantics()
	a.cancelSemanticKind(pluginSemanticRename)
	a.semantics.rename = renameState{}
	a.semantics.deferred = nil
	a.semantics.project = nil
	a.semantics.documentID = 0
	a.semantics.hoverDelay = 0
	a.semantics.autoDelay = 0
}

func (a *App) closePluginSemantics() {
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	a.closeSemanticHover()
	a.cancelSemanticKind(pluginSemanticDefinition)
	a.cancelSemanticKind(pluginSemanticHover)
	a.cancelSemanticKind(pluginSemanticCompletion)
	a.cancelSemanticKind(pluginSemanticReferences)
	a.cancelSemanticKind(pluginSemanticFormatting)
	a.cancelSemanticKind(pluginSemanticRangeFormatting)
	if a.semantics.candidate.cancel != nil {
		a.semantics.candidate.cancel()
	}
	a.semantics.candidate = hoverCandidate{}
	if a.semantics.autoCancel != nil {
		a.semantics.autoCancel()
		a.semantics.autoCancel = nil
	}
	a.semantics.autoGeneration++
}

func (a *App) closeSemanticCompletion() {
	a.semantics.completion = completionState{}
}

func (a *App) closeSemanticDefinition() {
	a.semantics.definition = definitionState{}
}

func (a *App) closeSemanticHover() {
	a.semantics.hover = hoverState{}
}

// cancelSemanticKind drops pending operations of one kind and asks Core to
// cancel the ones that already have an operation ID.
func (a *App) cancelSemanticKind(kind semanticKind) {
	for _, pending := range append([]*semanticPending(nil), a.semantics.pending...) {
		if pending.kind == kind {
			a.cancelSemantic(pending)
		}
	}
}

func (a *App) cancelSemantic(pending *semanticPending) {
	if pending == nil || !a.removePending(pending) {
		return
	}
	if pending.operation != "" {
		a.cancelSemanticOperation(pending, pending.operation)
	}
}

func (a *App) cancelSemanticOperation(pending *semanticPending, operation string) {
	if a.plugins == nil || pending == nil || pending.server == nil || pending.server.session == nil {
		return
	}
	session := pending.server.session
	a.background(pending.project, semanticCancelTimeout, func(ctx context.Context) func(*App) {
		// log-exempt: 取消：过期结果已被 generation 丢弃，取消失败不影响界面状态。
		_ = a.plugins.CancelLanguageOperation(ctx, session, operation)
		return nil
	})
}

func (a *App) hasPending(pending *semanticPending) bool {
	for _, candidate := range a.semantics.pending {
		if candidate == pending {
			return true
		}
	}
	return false
}

func (a *App) removePending(pending *semanticPending) bool {
	for i, candidate := range a.semantics.pending {
		if candidate == pending {
			a.semantics.pending = append(a.semantics.pending[:i], a.semantics.pending[i+1:]...)
			return true
		}
	}
	return false
}

// logSemanticError records Core's stable error code without copying server
// internals into the user's log.
func (a *App) logSemanticError(kind semanticKind, raw json.RawMessage) {
	var failure struct {
		Code string `json:"code"`
	}
	fields := map[string]any{"operation": "plugin_semantics", "request": string(kind)}
	if err := json.Unmarshal(raw, &failure); err == nil && failure.Code != "" {
		fields["code"] = failure.Code
	}
	a.emit(operationFailedLevel, operationFailedEvent, fields)
}

func truncateHover(contents string) string {
	if len(contents) <= maxHoverBytes {
		return contents
	}
	cut := maxHoverBytes
	for cut > 0 && (contents[cut]&0xc0) == 0x80 {
		cut--
	}
	return contents[:cut]
}

func (a *App) definitionLabel(target core.PluginSemanticLocation) string {
	path := target.FilePath
	if a.project != nil {
		if relative, err := filepath.Rel(a.project.root, path); err == nil && relative != ".." && !filepath.IsAbs(relative) {
			path = relative
		}
	}
	return path + ":" + strconv.FormatInt(int64(target.Range.Start.Line)+1, 10) + ":" + strconv.FormatInt(int64(target.Range.Start.UTF16Column)+1, 10)
}

func semanticWindow(selected, total int) (int, int) {
	if total <= visibleSemanticRows {
		return 0, total
	}
	first := choiceOffset(selected, total, selected-visibleSemanticRows/2)
	return first, min(first+visibleSemanticRows, total)
}

func popupOrigin(x, y, width float32, bounds gfx.Rect) (float32, float32) {
	if width > bounds.Width-8 {
		width = bounds.Width - 8
	}
	x = min(max(x, bounds.X+4), max(bounds.X+bounds.Width-width-4, bounds.X+4))
	y = min(max(y, bounds.Y+4), max(bounds.Y+bounds.Height-8, bounds.Y+4))
	return x, y
}

// definitionPopupTitle is the accessibility title of the open location list.
func (a *App) definitionPopupTitle(references bool) string {
	if references {
		return i18n.Shared(a.language(), "desktop.semantics.references")
	}
	return i18n.Shared(a.language(), "desktop.semantics.definitions")
}
