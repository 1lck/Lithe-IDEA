package workbench

import (
	"context"
	"errors"
	"regexp"

	"github.com/1lck/Lithe-IDEA/desktop/internal/ai"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/ui"
)

// This file is the editor's AI inline edit (matrix id ai-inline-edit): the user selects code,
// asks for a change, reviews a diff and accepts or rejects it. The ai package sends the
// request with Core; this file keeps the dialog's state and applies an accepted edit as one
// undoable step. Nothing is applied before the user accepts, and nothing is applied if the file
// changed in the meantime.

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
	// source is the configuration the edit is sent with: codex or claude. Empty follows the
	// AI settings, as the commit message generation does (inlineEditSources).
	source string
	// currentLine says the edit covers the caret's line because nothing was selected.
	currentLine bool
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
	if !a.aiKernelReady() || a.inline.open {
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
	currentLine := start == end
	text, rope := view.Text()
	if currentLine {
		// Without a selection the edit covers the caret's line, as the Windows client does.
		line, _ := view.Caret()
		start = rope.LineStart(line)
		end = start
		for end < len(text) && text[end] != '\n' {
			end++
		}
	}
	if start == end {
		a.notify(t.NoSelection)
		return
	}
	if view.ReadOnly() {
		a.notify(t.ReadOnly)
		return
	}
	a.performed("ai.inlineEdit.open", surfaceShortcut)
	s := &a.inline
	*s = inlineEditState{open: true, doc: doc, start: start, end: end, selected: string(text[start:end]), revision: view.Revision(), currentLine: currentLine}
}

// runInlineEdit sends the request. The answer replaces any earlier result.
func (a *App) runInlineEdit(p *project) {
	s := &a.inline
	kernel := a.aiKernel
	if kernel == nil || s.running || s.doc == nil {
		return
	}
	text, _ := s.doc.view.Text()
	before, after := ai.InlineContext(text, s.start, s.end)
	edit := ai.InlineEdit{
		BeforeSelection: before, SelectedText: s.selected, AfterSelection: after,
		Instruction: s.instruction.Text(), FilePath: s.doc.path, LanguageID: s.doc.languageID,
	}
	ctx, cancel := context.WithCancel(p.ctx)
	s.running, s.cancel, s.failure, s.hasResult = true, cancel, "", false
	sources := a.inlineEditSources()
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		edited, err := ai.EditInline(ctx, kernel, edit, sources)
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

// inlineEditSources is the provider order of one edit: the picker's choice when there is one,
// otherwise the same order the commit message generation uses.
func (a *App) inlineEditSources() []string {
	if source := a.inline.source; source != "" {
		return []string{source}
	}
	return a.aiGenerationSources()
}

// inlineEditFailure is the notice for a failed request: a stable code or a status, never a
// response body or the request.
func (a *App) inlineEditFailure(err error) string {
	t, c := a.text.AI.InlineEdit, a.text.AI.Commit
	var status *ai.HTTPError
	switch {
	case errors.Is(err, ai.ErrNoProvider):
		return c.NoProvider
	case errors.Is(err, ai.ErrResponseTooLarge):
		return t.Failed(c.ResponseTooLarge)
	case errors.Is(err, ai.ErrTimeout):
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
		a.notifyError(t.Stale)
		a.closeInlineEdit()
		return
	}
	a.performed("ai.inlineEdit.accept", surfaceButton)
	if err := view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: s.start, End: s.end}, Text: s.result}}); err != nil {
		a.notifyError(t.Failed(err.Error()))
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
