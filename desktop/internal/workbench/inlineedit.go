package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/ui"
)

// This file is the editor's AI inline edit (matrix id ai-inline-edit): the user selects code,
// asks for a change, reviews a diff and accepts or rejects it. Core plans the request
// (ai.inlineEdit.plan) and decodes the answer (ai.inlineEdit.decode); this file picks the
// provider and credential from the Codex or Claude configuration, makes the HTTP call and
// applies an accepted edit as one undoable step. Nothing is applied before the user accepts,
// and nothing is applied if the file changed in the meantime.

// inlineEditWindow is how many bytes of context are read on each side of the selection. Core
// keeps 12,000 Unicode scalars of them; a scalar is at most 4 bytes.
const inlineEditWindow = 48_000

// aiInlineKernel is the part of the kernel an inline edit uses.
type aiInlineKernel interface {
	AIInlineEditPlan(ctx context.Context, provider core.AIInlineEditProvider, model core.AIInlineEditModel, edit core.AIInlineEdit) (core.AIInlineEditPlan, error)
	AIInlineEditDecode(ctx context.Context, wireProtocol string, response json.RawMessage) (string, error)
}

// inlineEditState is the open inline edit, if any.
type inlineEditState struct {
	open bool
	doc  *document
	// start and end are the selection's byte range when the edit was requested, selected its
	// text, and revision the document's revision then. Accepting is refused when the text
	// there changed.
	start, end int
	selected   string
	revision   int

	instruction ui.Field
	running     bool
	cancel      context.CancelFunc
	// result is the model's replacement once there is one; diff compares it with the selection.
	hasResult bool
	result    string
	diff      []diffLine
	// failure is the words of the last failure, empty when there is none.
	failure string
}

var inlineEditCode = regexp.MustCompile(`AI_INLINE_EDIT_[A-Z_]+`)

// requestInlineEdit opens the inline edit on the selection of the document that has the
// keyboard. A missing selection or a read-only file is reported and nothing opens.
func (a *App) requestInlineEdit(p *project, view *editorview.View) {
	if _, ok := a.kernel.(aiInlineKernel); !ok || !a.agentKernelReady() || a.inline.open {
		return
	}
	var doc *document
	for _, d := range p.docs.list {
		if d.view == view {
			doc = d
		}
	}
	if doc == nil || doc.virtual {
		return
	}
	t := a.text.AI.InlineEdit
	start, end := view.Selection()
	if start == end {
		a.notify(t.NoSelection)
		return
	}
	if view.ReadOnly() {
		a.notify(t.ReadOnly)
		return
	}
	a.performed("ai.inlineEdit.open", surfaceShortcut)
	text, _ := view.Text()
	s := &a.inline
	*s = inlineEditState{open: true, doc: doc, start: start, end: end, selected: string(text[start:end]), revision: view.Revision()}
}

// inlineContext is the text around the selection, cut at character boundaries.
func inlineContext(text []byte, start, end int) (before, after string) {
	from := max(0, start-inlineEditWindow)
	for from < start && !utf8.RuneStart(text[from]) {
		from++
	}
	to := min(len(text), end+inlineEditWindow)
	for to > end && to < len(text) && !utf8.RuneStart(text[to]) {
		to--
	}
	return string(text[from:start]), string(text[end:to])
}

// runInlineEdit sends the request. The answer replaces any earlier result.
func (a *App) runInlineEdit(p *project) {
	s := &a.inline
	kernel, ok := a.kernel.(aiInlineKernel)
	if !ok || s.running || s.doc == nil {
		return
	}
	text, _ := s.doc.view.Text()
	before, after := inlineContext(text, s.start, s.end)
	edit := core.AIInlineEdit{
		BeforeSelection: before, SelectedText: s.selected, AfterSelection: after,
		Instruction: s.instruction.Text(), FilePath: s.doc.path, LanguageID: s.doc.languageID,
	}
	ctx, cancel := context.WithCancel(p.ctx)
	s.running, s.cancel, s.failure, s.hasResult = true, cancel, "", false
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		edited, err := a.fetchInlineEdit(ctx, kernel, edit)
		return func(a *App) {
			s := &a.inline
			s.running, s.cancel = false, nil
			switch {
			case errors.Is(err, context.Canceled):
			case err != nil:
				s.failure = a.inlineEditFailure(err)
				a.gitOperationFailed("ai_inline_edit", err)
			default:
				s.hasResult, s.result = true, edited
				s.diff = lineDiff(s.selected, edited)
			}
		}
	})
}

