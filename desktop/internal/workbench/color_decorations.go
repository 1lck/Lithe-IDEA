package workbench

import (
	"cmp"
	"context"
	"errors"
	"slices"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// colorDecorationsState owns each open document's foreground overlays and bracket index.
// These are independent of the language server's semantic tokens.
type colorDecorationsState struct {
	docs map[int]*documentColorDecorations
}

// documentColorDecorations is one document's color pipeline: whether a provider serves it, the
// pause after an edit and the request in flight. A keystroke only restarts the pause: it neither
// looks up providers nor starts a worker, and the view keeps the colors it moved with the edit
// until the answer for the new text replaces them.
type documentColorDecorations struct {
	// provided is whether a provider serves the document at path in language. known is false
	// until it is looked up and again when a color provider registers or withdraws; a new path or
	// language is looked up again too.
	path, language  string
	known, provided bool
	// timer starts the request once typing pauses, and cancel ends the request in flight.
	timer  *time.Timer
	cancel context.CancelFunc
	// generation counts the requests planned and revoked, so that a timer or an answer overtaken
	// by a newer edit, request or withdrawal changes nothing.
	generation uint64
	// Bracket offsets are valid only for the view and revision the worker analyzed.
	bracketMatches  []bracketMatch
	bracketView     *editorview.View
	bracketRevision int
}

type bracketMatch struct {
	offset uint32
	mate   uint32
}

const (
	colorDecorationsDelay   = 250 * time.Millisecond
	colorDecorationsTimeout = 20 * time.Second
)

// revoke stops the pending request and the one in flight.
func (s *documentColorDecorations) revoke() {
	s.generation++
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
}

// scheduleColorDecorations asks the providers for the document's colors after delay, replacing
// the request already pending or running. The colors the view moved with an edit stay until the
// answer for the new text replaces them; colors chosen under another path, language or set of
// color providers, or for a document no provider serves any longer, go at once.
func (a *App) scheduleColorDecorations(p *project, d *document, delay time.Duration) {
	if p == nil || d == nil || d.view == nil || a.project != p {
		return
	}
	docs := a.editor.colorDecorations.docs
	if docs == nil {
		docs = make(map[int]*documentColorDecorations)
		a.editor.colorDecorations.docs = docs
	}
	state := docs[d.id]
	if state == nil {
		state = &documentColorDecorations{}
		docs[d.id] = state
	}
	state.revoke()
	if !builtinBracketMatchingServes(d) || state.path != d.path || state.language != d.languageID ||
		state.bracketView != d.view || state.bracketRevision != d.view.Revision() {
		state.bracketMatches = nil
		state.bracketView = nil
		d.view.SetBracketHighlights(-1, -1)
	}
	providerServes := a.colorDecorationsServed(p, d, state)
	if !providerServes && !builtinBracketMatchingServes(d) {
		d.view.ClearColorDecorations()
		return
	}
	if delay <= 0 {
		a.requestColorDecorations(p, d, state)
		return
	}
	generation := state.generation
	state.timer = time.AfterFunc(delay, func() {
		a.post(func(a *App) {
			if a.project == p && p.docs.find(d.id) == d && a.editor.colorDecorations.docs[d.id] == state && state.generation == generation {
				state.timer = nil
				a.requestColorDecorations(p, d, state)
			}
		})
	})
}

// colorDecorationsServed reports whether a provider serves the document as it is now. Only a
// document within the snapshot limit is sent to providers, and the providers are looked up once
// per path, language and change of the color providers, not on every keystroke.
func (a *App) colorDecorationsServed(p *project, d *document, state *documentColorDecorations) bool {
	if d.virtual || d.view.TextSnapshot().Len() > pluginservice.DocumentSnapshotMaxBytes {
		return false
	}
	if !state.known || state.path != d.path || state.language != d.languageID {
		d.view.ClearColorDecorations()
		state.path, state.language, state.known = d.path, d.languageID, true
		state.provided = a.plugins != nil && a.plugins.HasColorDecorationsProvider(p.root, d.path, d.languageID)
	}
	return state.provided
}

// requestColorDecorations asks the providers for the colors of the current text. Preparation
// reads an immutable text snapshot on the worker; the window applies only its latest answer.
func (a *App) requestColorDecorations(p *project, d *document, state *documentColorDecorations) {
	ctx, cancel := context.WithTimeout(a.operationContext(p.ctx), colorDecorationsTimeout)
	state.cancel = cancel
	generation := state.generation
	view, text, revision := d.view, d.view.TextSnapshot(), d.view.Revision()
	plugins, root, path, language, id := a.plugins, p.root, d.path, d.languageID, documentPublicID(d)
	provided := state.provided && text.Len() <= pluginservice.DocumentSnapshotMaxBytes
	prefs := a.editorPreferences
	var grammar *syntax.Syntax
	if builtinBracketMatchingServes(d) {
		grammar = d.grammar
	}
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		var rainbow []editorview.RainbowColor
		var matches []bracketMatch
		if grammar != nil {
			var rainbowErr error
			rainbow, matches, rainbowErr = resolveBuiltinRainbow(ctx, text, grammar, prefs.RainbowBrackets, prefs.RainbowVariables)
			if rainbowErr != nil && !errors.Is(ctx.Err(), context.Canceled) {
				a.backgroundFailedIn(ctx, "editor_rainbow_colors", rainbowErr)
			}
			if provided && ctx.Err() == nil {
				// The local bracket index can be applied while a plugin computes its colors.
				a.post(func(a *App) { a.finishBracketMatches(p, d, state, generation, view, revision, matches) })
			}
		}
		var spans []editorview.ColorDecoration
		var err error
		if provided && ctx.Err() == nil {
			decorations, providerErr := plugins.PluginColorDecorations(ctx, root, path, language, id, revision)
			err = providerErr
			spans = make([]editorview.ColorDecoration, 0, len(decorations))
			for _, decoration := range decorations {
				spans = append(spans, editorview.ColorDecoration{
					StartLine: decoration.Range.Start.Line, StartCharacter: decoration.Range.Start.Character,
					EndLine: decoration.Range.End.Line, EndCharacter: decoration.Range.End.Character,
					SourceID: decoration.SourceID, Light: decoration.Light, Dark: decoration.Dark,
				})
			}
		}
		if errors.Is(ctx.Err(), context.Canceled) {
			// log-exempt: 用户取消：新的编辑、设置或提供者变化、关闭文档会结束过期请求。
			return nil
		}
		prepared := editorview.PrepareColorDecorations(text, spans).WithRainbowColors(
			rainbow, prefs.RainbowBracketLightColors, prefs.RainbowBracketDarkColors,
		)
		return func(a *App) {
			if !provided {
				a.finishBracketMatches(p, d, state, generation, view, revision, matches)
			}
			a.finishColorDecorations(p, d, state, generation, view, revision, prepared, err)
		}
	})
}

