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
	bracketView     *editorview.View
	bracketRevision int
	resolved        *resolvedRainbow
	rainbowView     *editorview.View
	rainbowReasons  []string
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
	if state.rainbowView != d.view || state.path != d.path || state.language != d.languageID {
		state.rainbowView = d.view
		state.resolved = nil
		state.rainbowReasons = nil
	}
	if !builtinBracketMatchingServes(d) || state.path != d.path || state.language != d.languageID ||
		state.bracketView != d.view || state.bracketRevision != d.view.Revision() {
		state.bracketView = nil
		d.view.SetBracketMatches(nil)
		d.view.SetIndentGuideScopes(editorview.PreparedIndentGuideScopes{})
		a.clearSourcePreviewScopes(d)
	}
	providerServes := a.colorDecorationsServed(p, d, state)
	if !providerServes && !builtinBracketMatchingServes(d) {
		d.view.ClearColorDecorations()
		a.clearSourcePreviewDecorations(d)
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
		a.clearSourcePreviewColors(d)
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
	preview := a.colorDecorationsPreview(d)
	plugins, root, path, language, id := a.plugins, p.root, d.path, d.languageID, documentPublicID(d)
	provided := state.provided && text.Len() <= pluginservice.DocumentSnapshotMaxBytes
	prefs := a.editorPreferences
	previousRainbow := state.resolved
	var grammar *syntax.Syntax
	if builtinBracketMatchingServes(d) {
		grammar = d.grammar
	}
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		var rainbow builtinRainbow
		var resolved *resolvedRainbow
		var indentScopes editorview.PreparedIndentGuideScopes
		var previewScopes editorview.PreparedIndentGuideScopes
		var candidates syntax.CandidateSnapshot
		candidatesReady := false
		pairedPreview := preview.view != nil && !preview.text.Same(text) && preview.text.Equal(text)
		if grammar != nil {
			var rainbowErr error
			candidates, rainbowErr = view.RainbowCandidates(ctx, text)
			if rainbowErr == nil {
				candidatesReady = true
				resolved, rainbowErr = resolveRainbowCandidates(ctx, candidates, prefs.RainbowBrackets, prefs.RainbowVariables, previousRainbow)
				if resolved != nil {
					rainbow = resolved.result
				}
				if rainbowErr != nil {
					resolved = nil
				}
			}
			if rainbowErr != nil && !errors.Is(ctx.Err(), context.Canceled) {
				a.backgroundFailedIn(ctx, "editor_rainbow_colors", rainbowErr)
			}
			indentScopes = editorview.PrepareIndentGuideScopes(text, rainbow.indentScopes)
		}
		if pairedPreview {
			previewScopes = indentScopes.ForSnapshot(preview.text)
		}
		matches := rainbow.matches
		if provided && grammar != nil && ctx.Err() == nil {
			// The local bracket index can be applied while a plugin computes its colors.
			a.post(func(a *App) {
				a.finishBracketMatches(p, d, state, generation, view, revision, matches, indentScopes)
				if pairedPreview && a.currentColorDecorationsPreview(p, d, state, generation, view, revision, preview) {
					preview.view.SetBracketMatches(matches)
					preview.view.SetIndentGuideScopes(previewScopes)
				}
			})
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
			rainbow.colors, prefs.RainbowLightColors, prefs.RainbowDarkColors,
		)
		var previewColors editorview.PreparedColorDecorations
		if pairedPreview {
			previewColors = prepared.CloneFor(preview.text)
		}
		return func(a *App) {
			if a.currentColorDecorationsRequest(p, d, state, generation, view) && view.Revision() == revision {
				state.resolved = resolved
				if candidatesReady {
					a.reportRainbowDegradation(state, candidates.Reasons)
				}
			}
			if !provided {
				a.finishBracketMatches(p, d, state, generation, view, revision, matches, indentScopes)
			}
			a.finishColorDecorations(p, d, state, generation, view, revision, prepared, err)
			if pairedPreview && a.currentColorDecorationsPreview(p, d, state, generation, view, revision, preview) {
				preview.view.SetBracketMatches(matches)
				preview.view.SetIndentGuideScopes(previewScopes)
				preview.view.SetPreparedColorDecorations(previewColors)
			}
		}
	})
}