// fetchInlineEdit plans, sends and decodes one request off the window thread.
func (a *App) fetchInlineEdit(ctx context.Context, kernel aiInlineKernel, edit core.AIInlineEdit) (string, error) {
	providers, _ := a.discoverAgentProviders(ctx)
	provider, ok := pickAIProvider(providers)
	if !ok {
		return "", errAINoProvider
	}
	model := core.AIInlineEditModel{ID: provider.Model, Listing: "unlisted"}
	plan, err := kernel.AIInlineEditPlan(ctx, core.AIInlineEditProvider{
		WireProtocol: provider.Protocol, Endpoint: provider.Endpoint, RequiresAPIKey: true,
		AcceptsUnlistedModels: true, ChatTokenLimitField: "max_completion_tokens",
	}, model, edit)
	if err != nil {
		return "", err
	}
	headers := map[string]string{"Content-Type": "application/json"}
	for name, value := range plan.Headers {
		headers[name] = value
	}
	if plan.Credential.Required {
		value := provider.APIKey
		if plan.Credential.Scheme == "bearer" {
			value = "Bearer " + value
		}
		headers[plan.Credential.Header] = value
	}
	answer, err := aiPost(ctx, plan.URL, headers, plan.Body)
	if err != nil {
		return "", err
	}
	if !json.Valid(answer) {
		return "", errors.New("AI_INLINE_EDIT_INVALID_RESPONSE")
	}
	return kernel.AIInlineEditDecode(ctx, provider.Protocol, answer)
}

// inlineEditFailure is the notice for a failed request: a stable code or a status, never a
// response body or the request.
func (a *App) inlineEditFailure(err error) string {
	t, c := a.text.AI.InlineEdit, a.text.AI.Commit
	var status *aiHTTPError
	switch {
	case errors.Is(err, errAINoProvider):
		return c.NoProvider
	case errors.Is(err, errAIResponseTooLarge):
		return t.Failed(c.ResponseTooLarge)
	case errors.Is(err, errAITimeout):
		return t.Failed(c.Timeout)
	case errors.As(err, &status):
		return t.Failed(c.HTTPStatus(status.Status))
	}
	if code := inlineEditCode.FindString(err.Error()); code != "" {
		return t.Failed(code)
	}
	return t.Failed("AI_INLINE_EDIT_FAILED")
}

// acceptInlineEdit applies the result when the selection is untouched: the file has the same
// revision, or at least the same text in the same range. It is one undoable edit.
func (a *App) acceptInlineEdit(p *project) {
	s := &a.inline
	t := a.text.AI.InlineEdit
	if !s.hasResult || s.doc == nil {
		return
	}
	view := s.doc.view
	text, _ := view.Text()
	if view.Revision() != s.revision && (s.end > len(text) || string(text[s.start:s.end]) != s.selected) || view.IsComposing() {
		a.notify(t.Stale)
		a.closeInlineEdit()
		return
	}
	a.performed("ai.inlineEdit.accept", surfaceButton)
	if err := view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: s.start, End: s.end}, Text: s.result}}); err != nil {
		a.notify(t.Failed(err.Error()))
		a.gitOperationFailed("ai_inline_edit", err)
	}
	a.closeInlineEdit()
}

// closeInlineEdit stops a running request and closes the dialog without applying anything.
func (a *App) closeInlineEdit() {
	if cancel := a.inline.cancel; cancel != nil {
		cancel()
	}
	a.inline = inlineEditState{}
}