func builtinBracketMatchingServes(d *document) bool {
	return !d.virtual && d.grammar != nil &&
		d.view.TextSnapshot().Len() <= syntax.RainbowBracketMaxBytes
}

// resolveBuiltinRainbow takes both sets of candidates from one grammar scan. Core assigns
// matching offsets and nesting depths to brackets, and a stable color selector to each variable
// spelling. Caret matching always needs brackets, regardless of the requested foreground colors.
func resolveBuiltinRainbow(ctx context.Context, text rope.Rope, grammar *syntax.Syntax, colorBrackets, colorVariables bool) ([]editorview.RainbowColor, []bracketMatch, error) {
	bracketTokens, variableTokens := syntax.RainbowCandidates(ctx, text, grammar, true, colorVariables)
	if len(bracketTokens) == 0 && len(variableTokens) == 0 {
		return nil, nil, nil
	}
	client := core.NewClient()
	var colors []editorview.RainbowColor
	var matches []bracketMatch
	if colorBrackets {
		colors = make([]editorview.RainbowColor, 0, len(bracketTokens)+len(variableTokens))
	} else if len(variableTokens) != 0 {
		colors = make([]editorview.RainbowColor, 0, len(variableTokens))
	}
	var bracketErr, variableErr error
	if len(bracketTokens) != 0 {
		brackets := make([]core.EditorRainbowBracket, len(bracketTokens))
		for i, token := range bracketTokens {
			brackets[i] = core.EditorRainbowBracket(token)
		}
		var result []core.EditorRainbowColor
		result, bracketErr = client.ResolveEditorRainbowBrackets(ctx, brackets)
		for _, bracket := range result {
			if colorBrackets {
				colors = append(colors, editorview.RainbowColor{Start: bracket.Offset, End: bracket.Offset + 1, Color: bracket.Depth})
			}
			if bracket.MatchOffset != nil {
				matches = append(matches, bracketMatch{offset: bracket.Offset, mate: *bracket.MatchOffset})
			}
		}
	}
	if len(variableTokens) != 0 {
		variables := make([]core.EditorRainbowVariable, len(variableTokens))
		for i, token := range variableTokens {
			variables[i] = core.EditorRainbowVariable(token)
		}
		var result []core.EditorRainbowVariableColor
		result, variableErr = client.ResolveEditorRainbowVariables(ctx, variables)
		for _, variable := range result {
			colors = append(colors, editorview.RainbowColor(variable))
		}
	}
	if colorBrackets && len(bracketTokens) != 0 && len(variableTokens) != 0 {
		slices.SortFunc(colors, func(left, right editorview.RainbowColor) int {
			return cmp.Compare(left.Start, right.Start)
		})
	}
	return colors, matches, errors.Join(bracketErr, variableErr)
}