// Only the accepted snapshot advances this document's diagnostic state. A
// persistent limit is one degradation, even if typing repeatedly restarts work.
func (a *App) reportRainbowDegradation(state *documentColorDecorations, reasons []string) {
	for _, reason := range reasons {
		if !slices.Contains(state.rainbowReasons, reason) {
			a.backgroundFailed("editor_rainbow_"+reason, errors.New(reason))
		}
	}
	state.rainbowReasons = append(state.rainbowReasons[:0], reasons...)
}

func builtinBracketMatchingServes(d *document) bool {
	return !d.virtual && d.grammar != nil &&
		d.view.TextSnapshot().Len() <= syntax.RainbowBracketMaxBytes
}

type builtinRainbow struct {
	colors       []editorview.RainbowColor
	matches      []editorview.BracketMatch
	indentScopes []editorview.IndentGuideScope
}

// resolvedRainbow is an immutable result owned by the document's last completed worker.
// Unchanged candidates reuse the Core result even when unrelated text changes its revision.
type resolvedRainbow struct {
	brackets                      []syntax.Bracket
	variables                     []syntax.Variable
	colorBrackets, colorVariables bool
	result                        builtinRainbow
}

func resolveRainbowCandidates(ctx context.Context, candidates syntax.CandidateSnapshot, colorBrackets, colorVariables bool, previous *resolvedRainbow) (*resolvedRainbow, error) {
	bracketTokens, variableTokens := candidates.Brackets, candidates.Variables
	if !colorVariables {
		variableTokens = nil
	}
	if previous != nil && previous.colorBrackets == colorBrackets && previous.colorVariables == colorVariables &&
		slices.Equal(previous.brackets, bracketTokens) && slices.Equal(previous.variables, variableTokens) {
		return previous, nil
	}
	if previous != nil && previous.colorBrackets == colorBrackets && previous.colorVariables == colorVariables {
		if moved := previous.reproject(bracketTokens, variableTokens); moved != nil {
			return moved, nil
		}
	}
	client := core.NewClient()
	var rainbow builtinRainbow
	if colorBrackets {
		rainbow.colors = make([]editorview.RainbowColor, 0, len(bracketTokens)+len(variableTokens))
	} else if len(variableTokens) != 0 {
		rainbow.colors = make([]editorview.RainbowColor, 0, len(variableTokens))
	}
	var bracketErr, variableErr error
	if len(bracketTokens) != 0 {
		brackets := make([]core.EditorRainbowBracket, len(bracketTokens))
		for i, token := range bracketTokens {
			brackets[i] = core.EditorRainbowBracket(token)
		}
		var result []core.EditorRainbowColor
		result, bracketErr = client.ResolveEditorRainbowBrackets(ctx, brackets)
		if bracketErr == nil {
			rainbow.indentScopes = []editorview.IndentGuideScope{}
		}
		for _, bracket := range result {
			if colorBrackets {
				rainbow.colors = append(rainbow.colors, editorview.RainbowColor{Start: bracket.Offset, End: bracket.Offset + 1, Color: bracket.Depth})
			}
			if bracket.MatchOffset != nil {
				mate := *bracket.MatchOffset
				rainbow.matches = append(rainbow.matches, editorview.BracketMatch{Offset: bracket.Offset, Mate: mate})
				token, found := slices.BinarySearchFunc(bracketTokens, bracket.Offset, func(token syntax.Bracket, offset uint32) int { return cmp.Compare(token.Offset, offset) })
				if bracket.Offset < mate && found && bracketTokens[token].Bracket == "{" {
					rainbow.indentScopes = append(rainbow.indentScopes, editorview.IndentGuideScope{Open: int(bracket.Offset), Close: int(mate)})
				}
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
			rainbow.colors = append(rainbow.colors, editorview.RainbowColor(variable))
		}
	}
	if colorBrackets && len(bracketTokens) != 0 && len(variableTokens) != 0 {
		slices.SortFunc(rainbow.colors, func(left, right editorview.RainbowColor) int {
			return cmp.Compare(left.Start, right.Start)
		})
	}
	return &resolvedRainbow{brackets: bracketTokens, variables: variableTokens, colorBrackets: colorBrackets, colorVariables: colorVariables, result: rainbow}, errors.Join(bracketErr, variableErr)
}

// Pairing and colors belong to Core. When only UTF-8 positions move, project
// its existing answer onto the new candidates without changing that answer.
func (previous *resolvedRainbow) reproject(brackets []syntax.Bracket, variables []syntax.Variable) *resolvedRainbow {
	if len(previous.brackets) != len(brackets) || len(previous.variables) != len(variables) {
		return nil
	}
	for i, token := range brackets {
		if token.Bracket != previous.brackets[i].Bracket || i > 0 && token.Offset <= brackets[i-1].Offset {
			return nil
		}
	}
	for i, token := range variables {
		if token.Name != previous.variables[i].Name || token.End <= token.Start ||
			token.End-token.Start != uint32(len(token.Name)) || i > 0 && token.Start < variables[i-1].End {
			return nil
		}
	}
	moveBracket := func(offset uint32) (uint32, bool) {
		i, found := slices.BinarySearchFunc(previous.brackets, offset, func(token syntax.Bracket, offset uint32) int { return cmp.Compare(token.Offset, offset) })
		if !found {
			return 0, false
		}
		return brackets[i].Offset, true
	}
	result := builtinRainbow{
		colors: slices.Clone(previous.result.colors), matches: slices.Clone(previous.result.matches),
		indentScopes: slices.Clone(previous.result.indentScopes),
	}
	for i, color := range result.colors {
		if offset, found := moveBracket(color.Start); previous.colorBrackets && found && color.End == color.Start+1 {
			result.colors[i].Start, result.colors[i].End = offset, offset+1
			continue
		}
		j, found := slices.BinarySearchFunc(previous.variables, color.Start, func(token syntax.Variable, start uint32) int { return cmp.Compare(token.Start, start) })
		if !found || color.End != previous.variables[j].End {
			return nil
		}
		result.colors[i].Start, result.colors[i].End = variables[j].Start, variables[j].End
	}
	for i, match := range result.matches {
		offset, found := moveBracket(uint32(match.Offset))
		mate, paired := moveBracket(uint32(match.Mate))
		if !found || !paired {
			return nil
		}
		result.matches[i] = editorview.BracketMatch{Offset: offset, Mate: mate}
	}
	for i, scope := range result.indentScopes {
		open, found := moveBracket(uint32(scope.Open))
		close, paired := moveBracket(uint32(scope.Close))
		if !found || !paired {
			return nil
		}
		result.indentScopes[i] = editorview.IndentGuideScope{Open: int(open), Close: int(close)}
	}
	if previous.colorBrackets && previous.colorVariables {
		slices.SortFunc(result.colors, func(a, b editorview.RainbowColor) int { return cmp.Compare(a.Start, b.Start) })
	}
	return &resolvedRainbow{brackets: brackets, variables: variables, colorBrackets: previous.colorBrackets, colorVariables: previous.colorVariables, result: result}
}

func (a *App) finishBracketMatches(p *project, d *document, state *documentColorDecorations, generation uint64, view *editorview.View, revision int, matches []editorview.BracketMatch, indentScopes editorview.PreparedIndentGuideScopes) {
	if !a.currentColorDecorationsRequest(p, d, state, generation, view) || view.Revision() != revision {
		return
	}
	state.bracketView, state.bracketRevision = view, revision
	view.SetBracketMatches(matches)
	view.SetIndentGuideScopes(indentScopes)
	a.syncSourcePreviewDecorations(d)
}

// documentColorPreview captures the independently edited preview at request time. The worker
// reads only its immutable text; the window rejects an answer after the preview changes or moves.
type documentColorPreview struct {
	view     *editorview.View
	text     rope.Rope
	revision int
}

func (a *App) colorDecorationsPreview(d *document) documentColorPreview {
	if preview := a.documentPreviewView(d); preview != nil {
		return documentColorPreview{view: preview, text: preview.TextSnapshot(), revision: preview.Revision()}
	}
	return documentColorPreview{}
}

func (a *App) currentColorDecorationsPreview(p *project, d *document, state *documentColorDecorations, generation uint64, view *editorview.View, revision int, preview documentColorPreview) bool {
	return preview.view != nil && !preview.text.Same(view.TextSnapshot()) &&
		a.currentColorDecorationsRequest(p, d, state, generation, view) && view.Revision() == revision &&
		a.documentPreviewView(d) == preview.view && preview.view.Revision() == preview.revision
}

func (a *App) refreshBuiltinRainbowColors() {
	if p := a.project; p != nil {
		for _, d := range p.docs.list {
			if d.view == nil {
				continue
			}
			d.view.ClearColorDecorations()
			a.clearSourcePreviewColors(d)
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
	a.syncSourcePreviewDecorations(d)
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
		d.view.SetBracketMatches(nil)
		d.view.SetIndentGuideScopes(editorview.PreparedIndentGuideScopes{})
		a.clearSourcePreviewDecorations(d)
	}
}
