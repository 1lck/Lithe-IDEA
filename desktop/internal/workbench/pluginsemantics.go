package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
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
	pluginSemanticImplementation  = "implementation"
	pluginSemanticHover           = "hover"
	pluginSemanticCompletion      = "completion"
	pluginSemanticReferences      = "references"
	pluginSemanticFormatting      = "formatting"
	pluginSemanticRangeFormatting = "rangeFormatting"
	pluginSemanticRename          = "rename"
	// The LSP methods Core reports on a completed event. They are matched only
	// against the host's own pending operation, never used to derive a rule.
	pluginMethodDefinition      = "textDocument/definition"
	pluginMethodImplementation  = "textDocument/implementation"
	pluginMethodHover           = "textDocument/hover"
	pluginMethodCompletion      = "textDocument/completion"
	pluginMethodReferences      = "textDocument/references"
	pluginMethodFormatting      = "textDocument/formatting"
	pluginMethodRangeFormatting = "textDocument/rangeFormatting"
	pluginMethodRename          = "textDocument/rename"
	featureImplementation       = "implementation"

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

	semanticDefinitionWidth = float32(480)
	semanticRowHeight       = float32(24)
	semanticPopupPad        = float32(4)
	// semanticHoverDelay is how long the pointer rests on a symbol before the
	// hover request starts. 300 ms matches the default of Zed and VS Code
	// (editor.hover.delay); the delay is most of what the user waits, since a
	// warm language server answers within a few milliseconds and Core keeps
	// repeated answers (#1995). Negative lets tests exercise it without a
	// clock wait.
	semanticHoverDelay = 300 * time.Millisecond
	// semanticAutoCompletionDelay is the typing pause before automatic
	// completion asks. Negative lets tests skip the clock wait.
	semanticAutoCompletionDelay = 120 * time.Millisecond
)

// semanticKind is one editor semantic operation.
type semanticKind string