func (a *App) finishBracketMatches(p *project, d *document, state *documentColorDecorations, generation uint64, view *editorview.View, revision int, matches []bracketMatch) {
	if !a.currentColorDecorationsRequest(p, d, state, generation, view) || view.Revision() != revision {
		return
	}
	state.bracketMatches, state.bracketView, state.bracketRevision = matches, view, revision
	a.syncBracketHighlights(d)
}

// syncBracketHighlights projects the current caret onto the already prepared bracket index.
// Each delimiter occupies one ASCII byte, so the caret can be on either edge of its glyph.
func (a *App) syncBracketHighlights(d *document) {
	if d == nil || d.view == nil {
		return
	}
	view := d.view
	state := a.editor.colorDecorations.docs[d.id]
	if state != nil && state.bracketView == view && state.bracketRevision == view.Revision() && len(state.bracketMatches) != 0 {
		start, end := view.Selection()
		if start == end && !view.IsComposing() {
			matches := state.bracketMatches
			at, found := slices.BinarySearchFunc(matches, uint32(start), func(match bracketMatch, offset uint32) int {
				return cmp.Compare(match.offset, offset)
			})
			if !found && at > 0 && int(matches[at-1].offset)+1 == start {
				at, found = at-1, true
			}
			if found {
				offset, mate := int(matches[at].offset), int(matches[at].mate)
				view.SetBracketHighlights(min(offset, mate), max(offset, mate))
				return
			}
		}
	}
	view.SetBracketHighlights(-1, -1)
}

func (a *App) refreshBuiltinRainbowColors() {
	if p := a.project; p != nil {
		for _, d := range p.docs.list {
			if d.view == nil {
				continue
			}
			d.view.ClearColorDecorations()
			a.scheduleColorDecorations(p, d, 0)
		}
	}
}

// finishColorDecorations applies an answer when it is still the document's latest request and
// the text is still the one it was computed for.
func (a *App) finishColorDecorations(p *project, d *document, state *documentColorDecorations, generation uint64, view *editorview.View, revision int, prepared editorview.PreparedColorDecorations, err error) {
	if !a.currentColorDecorationsRequest(p, d, state, generation, view) {
		return
	}
	state.cancel = nil
	if view.Revision() != revision {
		return
	}
	if err != nil {
		a.backgroundFailed("plugin_color_decorations", err)
	}
	view.SetPreparedColorDecorations(prepared)
}

func (a *App) currentColorDecorationsRequest(p *project, d *document, state *documentColorDecorations, generation uint64, view *editorview.View) bool {
	return a.project == p && p.docs.find(d.id) == d && view == d.view &&
		a.editor.colorDecorations.docs[d.id] == state && state.generation == generation
}

// colorProvidersChanged looks up the providers of every open document again and asks for their
// colors, after a color provider registered or withdrew.
func (a *App) colorProvidersChanged(p *project) {
	for _, d := range p.docs.list {
		if state := a.editor.colorDecorations.docs[d.id]; state != nil {
			state.known = false
		}
		a.scheduleColorDecorations(p, d, 0)
	}
}

// dropColorDecorations revokes the document's requests before clearing its colors, so a late
// result can never resurrect ranges from an ended document or provider registration.
func (a *App) dropColorDecorations(d *document) {
	if d == nil {
		return
	}
	if state := a.editor.colorDecorations.docs[d.id]; state != nil {
		state.revoke()
		delete(a.editor.colorDecorations.docs, d.id)
	}
	if d.view != nil {
		d.view.ClearColorDecorations()
		d.view.SetBracketHighlights(-1, -1)
	}
}