func (k semanticKind) method() string {
	switch k {
	case pluginSemanticCodeActions:
		return pluginMethodCodeActions
	case pluginSemanticResolveCodeAction:
		return pluginMethodResolveCodeAction
	case pluginSemanticExecuteCommand:
		return pluginMethodExecuteCommand
	case pluginSemanticSignatureHelp:
		return pluginMethodSignatureHelp
	case pluginSemanticInlayHints:
		return pluginMethodInlayHints
	case pluginSemanticResolveInlayHint:
		return pluginMethodResolveInlayHint
	case pluginSemanticDefinition:
		return pluginMethodDefinition
	case pluginSemanticImplementation:
		return pluginMethodImplementation
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
	case pluginSemanticDocumentSymbols, pluginSemanticCopyReference:
		return pluginMethodDocumentSymbols
	case pluginSemanticTokens:
		return pluginMethodSemanticTokens
	case pluginSemanticDocumentLinks:
		return pluginMethodDocumentLinks
	case pluginSemanticDocumentHighlight:
		return pluginMethodDocumentHighlight
	case pluginSemanticWorkspaceSymbols:
		return pluginMethodWorkspaceSymbols
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
	// row under the pointer rather than the caret cell.
	fromPointer bool
	// automatic marks a completion the editor asked for while the user typed.
	automatic bool
	anchor    gfx.Rect
	operation string
	// cancelProvider stops a standalone provider call, which has no LSP operation ID.
	cancelProvider context.CancelFunc
	// join is set on the language-server side of an explicit completion that also asks a
	// plugin completion provider; the answer feeds the join instead of opening the popup.
	join *completionMergeJoin
	// usages marks the references request of a go-to-declaration gesture made on the
	// declaration itself: its answer, without the declaration, opens a single usage or lists
	// several, as IntelliJ IDEA's Go to Declaration or Usages does, instead of filling the
	// References tool window.
	usages bool
}

type earlySemanticResult struct {
	server *pluginServer
	event  core.BackendEvent
}

const maxEarlySemanticResults = 32

// completionState is the editor's completion popup.
type completionState struct {
	open         bool
	automatic    bool
	items        []core.PluginSemanticCompletionItem
	selected     int
	offset       int
	documentID   int
	revision     int
	line, column int
	// incomplete says the server's list was cut short: what the user types next is asked again
	// rather than filtered from these items.
	incomplete bool
}

// definitionState is the multi-target definition or implementation popup.
type definitionState struct {
	open       bool
	kind       semanticKind
	targets    []core.PluginSemanticLocation
	selected   int
	offset     int
	documentID int
	revision   int
	anchor     *gfx.Rect
}

// hoverState is the hover popup (pluginsemantics_hover.go).
type hoverState struct {
	open     bool
	contents string
	// anchor is the row (pointer) or caret (keyboard) the popup is placed under; rect is where
	// the popup was declared last.
	anchor gfx.Rect
	rect   gfx.Rect
	// documentID, line, start and end are the hovered symbol, as UTF-16 columns: while the
	// pointer stays on it no new hover is asked for.
	documentID int
	line       int
	start, end int
	// fromPointer marks a hover the pointer opened, which closes once the pointer has left
	// the symbol and the popup.
	fromPointer bool
	page        *hoverPage
	quickFix    *core.PluginDocumentRange
}

// hoverCandidate is the symbol under the resting pointer. It stays after its hover was asked for,
// so moving within the character does not ask again, and is cleared once the pointer leaves the
// text (leaveSemanticHover).
type hoverCandidate struct {
	active       bool
	documentID   int
	line, column int
	anchor       gfx.Rect
	// cancel ends the delay before the request. It is replaced or called when
	// the pointer moves or leaves the text, the document changes or the window closes.
	cancel context.CancelFunc
}

// pluginSemantics is the window's semantic state. It is touched only on the
// window thread; background work only reports back through post.
type pluginSemantics struct {
	project    *project
	documentID int
	generation uint64
	pending    []*semanticPending
	// A result may reach the window before the submission acknowledgement.
	// IDs keep those answers apart from requests for the same document and method.
	early []earlySemanticResult
	// deferred starts the user's request once the document's pending changes
	// have reached Core, so a definition never asks about stale text.
	deferred   func(*App)
	completion completionState
	// startingCompletion is the manual request waiting for language-server discovery to finish.
	startingCompletion *semanticPending
	// merge is the explicit completion whose language-server and provider answers are pending.
	merge         *completionMergeJoin
	definition    definitionState
	hover         hoverState
	codeActions   codeActionsState
	signatureHelp signatureHelpState
	sigCancel     context.CancelFunc
	sigDelay      time.Duration
	sigGeneration uint64
	sigDeferred   func(*App)
	inlayHover    inlayHintHoverState
	inlayDelay    time.Duration
	rename        renameState
	candidate     hoverCandidate
	hoverDelay    time.Duration
	// hoverHideDelay overrides semanticHoverHideDelay; hideCancel ends the pending close of a
	// pointer hover and hideToken names the newest one, so an older wait that fired is ignored.
	hoverHideDelay time.Duration
	hideCancel     context.CancelFunc
	hideToken      uint64
	// hoverColors turns code tokens into the hover popup's code colors.
	hoverColors hoverPalette
	// autoDelay and autoCancel debounce automatic completion while typing.
	autoDelay  time.Duration
	autoCancel context.CancelFunc
	// autoGeneration guards automatic work even after the debounce has fired.
	autoGeneration       uint64
	symbolHighlights     symbolHighlightState
	symbolHighlightDelay time.Duration
}

// pluginSemanticHit is the open document whose text, or editable preview, is id.
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
	return a.previewDocumentHit(id)
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
	if a.semantics.codeActions.open {
		return a.codeActionsKey(event)
	}
	if a.semantics.completion.open {
		return a.completionKey(event)
	}
	if a.semantics.definition.open {
		return a.definitionKey(event)
	}
	if result := a.signatureHelpKey(event); result.Handled {
		return result
	}
	if a.semantics.inlayHover.open && event.Key == gfx.KeyEscape {
		a.semantics.inlayHover = inlayHintHoverState{}
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if a.semantics.hover.open && event.Key == gfx.KeyEscape {
		a.leaveSemanticHover()
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
	if d == nil || d.caretView().IsComposing() {
		return gfx.EventResult{}, false
	}
	if event.Modifiers == gfx.ModifierShift {
		switch event.Key {
		case gfx.KeyF12:
			line, column := d.caretView().CaretUTF16()
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
		line, column := d.caretView().CaretUTF16()
		a.startPluginDefinition(p, d, line, column, true)
		return gfx.EventResult{Handled: true, Repaint: true}, true
	case gfx.KeyF2:
		a.openPluginRename(p, d)
		return gfx.EventResult{Handled: true, Repaint: true}, true
	case gfx.KeyF1:
		line, column := d.caretView().CaretUTF16()
		rect, _ := d.caretView().CaretRect()
		a.startPluginHover(p, d, line, column, rect, false, true)
		return gfx.EventResult{Handled: true, Repaint: true}, true
	}
	return gfx.EventResult{}, false
}

// pluginSemanticsShortcut handles Control+Space, the explicit completion
// trigger. A platform may deliver it as a shortcut text without the key code,
// so the space text is accepted as well as KeySpace.
func (a *App) pluginSemanticsShortcut(event gfx.KeyEvent) gfx.EventResult {
	if result := a.codeActionsShortcut(event); result.Handled {
		return result
	}
	if result := a.signatureHelpShortcut(event); result.Handled {
		return result
	}
	if result := a.pluginEditShortcut(event); result.Handled {
		return result
	}
	if result := a.implementationShortcut(event); result.Handled {
		return result
	}
	if result := a.superDeclarationShortcut(event); result.Handled {
		return result
	}
	if result := a.declarationShortcut(event); result.Handled {
		return result
	}
	if event.Release || (event.Key != gfx.KeySpace && event.Text != " ") {
		return gfx.EventResult{}
	}
	if event.Modifiers != gfx.ModifierControl {
		return gfx.EventResult{}
	}
	p, d := a.pluginSemanticHit(event.Target)
	if d == nil || d.caretView().IsComposing() {
		return gfx.EventResult{}
	}
	line, column := d.caretView().CaretUTF16()
	a.startPluginCompletion(p, d, line, column)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// declarationShortcut handles Go to Declaration or Usages, IntelliJ IDEA's Command+B (Control+B
// elsewhere), at the caret of the editor that owns the keyboard. It is the keyboard form of
// the modifier-click and asks the same definition request.
func (a *App) declarationShortcut(event gfx.KeyEvent) gfx.EventResult {
	if event.Release || event.Modifiers != primaryModifier() || !strings.EqualFold(event.Text, "b") {
		return gfx.EventResult{}
	}
	p, d := a.pluginSemanticHit(event.Target)
	if d == nil || d.caretView().IsComposing() {
		return gfx.EventResult{}
	}
	line, column := d.caretView().CaretUTF16()
	a.startPluginDefinition(p, d, line, column, true)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// implementationShortcut handles Go to Implementation(s), Command+Option+B on macOS or
// Control+Alt+B elsewhere, at the caret of the editor that owns the keyboard.
func (a *App) implementationShortcut(event gfx.KeyEvent) gfx.EventResult {
	want := gfx.ModifierControl | gfx.ModifierAlt
	if runtime.GOOS == "darwin" {
		want = gfx.ModifierMeta | gfx.ModifierAlt
	}
	if event.Release || event.Modifiers != want || !strings.EqualFold(event.Text, "b") {
		return gfx.EventResult{}
	}
	p, d := a.pluginSemanticHit(event.Target)
	if d == nil || d.caretView().IsComposing() {
		return gfx.EventResult{}
	}
	line, column := d.caretView().CaretUTF16()
	a.startPluginImplementation(p, d, line, column, true)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// superDeclarationShortcut handles Go to Super Declaration, Command+U on macOS or Control+U
// elsewhere, using the gutter's upward navigation actions for the caret line.
func (a *App) superDeclarationShortcut(event gfx.KeyEvent) gfx.EventResult {
	if event.Release || event.Modifiers != primaryModifier() || !strings.EqualFold(event.Text, "u") {
		return gfx.EventResult{}
	}
	p, d := a.pluginSemanticHit(event.Target)
	if d == nil || d.caretView().IsComposing() {
		return gfx.EventResult{}
	}
	a.triggerGoToSuper(p, d)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// pluginSemanticsPointer handles modifier-click definition, modifier+alt-click implementation, and
// pointer hover over view, the document's own editor or its editable preview. It runs before the
// view's own pointer handling.
func (a *App) pluginSemanticsPointer(event gfx.PointerEvent, p *project, d *document, view *editorview.View) (gfx.EventResult, bool) {
	switch event.Kind {
	case gfx.PointerDown:
		a.leaveSemanticHover()
		if a.semantics.codeActions.open || a.semantics.completion.open || a.semantics.definition.open || a.semantics.hover.open {
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
		line, column, ok := view.PositionAt(event.X, event.Y)
		if !ok {
			return gfx.EventResult{}, false
		}
		if event.Modifiers&gfx.ModifierAlt != 0 {
			a.startPluginImplementation(p, d, line, column, false)
		} else {
			a.startPluginDefinition(p, d, line, column, false)
		}
		return gfx.EventResult{Handled: true, Repaint: true}, true
	case gfx.PointerMove:
		if a.semantics.codeActions.open || a.semantics.completion.open || a.semantics.definition.open {
			return gfx.EventResult{}, false
		}
		if d == nil {
			a.leaveSemanticHover()
			return gfx.EventResult{}, false
		}
		if _, _, _, hit := view.LineIconAt(event.X, event.Y); hit {
			a.leaveSemanticHover()
			return gfx.EventResult{}, false
		}
		line, column, ok := view.PositionAt(event.X, event.Y)
		if !ok {
			a.leaveSemanticHover()
			return gfx.EventResult{}, false
		}
		// The pointer moving along the hovered symbol keeps the popup where it is instead of
		// asking again for every character; leaving it starts the popup's close.
		if a.hoverCovers(d, line, column) {
			a.holdSemanticHover()
			return gfx.EventResult{}, false
		}
		a.releaseSemanticHover()
		a.pointPluginHover(p, d, line, column, hoverRowAnchor(view, event.X, event.Y))
		return gfx.EventResult{}, false
	case gfx.PointerExit:
		a.leaveSemanticHover()
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
	a.startPluginLocations(pluginSemanticDefinition, p, d, line, column, requireCaret, false)
}

// startPluginImplementation asks the language server for implementations at a position, or falls
// back to the gutter's downward navigation actions when the server offers none.
func (a *App) startPluginImplementation(p *project, d *document, line, column int, requireCaret bool) {
	a.cancelContentOpen()
	if a.plugins == nil || p == nil || d == nil || a.project != p {
		return
	}
	if d.caretView().IsComposing() {
		return
	}
	a.closeSemanticHover()
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	server, ok := a.semanticServer(d)
	if !ok {
		a.triggerNavigationLaneAction(p, d, line, "navigate-down")
		return
	}
	if !a.semanticDocumentReady(d) {
		a.deferSemantic(p, d, func(a *App) { a.startPluginImplementation(p, d, line, column, requireCaret) })
		a.startDocumentSync(p, d)
		return
	}
	if !server.isReady() {
		a.deferSemantic(p, d, func(a *App) { a.startPluginImplementation(p, d, line, column, requireCaret) })
		return
	}
	if !server.features[featureImplementation] {
		a.triggerNavigationLaneAction(p, d, line, "navigate-down")
		return
	}
	a.submitSemanticLocations(pluginSemanticImplementation, p, d, server, line, column, requireCaret, false)
}

// triggerGoToSuper jumps to the super declaration or interface of the caret line using the
// gutter's upward navigation actions.
func (a *App) triggerGoToSuper(p *project, d *document) {
	if p == nil || d == nil || a.project != p || d.caretView().IsComposing() {
		return
	}
	a.closeSemanticHover()
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	line, _ := d.caretView().CaretUTF16()
	a.triggerNavigationLaneAction(p, d, line, "navigate-up")
}

func (a *App) triggerNavigationLaneAction(p *project, d *document, line int, lane string) {
	choices := editorActionChoices(d.actions, line, lane)
	var anchor *gfx.Rect
	if rect, ok := d.caretView().CaretRect(); ok {
		anchor = &rect
	}
	switch len(choices) {
	case 0:
		if lane == "navigate-up" {
			a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noSuperDeclaration"))
		} else {
			a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noImplementations"))
		}
	case 1:
		a.runEditorActionAt(p, d, choices[0].action, choices[0].alternative, anchor)
	default:
		a.clearEditorActionHover(d)
		d.actionPanel.menuLine, d.actionPanel.menuLane, d.actionPanel.menuOpen = line, lane, true
		if anchor != nil {
			d.actionPanel.menuAt = *anchor
		} else {
			d.actionPanel.menuAt = d.lastArea
		}
	}
}

// startPluginReferences asks for every reference to the symbol at the caret.
func (a *App) startPluginReferences(p *project, d *document, line, column int) {
	a.startPluginLocations(pluginSemanticReferences, p, d, line, column, true, false)
}

// startPluginUsages asks for the usages of the declaration a go-to-declaration gesture was
// made on, without the declaration itself.
func (a *App) startPluginUsages(p *project, d *document, line, column int, requireCaret bool) {
	a.startPluginLocations(pluginSemanticReferences, p, d, line, column, requireCaret, true)
}

// startPluginLocations asks for a location list (definition, implementation or references); usages
// marks the references of a declaration a go-to-declaration gesture was made on.
func (a *App) startPluginLocations(kind semanticKind, p *project, d *document, line, column int, requireCaret, usages bool) {
	a.cancelContentOpen()
	if a.plugins == nil || p == nil || d == nil || a.project != p {
		return
	}
	if d.caretView().IsComposing() {
		return
	}
	a.closeSemanticHover()
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	if kind == pluginSemanticDefinition && a.startProviderDefinition(p, d, line, column) {
		return
	}
	if !a.semanticDocumentReady(d) {
		a.deferSemantic(p, d, func(a *App) { a.startPluginLocations(kind, p, d, line, column, requireCaret, usages) })
		a.startDocumentSync(p, d)
		return
	}
	server, ok := a.semanticServer(d)
	if !ok {
		return
	}
	if !server.isReady() {
		a.deferSemantic(p, d, func(a *App) { a.startPluginLocations(kind, p, d, line, column, requireCaret, usages) })
		return
	}
	a.submitSemanticLocations(kind, p, d, server, line, column, requireCaret, usages)
}

func (a *App) submitSemanticLocations(kind semanticKind, p *project, d *document, server *pluginServer, line, column int, requireCaret, usages bool) {
	position := core.PluginDocumentPosition{Line: line, UTF16Column: column}
	a.cancelSemanticKind(kind)
	pending := a.newSemanticPending(kind, p, d, server, line, column, requireCaret, false)
	pending.usages = usages
	a.semantics.pending = append(a.semantics.pending, pending)
	request := core.PluginSemanticRequest{
		Operation: string(kind),
		URI:       d.sync.uri,
		Position:  &position,
	}
	if usages {
		includeDeclaration := false
		request.IncludeDeclaration = &includeDeclaration
	}
	a.submitSemantic(pending, request)
}

// startPluginHover asks for hover contents at a caret position.
func (a *App) startPluginHover(p *project, d *document, line, column int, anchor gfx.Rect, fromPointer, requireCaret bool) {
	if a.plugins == nil || p == nil || d == nil || a.project != p {
		return
	}
	if d.caretView().IsComposing() {
		return
	}
	if fromPointer && (a.semantics.codeActions.open || a.semantics.completion.open || a.semantics.definition.open) {
		return
	}
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	if diag, ok := a.diagnosticAt(d, line, column); ok && !d.view.ReadOnly() {
		span := core.PluginDocumentRange{
			Start: core.PluginDocumentPosition{Line: diag.Range.Start.Line, UTF16Column: diag.Range.Start.UTF16Column},
			End:   core.PluginDocumentPosition{Line: diag.Range.End.Line, UTF16Column: diag.Range.End.UTF16Column},
		}
		a.cancelSemanticKind(pluginSemanticHover)
		a.semantics.project, a.semantics.documentID = p, d.id
		a.showSemanticHover(p, d, diag.Message, false, line, column, &span, anchor, fromPointer)
		a.semantics.hover.quickFix = &span
		return
	}
	if !a.semanticDocumentReady(d) {
		a.deferSemantic(p, d, func(a *App) {
			a.startPluginHover(p, d, line, column, anchor, fromPointer, requireCaret)
		})
		a.startDocumentSync(p, d)
		return
	}
	server, ok := a.semanticServer(d)
	if !ok {
		a.startProviderHover(p, d, line, column, anchor, fromPointer)
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

// startProviderHover shows a plugin hover provider's text when no language server serves the document.
// A language server that is ready keeps its own hover, since a plugin's text would show twice.
func (a *App) startProviderHover(p *project, d *document, line, column int, anchor gfx.Rect, fromPointer bool) {
	if a.plugins == nil || d == nil || d.virtual || d.path == "" {
		return
	}
	if !a.plugins.HasHoverProvider(p.root, d.path, d.languageID) {
		return
	}
	revision, id, path, language, root, plugins := d.view.Revision(), strconv.Itoa(d.id), d.path, d.languageID, p.root, a.plugins
	a.cancelSemanticKind(pluginSemanticHover)
	a.background(p, 15*time.Second, func(ctx context.Context) func(*App) {
		contents, err := plugins.PluginHover(ctx, root, path, language, id, revision, line, column)
		return func(a *App) {
			if p.docs.find(d.id) != d || d.view.Revision() != revision {
				return
			}
			if err != nil {
				a.backgroundFailed("plugin_provider", err)
				return
			}
			if contents == "" {
				a.closeSemanticHover()
				return
			}
			a.showSemanticHover(p, d, contents, true, line, column, nil, anchor, fromPointer)
		}
	})
}

// startPluginCompletion asks for an explicit completion list.
func (a *App) startPluginCompletion(p *project, d *document, line, column int) {
	a.stopAutoCompletion()
	a.semantics.deferred = nil
	a.requestPluginCompletion(p, d, line, column, completionTriggerContext(), false)
}

// requestPluginCompletion asks for a completion list with the given LSP trigger
// context. An automatic request (typing) is dropped instead of deferred when
// the caret has moved on, so a slow synchronization never opens a stale list.
func (a *App) requestPluginCompletion(p *project, d *document, line, column int, triggerContext json.RawMessage, automatic bool) {
	if a.plugins == nil || p == nil || d == nil || a.project != p {
		return
	}
	if d.caretView().IsComposing() {
		return
	}
	if automatic {
		if a.settings.DisableAutoCompletion {
			return
		}
		if caretLine, caretColumn := d.caretView().CaretUTF16(); caretLine != line || caretColumn != column {
			return
		}
	}
	a.closeSemanticHover()
	a.closeSemanticDefinition()
	a.closeSemanticCompletion()
	server, ok := a.semanticServer(d)
	if !ok && !automatic {
		if a.languageServerStarting(d.languageID) {
			a.semantics.startingCompletion = a.newSemanticPending(pluginSemanticCompletion, p, d, nil, line, column, true, false)
			return
		}
		// A standalone provider reads the editor document directly.
		if a.startProviderCompletion(p, d, line, column, false, nil) {
			return
		}
	}
	generation := a.semantics.autoGeneration
	revision := d.view.Revision()
	retry := func(a *App) {
		if (!automatic || a.semantics.autoGeneration == generation) && completionPositionCurrent(d, revision, line, column) {
			a.requestPluginCompletion(p, d, line, column, triggerContext, automatic)
		}
	}
	if !a.semanticDocumentReady(d) {
		a.deferSemantic(p, d, retry)
		a.startDocumentSync(p, d)
		return
	}
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
	pending.automatic = automatic
	if join := a.newCompletionMergeJoin(p, d, line, column, automatic); join != nil {
		pending.join = join
		a.startProviderCompletion(p, d, line, column, false, join)
	}
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
	server.signatureHelpTriggers = nil
	server.signatureHelpRetriggers = nil
	if options := event.SignatureHelpOptions; options != nil {
		server.signatureHelpTriggers = options.TriggerCharacters
		server.signatureHelpRetriggers = options.RetriggerCharacters
	}
	// The features arrive after the documents opened: ask for the colors now.
	a.semanticTokensResume()
	a.resumeSymbolHighlights()
	if server.features[featureWorkspaceSymbols] {
		a.resumeEverywhereSymbols(server.project)
	}
}

// scheduleAutoCompletion starts the debounce for one typed character. Each new
// edit cancels the previous wait, and the request is placed only if the caret
// is still where typing left it.
func (a *App) scheduleAutoCompletion(p *project, d *document, edit editorview.Edit) {
	if a.settings.DisableAutoCompletion {
		return
	}
	a.stopAutoCompletion()
	if a.plugins == nil || a.project != p || d.caretView().IsComposing() {
		return
	}
	// An incomplete list is asked again on every word character typed while it is open.
	if completion := a.semantics.completion; completion.open && completion.incomplete && completion.documentID == d.id && isWordInsert(edit) {
		line, column := d.caretView().CaretUTF16()
		a.requestPluginCompletion(p, d, line, column, completionTriggerContext(), true)
		return
	}
	server, ok := a.semanticServer(d)
	providerOnly := !ok
	var triggers []string
	if providerOnly {
		// Without a language server, a plugin's completion provider asks on the characters it declared.
		triggers = a.plugins.CompletionTriggers(p.root, d.path, d.languageID)
		if len(triggers) == 0 {
			return
		}
	} else {
		triggers = server.completionTriggers
	}
	trigger, ok := autoCompletionContext(edit, triggers)
	if !ok {
		return
	}
	line, column := d.caretView().CaretUTF16()
	delay := a.semantics.autoDelay
	if delay == 0 {
		delay = semanticAutoCompletionDelay
	}
	ctx, cancel := context.WithCancel(p.ctx)
	a.semantics.autoCancel = cancel
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
			if providerOnly {
				a.startProviderCompletion(p, d, line, column, true, nil)
				return
			}
			a.requestPluginCompletion(p, d, line, column, trigger, true)
		}
	})
}

func (a *App) setDisableAutoCompletion(disabled bool) {
	if a.settings.DisableAutoCompletion == disabled {
		return
	}
	a.settings.DisableAutoCompletion = disabled
	if disabled {
		a.stopAutoCompletion()
		if a.semantics.completion.automatic {
			a.closeSemanticCompletion()
		}
		for _, pending := range slices.Clone(a.semantics.pending) {
			if pending.kind == pluginSemanticCompletion && pending.automatic {
				a.cancelSemantic(pending)
			}
		}
	}
	a.saveSettings()
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

// submitSemantic sends one request to the language server. A request the user asked for is an
// action of its own; a hover under the moving pointer and a completion while typing are the
// editor's, and stay part of whatever action is current.
func (a *App) submitSemantic(pending *semanticPending, request core.PluginSemanticRequest) {
	if !pending.fromPointer && !pending.automatic {
		a.performed("editor.semantics."+string(pending.kind), surfaceShortcut)
	}
	a.background(pending.project, semanticStartTimeout, func(ctx context.Context) func(*App) {
		operation, err := a.plugins.RequestLanguageSession(ctx, pending.server.session, request)
		return func(a *App) { a.semanticRequestStarted(pending, operation, err, ctx.Err()) }
	})
}

// semanticRequestStarted binds Core's operation ID to the submitted request.
// If an answer arrived first, only this ID's result can settle the request.
func (a *App) semanticRequestStarted(pending *semanticPending, operation string, err, ctxErr error) {
	result, received := a.takeEarlySemanticResult(pending.server, operation)
	if !a.hasPending(pending) {
		if operation != "" {
			a.cancelSemanticOperation(pending, operation)
		}
		return
	}
	pending.operation = operation
	if err != nil {
		a.removePending(pending)
		if pending.kind == pluginSemanticWorkspaceSymbols {
			pending.project.everywhereSymbols.pending = removePendingEntry(pending.project.everywhereSymbols.pending, pending)
		}
		a.settleMergeSide(pending.join, true, nil, false)
		if pending.kind == pluginSemanticCopyReference {
			a.applyReferenceSymbols(pending, core.BackendEvent{}, true)
		}
		if errors.Is(err, context.Canceled) || errors.Is(ctxErr, context.Canceled) {
			return
		}
		// A request the server never received fails like one it refused: formatting and rename
		// tell the user, the others go without.
		if pending.kind.toldToUser() {
			a.operationFailed("plugin_semantics", err)
			if !a.applyEditorEvent(pending, core.BackendEvent{}, true) {
				a.semanticOperationFailed(pending.kind)
			}
		} else {
			a.backgroundFailed("plugin_semantics", err)
			if pending.kind == pluginSemanticInlayHints || pending.kind == pluginSemanticResolveInlayHint || pending.kind == pluginSemanticDocumentHighlight {
				a.applyEditorEvent(pending, core.BackendEvent{}, true)
			}
		}
		return
	}
	if received {
		a.applyPluginSemanticEvent(pending.server, result)
	}
}

// applyPluginSemanticEvent takes one completed request from a language server.
func (a *App) applyPluginSemanticEvent(server *pluginServer, event core.BackendEvent) {
	if a.project == nil || server == nil || server.session == nil {
		return
	}
	pending := a.matchPending(server, event)
	if pending == nil {
		a.queueEarlySemanticResult(server, event)
		return
	}
	a.removePending(pending)
	if pending.project != a.project || !a.isCurrentPluginServer(server.session.PluginID, server) {
		a.settleMergeSide(pending.join, true, nil, false)
		return
	}
	if len(event.Error) != 0 && string(event.Error) != "null" {
		a.logSemanticError(pending.kind, event.Error)
		a.settleMergeSide(pending.join, true, nil, false)
		if !a.applyEditorEvent(pending, event, true) {
			a.semanticOperationFailed(pending.kind)
		}
		return
	}
	if a.applyEditorEvent(pending, event, false) {
		return
	}
	switch pending.kind {
	case pluginSemanticDefinition, pluginSemanticImplementation, pluginSemanticReferences:
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
	for _, pending := range a.semantics.pending {
		if pending.server == server && pending.operation != "" && pending.operation == event.OperationID {
			return pending
		}
	}
	return nil
}

func (a *App) queueEarlySemanticResult(server *pluginServer, event core.BackendEvent) {
	if event.OperationID == "" {
		return
	}
	for _, pending := range a.semantics.pending {
		if pending.server != server || pending.operation != "" || pending.kind.method() != event.Method ||
			(event.URI != "" && event.URI != pending.uri) {
			continue
		}
		early := &a.semantics.early
		if len(*early) == maxEarlySemanticResults {
			*early = slices.Delete(*early, 0, 1)
		}
		*early = append(*early, earlySemanticResult{server: server, event: event})
		return
	}
}

func (a *App) takeEarlySemanticResult(server *pluginServer, operation string) (core.BackendEvent, bool) {
	early := &a.semantics.early
	for i, result := range *early {
		if result.server == server && result.event.OperationID == operation {
			*early = slices.Delete(*early, i, i+1)
			return result.event, true
		}
	}
	return core.BackendEvent{}, false
}

func (a *App) applySemanticDefinition(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.view.Revision() != pending.revision || !a.semanticPositionCurrent(pending, d) {
		return
	}
	locations, err := core.PluginSemanticLocations(event)
	if err != nil {
		a.backgroundFailed("plugin_semantics", err)
		return
	}
	if pending.usages {
		a.presentUsages(p, d, a.usableDefinitionTargets(locations, maxReferenceTargets), len(locations), pending.revision)
		return
	}
	if pending.kind == pluginSemanticReferences {
		targets := a.usableDefinitionTargets(locations, maxReferenceTargets)
		if len(targets) == 0 {
			a.presentDefinitionTargets(p, d, pending.kind, targets, len(locations), pending.revision)
			return
		}
		// Find Usages fills the References tool window, which keeps the answer while the
		// user works through it, instead of a popup that closes on the first click. The
		// window's tab names what was searched for, and Rerun asks at the same place again.
		query := referenceQuery{documentID: d.id, line: pending.line, column: pending.column}
		a.showReferences(p, targets, query, identifierAt(d.view.TextSnapshot(), d.view, pending.line, pending.column))
		return
	}
	if pending.kind == pluginSemanticImplementation {
		targets := a.usableDefinitionTargets(locations, maxDefinitionTargets)
		a.presentDefinitionTargets(p, d, pluginSemanticImplementation, targets, len(locations), pending.revision)
		return
	}
	if a.plugins != nil && a.plugins.HasDefinitionProvider(p.root, d.path, d.languageID) {
		a.mergeProviderDefinitions(p, d, pending, locations)
		return
	}
	targets := a.usableDefinitionTargets(locations, maxDefinitionTargets)
	a.presentDefinitionOrUsages(p, d, pending.line, pending.column, pending.requireCaret, targets, len(locations), pending.revision)
}

// presentDefinitionOrUsages finishes a go-to-declaration gesture (Command+B, modifier-click,
// F12, the editor menu) the way IntelliJ IDEA's Go to Declaration or Usages does. From a use it
// opens the declaration; when Core finds the answer is the declaration the gesture was made on,
// it asks for that declaration's usages instead of jumping to where the caret already is.
func (a *App) presentDefinitionOrUsages(p *project, d *document, line, column int, requireCaret bool, targets []core.PluginSemanticLocation, answered, revision int) {
	if a.gestureOnDeclaration(d, line, column, targets) {
		a.startPluginUsages(p, d, line, column, requireCaret)
		return
	}
	a.presentDefinitionTargets(p, d, pluginSemanticDefinition, targets, answered, revision)
}

// gestureOnDeclaration asks Core whether every definition target is the place the gesture was
// made at. A failed decision is logged and the definition answer is presented as before.
func (a *App) gestureOnDeclaration(d *document, line, column int, targets []core.PluginSemanticLocation) bool {
	kernel, ok := a.kernel.(editorKernel)
	if !ok || len(targets) == 0 {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	position := core.PluginDocumentPosition{Line: line, UTF16Column: column}
	usages, err := kernel.DeclarationOrUsages(ctx, d.sync.uri, position, targets)
	if err != nil {
		a.backgroundFailed("editor_declaration_or_usages", err)
		return false
	}
	return usages
}

// presentUsages shows the usages of a declaration a go-to-declaration gesture was made on: a
// single usage opens, several wait in the list, and none says so.
func (a *App) presentUsages(p *project, d *document, targets []core.PluginSemanticLocation, answered, revision int) {
	if len(targets) == 0 && answered == 0 {
		a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noReferences"))
		return
	}
	a.presentDefinitionTargets(p, d, pluginSemanticDefinition, targets, answered, revision)
}

// mergeProviderDefinitions asks the definition provider for its locations and lets Core merge them with
// the language server's, the server's first. The merged list is presented as one answer.
func (a *App) mergeProviderDefinitions(p *project, d *document, pending *semanticPending, server []core.PluginSemanticLocation) {
	revision, id, path, language, root, plugins := pending.revision, strconv.Itoa(d.id), d.path, d.languageID, p.root, a.plugins
	line, column, uri, requireCaret := pending.line, pending.column, d.sync.uri, pending.requireCaret
	a.background(p, 25*time.Second, func(ctx context.Context) func(*App) {
		provided, err := plugins.PluginDefinitions(ctx, root, path, language, id, revision, line, column)
		var merged []core.PluginSemanticLocation
		if err == nil {
			merged, err = plugins.MergeDefinitions(ctx, uri, line, column, server, provided)
		}
		return func(a *App) {
			if p.docs.find(d.id) != d || d.view.Revision() != revision {
				return
			}
			if err != nil {
				a.backgroundFailed("plugin_provider", err)
				merged = server
			}
			a.presentDefinitionOrUsages(p, d, line, column, requireCaret, a.usableDefinitionTargets(merged, maxDefinitionTargets), len(merged), revision)
		}
	})
}

// presentDefinitionTargets shows the locations of a definition or implementation answer, from a
// language server or a plugin provider: one target opens, several wait in the list anchored at the
// caret, and nothing found says so.
func (a *App) presentDefinitionTargets(p *project, d *document, kind semanticKind, targets []core.PluginSemanticLocation, answered int, revision int) {
	a.presentDefinitionTargetsAt(p, d, kind, targets, answered, revision, nil)
}

func (a *App) presentDefinitionTargetsAt(p *project, d *document, kind semanticKind, targets []core.PluginSemanticLocation, answered int, revision int, anchor *gfx.Rect) {
	if len(targets) == 0 {
		switch {
		case answered > 0:
			// Every target is outside the file system (a class in a jar):
			// say so instead of looking like an empty answer.
			a.operationRejected("plugin_navigation", "target_outside_file_system")
			a.notifyError(i18n.Shared(a.language(), "desktop.semantics.targetUnavailable"))
		case kind == pluginSemanticReferences:
			a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noReferences"))
		case kind == pluginSemanticImplementation:
			a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noImplementations"))
		default:
			a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noDefinition"))
		}
		return
	}
	if len(targets) == 1 {
		a.openDefinitionTarget(targets[0])
		return
	}
	var anchorCopy *gfx.Rect
	if anchor != nil {
		rect := *anchor
		anchorCopy = &rect
	}
	a.leaveSemanticHover()
	a.closeSemanticHover()
	a.semantics.project = p
	a.semantics.documentID = d.id
	a.semantics.definition = definitionState{
		open:       true,
		kind:       kind,
		targets:    targets,
		documentID: d.id,
		revision:   revision,
		anchor:     anchorCopy,
	}
}

// startProviderDefinition asks a plugin's definition provider when no language server serves the
// document. It reports whether a provider took the request; with a server, the server answers alone
// for now, because merging provider locations with the server's answer is not wired yet.
func (a *App) startProviderDefinition(p *project, d *document, line, column int) bool {
	if a.plugins == nil || p == nil || d == nil || d.virtual || d.path == "" {
		return false
	}
	if _, serverOK := a.semanticServer(d); serverOK {
		return false
	}
	if !a.plugins.HasDefinitionProvider(p.root, d.path, d.languageID) {
		return false
	}
	revision, id, path, language, root, plugins := d.view.Revision(), strconv.Itoa(d.id), d.path, d.languageID, p.root, a.plugins
	a.background(p, 20*time.Second, func(ctx context.Context) func(*App) {
		locations, err := plugins.PluginDefinitions(ctx, root, path, language, id, revision, line, column)
		return func(a *App) {
			if p.docs.find(d.id) != d || d.view.Revision() != revision {
				return
			}
			if err != nil {
				a.backgroundFailed("plugin_provider", err)
				return
			}
			targets := a.usableDefinitionTargets(locations, maxDefinitionTargets)
			a.presentDefinitionTargets(p, d, pluginSemanticDefinition, targets, len(locations), revision)
		}
	})
	return true
}

func (a *App) applySemanticHover(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.view.Revision() != pending.revision || !a.semanticPositionCurrent(pending, d) {
		return
	}
	hover, err := core.PluginSemanticHoverFromEvent(event)
	if err != nil {
		a.backgroundFailed("plugin_semantics", err)
		return
	}
	if hover == nil || hover.Contents == "" {
		a.closeSemanticHover()
		return
	}
	a.showSemanticHover(p, d, hover.Contents, hover.IsMarkdown, pending.line, pending.column, hover.Range, pending.anchor, pending.fromPointer)
}

func (a *App) applySemanticCompletion(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	stale := p != pending.project || d == nil || d.view.Revision() != pending.revision || !a.semanticPositionCurrent(pending, d)
	if pending.join != nil {
		a.settleServerCompletion(pending, event, stale)
		return
	}
	if stale {
		return
	}
	items, incomplete, err := core.PluginSemanticCompletions(event)
	if err != nil {
		a.backgroundFailed("plugin_semantics", err)
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
		automatic:  pending.automatic,
		items:      items,
		documentID: d.id,
		revision:   pending.revision,
		line:       pending.line,
		column:     pending.column,
		incomplete: incomplete,
	}
}

// startProviderCompletion asks the plugin completion provider. A join receives the answer as
// one of its two sides instead of opening the popup itself. It reports whether a call was started.
func (a *App) startProviderCompletion(p *project, d *document, line, column int, automatic bool, join *completionMergeJoin) bool {
	if a.plugins == nil || d == nil || d.virtual || d.path == "" || !a.plugins.HasCompletionProvider(p.root, d.path, d.languageID) {
		a.settleMergeSide(join, false, nil, false)
		return false
	}
	var standalone *semanticPending
	if join == nil {
		a.closeSemanticCompletion()
		a.cancelSemanticKind(pluginSemanticCompletion)
		standalone = a.newSemanticPending(pluginSemanticCompletion, p, d, nil, line, column, true, false)
		standalone.automatic = automatic
		a.semantics.pending = append(a.semantics.pending, standalone)
	}
	generation := a.semantics.autoGeneration
	revision, id, path, language, root, plugins := d.view.Revision(), strconv.Itoa(d.id), d.path, d.languageID, p.root, a.plugins
	cancel := a.background(p, 15*time.Second, func(ctx context.Context) func(*App) {
		items, err := plugins.PluginCompletions(ctx, root, path, language, id, revision, line, column)
		return func(a *App) {
			if standalone != nil {
				// log-exempt: 用户取消：光标移动、切换标签或新请求会取消旧候选。
				if !a.removePending(standalone) || (automatic && a.semantics.autoGeneration != generation) ||
					!completionPositionCurrent(d, revision, line, column) {
					return
				}
			}
			if p.docs.find(d.id) != d || d.view.Revision() != revision {
				a.settleMergeSide(join, false, nil, false)
				return
			}
			if err != nil {
				a.backgroundFailed("plugin_provider", err)
				a.settleMergeSide(join, false, nil, false)
				return
			}
			if join != nil {
				a.settleMergeSide(join, false, items, false)
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
				open: true, automatic: automatic, items: items, documentID: d.id,
				revision: revision, line: line, column: column,
			}
		}
	})
	if standalone != nil {
		standalone.cancelProvider = cancel
	}
	return true
}

func completionPositionCurrent(d *document, revision, line, column int) bool {
	if d == nil || d.view.Revision() != revision || d.caretView().IsComposing() {
		return false
	}
	caretLine, caretColumn := d.caretView().CaretUTF16()
	return line == caretLine && column == caretColumn
}

// semanticPositionCurrent says the trigger position still names the same place.
func (a *App) semanticPositionCurrent(pending *semanticPending, d *document) bool {
	if !pending.requireCaret {
		return true
	}
	line, column := d.caretView().CaretUTF16()
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
	if a.project != p || !completionPositionCurrent(d, state.revision, state.line, state.column) {
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
				a.operationFailed("plugin_completion_apply", err)
				a.notifyError(i18n.Shared(a.language(), "desktop.semantics.completionFailed"))
				return
			}
			if current != p || document == nil || a.project != p || document.view.Revision() != revision {
				return
			}
			document.caretView().ApplyTextChange(change)
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

// resumeStartingCompletion runs at document sync or when discovery ends without a server.
func (a *App) resumeStartingCompletion(p *project, languageID string) {
	waiting := a.semantics.startingCompletion
	if waiting == nil || waiting.project != p || a.project != p || a.languageServerStarting(languageID) {
		return
	}
	d := p.docs.find(waiting.documentID)
	if d != nil && d.languageID != languageID {
		return
	}
	a.semantics.startingCompletion = nil
	if completionPositionCurrent(d, waiting.revision, waiting.line, waiting.column) {
		a.requestPluginCompletion(p, d, waiting.line, waiting.column, completionTriggerContext(), false)
	}
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
	a.semanticTokensResume()
	a.resumeSymbolHighlights()
	if waiting := a.semantics.startingCompletion; waiting != nil {
		p, d := a.currentSemanticDocument(waiting.documentID)
		if p == waiting.project && a.semanticDocumentReady(d) {
			a.resumeStartingCompletion(p, d.languageID)
		}
	}
	if a.semantics.deferred == nil && a.semantics.sigDeferred == nil {
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
	run, sigRun := a.semantics.deferred, a.semantics.sigDeferred
	a.semantics.deferred, a.semantics.sigDeferred = nil, nil
	if run != nil {
		run(a)
	}
	if sigRun != nil {
		sigRun(a)
	}
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
	if a.contentOpen != nil && !a.contentOpen.current(a) {
		a.cancelContentOpen()
	}
	state := &a.semantics
	if state.project == nil || a.project != state.project {
		return
	}
	a.syncSignatureHelpCaret()
	if state.codeActions.open {
		p, d := a.currentSemanticDocument(state.codeActions.documentID)
		if d == nil || p != a.project || d.view.Revision() != state.codeActions.revision || d.caretView().IsComposing() {
			a.closeSemanticCodeActions()
			a.cancelSemanticKind(pluginSemanticResolveCodeAction)
		}
	}
	if state.completion.open {
		p, d := a.currentSemanticDocument(state.completion.documentID)
		if p != a.project || !completionPositionCurrent(d, state.completion.revision, state.completion.line, state.completion.column) {
			a.closeSemanticCompletion()
		}
	}
	if waiting := state.startingCompletion; waiting != nil {
		p, d := a.currentSemanticDocument(waiting.documentID)
		if p != waiting.project || !completionPositionCurrent(d, waiting.revision, waiting.line, waiting.column) {
			state.startingCompletion = nil
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

// pluginSemanticsScrolled closes popups whose screen position the scroll moved. A hover still
// waiting would open at the place its character scrolled away from.
func (a *App) pluginSemanticsScrolled(d *document) {
	a.clearEditorActionHover(d)
	a.semantics.inlayHover = inlayHintHoverState{}
	a.closeSemanticCodeActions()
	a.cancelSemanticKind(pluginSemanticResolveCodeAction)
	a.leaveSemanticHover()
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
}

// pluginSemanticsEdited closes popups and requests when one document's text
// changes. The request's original positions no longer describe the document.
func (a *App) pluginSemanticsEdited(d *document) {
	if d != nil && a.semantics.symbolHighlights.key.document == d {
		a.clearSymbolHighlights()
	}
	if p := a.project; p != nil && d != nil {
		a.semanticTokensEdited(p, d)
		a.clearDocumentInlayHints(d)
	}
	if d == nil || a.semantics.documentID != d.id {
		return
	}
	// Keep the previous signature answer while the typing hook refreshes it.
	a.closePositionSemantics()
}

// pluginSemanticsDocumentClosed drops state that belonged to a closed tab.
func (a *App) pluginSemanticsDocumentClosed(d *document) {
	if d != nil && a.semantics.symbolHighlights.key.document == d {
		a.clearSymbolHighlights()
	}
	if a.contentOpen != nil && a.contentOpen.source == d {
		a.cancelContentOpen()
	}
	if d == nil || a.semantics.documentID != d.id {
		return
	}
	a.closePluginSemantics()
}

// pluginSemanticsReset drops transient popups and their deferred work. Callers
// separately release server-owned editor requests or the entire project's work.
func (a *App) pluginSemanticsReset() {
	a.closePluginSemantics()
	a.cancelSemanticKind(pluginSemanticRename)
	a.semantics.rename = renameState{}
	// A single server's release can leave other editor requests alive. Keep
	// their replies when Core answered before the operation ID was bound.
	early := a.semantics.early
	a.semantics.early = nil
	for _, result := range early {
		a.queueEarlySemanticResult(result.server, result.event)
	}
	a.semantics.deferred = nil
	a.semantics.project = nil
	a.semantics.documentID = 0
	a.semantics.hoverDelay = 0
	a.semantics.hoverHideDelay = 0
	a.semantics.autoDelay = 0
}

func (a *App) closePluginSemantics() {
	a.closeSemanticSignatureHelp()
	a.cancelSemanticKind(pluginSemanticExecuteCommand)
	a.closePositionSemantics()
}

func (a *App) closePositionSemantics() {
	a.closeSemanticCodeActions()
	a.semantics.inlayHover = inlayHintHoverState{}
	a.cancelSemanticKind(pluginSemanticCodeActions)
	a.cancelSemanticKind(pluginSemanticResolveCodeAction)
	a.cancelContentOpen()
	a.closeSemanticCompletion()
	a.closeSemanticDefinition()
	a.closeSemanticHover()
	a.cancelSemanticKind(pluginSemanticDefinition)
	a.cancelSemanticKind(pluginSemanticImplementation)
	a.cancelSemanticKind(pluginSemanticHover)
	a.cancelSemanticKind(pluginSemanticCompletion)
	a.cancelSemanticKind(pluginSemanticReferences)
	a.cancelSemanticKind(pluginSemanticFormatting)
	a.cancelSemanticKind(pluginSemanticRangeFormatting)
	a.dropHoverCandidate()
	a.stopAutoCompletion()
}

func (a *App) stopAutoCompletion() {
	if a.semantics.autoCancel != nil {
		a.semantics.autoCancel()
		a.semantics.autoCancel = nil
	}
	a.semantics.autoGeneration++
}

func (a *App) closeSemanticCompletion() {
	a.semantics.completion = completionState{}
	a.semantics.startingCompletion = nil
	if a.semantics.merge != nil {
		a.semantics.merge.closed = true
		a.semantics.merge = nil
	}
}

func (a *App) closeSemanticDefinition() {
	a.semantics.definition = definitionState{}
}

func (a *App) closeSemanticHover() {
	a.stopSemanticHoverHide()
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
	if pending.cancelProvider != nil {
		pending.cancelProvider()
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
		// log-exempt: 预期的缺失：取消只在会话已经结束时失败；过期结果已由 generation 丢弃。
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

// logSemanticError records that the language server failed a request, with the error's stable
// code and never its message, which can quote the user's code. The code is the JSON-RPC
// number or the plugin's token; anything else is recorded as unknown.
func (a *App) logSemanticError(kind semanticKind, raw json.RawMessage) {
	var failure struct {
		Code json.RawMessage `json:"code"`
	}
	code := any("unknown")
	if json.Unmarshal(raw, &failure) == nil {
		var number int64
		var token string
		switch {
		case json.Unmarshal(failure.Code, &number) == nil:
			code = number
		case json.Unmarshal(failure.Code, &token) == nil && logToken.MatchString(token):
			code = token
		}
	}
	fields := map[string]any{
		"operation":    "plugin_semantics." + string(kind),
		"error":        "the language server failed the " + kind.method() + " request",
		"error_code":   code,
		"error_domain": "lsp",
	}
	if kind.toldToUser() {
		a.emit(operationFailedLevel, operationFailedEvent, fields)
	} else {
		a.emit(backgroundFailedLevel, backgroundFailedEvent, fields)
	}
}

// toldToUser says a failed request of this kind is told to the user (semanticOperationFailed),
// so it is a notification failure. The other requests fail quietly: the editor goes without the
// hover, completion or location, and the failure is a background one.
func (k semanticKind) toldToUser() bool {
	switch k {
	case pluginSemanticFormatting, pluginSemanticRangeFormatting, pluginSemanticRename,
		pluginSemanticCodeActions, pluginSemanticResolveCodeAction, pluginSemanticExecuteCommand:
		return true
	}
	return false
}

// logToken is the catalog's token type: what a token field accepts.
var logToken = regexp.MustCompile(`^[A-Za-z0-9._:/$-]{1,64}$`)

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
func (a *App) definitionPopupTitle() string {
	if a.semantics.definition.kind == pluginSemanticImplementation {
		return i18n.Shared(a.language(), "desktop.semantics.implementations")
	}
	return i18n.Shared(a.language(), "desktop.semantics.definitions")
}

// isWordInsert reports whether an edit types one identifier character at the caret.
func isWordInsert(edit editorview.Edit) bool {
	if edit.StartLine != edit.EndLine || edit.StartColumn != edit.EndColumn {
		return false
	}
	runes := []rune(edit.Text)
	if len(runes) != 1 {
		return false
	}
	r := runes[0]
	return r == '_' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}
