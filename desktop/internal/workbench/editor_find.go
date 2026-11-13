package workbench

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

type editorFindKey struct {
	query                             string
	version                           int
	matchCase, word, regex, selection bool
}

// editorFind holds only one document's bar and the result for an exact text revision.
// Matching and replacement planning belong to Core; text preparation runs on a worker.
type editorFind struct {
	open, replace, focus, pending     bool
	query, replacement                ui.Field
	matchCase, word, regex, selection bool
	scope                             *core.EditorByteRange
	key                               editorFindKey
	computed                          bool
	matches                           []core.EditorByteRange
	current                           int
	truncated                         bool
	failure                           string
	generation                        uint64
	cancel                            context.CancelFunc
	timer                             *time.Timer
	// A negative debounce lets tests drive completion without elapsed-time synchronization.
	debounce time.Duration
}

type editorFindKernel interface {
	FindEditorText(context.Context, []byte, core.EditorFindRequest) (core.EditorFindResult, error)
}

func (a *App) openEditorFind(replace bool) {
	p := a.project
	if p == nil {
		return
	}
	d := p.selectedDocument(p.docs.group)
	if d == nil || d.view.IsComposing() {
		return
	}
	f := &d.find
	if !f.open {
		start, end := d.view.Selection()
		if end > start {
			f.scope = &core.EditorByteRange{Start: start, End: end}
			if end-start <= 4096 {
				f.query.SetText(d.view.SelectedText())
			}
		}
	}
	f.open, f.replace, f.focus = true, replace, true
	f.computed = false
	a.performed("editor.find.open", surfaceShortcut)
	a.invalidator.Invalidate()
}

func (a *App) closeEditorFind(d *document) {
	f := &d.find
	f.generation++
	if f.cancel != nil {
		f.cancel()
		f.cancel = nil
	}
	if f.timer != nil {
		f.timer.Stop()
		f.timer = nil
	}
	f.open, f.pending, f.computed = false, false, false
	f.matches = nil
	d.view.ClearSearchMatches()
	a.focusDocument(d.id)
}

func (a *App) refreshEditorFind(p *project, d *document) {
	f := &d.find
	key := editorFindKey{f.query.Text(), d.view.Revision(), f.matchCase, f.word, f.regex, f.selection}
	if f.computed && key == f.key {
		return
	}
	f.key, f.computed = key, true
	f.generation++
	if f.cancel != nil {
		f.cancel()
		f.cancel = nil
	}
	if f.timer != nil {
		f.timer.Stop()
		f.timer = nil
	}
	f.matches = nil
	d.view.ClearSearchMatches()
	if key.query == "" {
		f.pending, f.failure = false, ""
		return
	}
	f.pending = true
	gen := f.generation
	start := func() { a.runEditorFind(p, d, nil, nil) }
	if f.debounce < 0 {
		start()
		return
	}
	delay := f.debounce
	if delay == 0 {
		delay = 80 * time.Millisecond
	}
	f.timer = time.AfterFunc(delay, func() {
		a.post(func(a *App) {
			if a.project == p && p.docs.find(d.id) == d && f.open && f.generation == gen {
				f.timer = nil
				start()
			}
		})
	})
}

// runEditorFind snapshots the native rope in O(1). No source flattening, matching,
// replacement expansion or whole-document layout happens on the window thread.
func (a *App) runEditorFind(p *project, d *document, replacement *string, replaceStart *int) {
	kernel, ok := a.kernel.(editorFindKernel)
	if !ok {
		return
	}
	f := &d.find
	if f.cancel != nil {
		f.cancel()
	}
	ctx, cancel := context.WithTimeout(p.ctx, kernelCallTimeout)
	f.cancel = cancel
	f.generation++
	gen := f.generation
	f.pending = true
	before := d.view.TextSnapshot()
	baseline := d.view.SavedSnapshot()
	_, caret := d.view.SelectionOffsets()
	input := core.EditorFindRequest{Query: f.query.Text(), CaseSensitive: f.matchCase, WholeWord: f.word, Regex: f.regex, Caret: caret, Replacement: replacement, ReplaceStart: replaceStart}
	if f.selection {
		input.Range = f.scope
	}
	a.background(p, kernelCallTimeout, func(context.Context) func(*App) {
		defer cancel()
		result, err := kernel.FindEditorText(ctx, before.Bytes(), input)
		var prepared editorview.PreparedEdit
		if err == nil && replacement != nil && len(result.Edits) > 0 {
			edits := make([]editorview.TextEdit, len(result.Edits))
			for i, e := range result.Edits {
				edits[i] = editorview.TextEdit{Range: editorview.Range{Start: e.Start, End: e.End}, Text: e.Text}
			}
			prepared, err = editorview.PrepareEdits(before, baseline, edits)
		}
		return func(a *App) { a.applyEditorFind(p, d, before, gen, replacement != nil, result, prepared, err) }
	})
}

func (a *App) applyEditorFind(p *project, d *document, before rope.Rope, gen uint64, replacing bool, result core.EditorFindResult, prepared editorview.PreparedEdit, err error) {
	f := &d.find
	if a.project != p || p.docs.find(d.id) != d || !f.open || f.generation != gen {
		return
	}
	f.pending = false
	if !d.view.TextSnapshot().Same(before) {
		f.computed = false
		if replacing {
			a.notifyInfo(i18n.Shared(a.language(), "desktop.editorFind.stale"))
		}
		return
	}
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		} // log-exempt: 用户取消：关闭或更新查询取消旧匹配。
		code := "failed"
		var failure *core.Error
		if errors.As(err, &failure) {
			code = failure.Details
		}
		if code != f.failure {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_find", err))
		}
		f.failure = code
		return
	}
	f.failure = ""
	if replacing {
		if len(result.Edits) > 0 {
			if !d.view.ApplyPreparedEdit(prepared) {
				f.computed = false
				a.notifyInfo(i18n.Shared(a.language(), "desktop.editorFind.stale"))
				return
			}
		}
		if result.Range != nil {
			f.scope = result.Range
		}
		f.computed = false
		a.notifyInfo(i18n.SharedFormat(a.language(), "desktop.editorFind.replaced", map[string]string{"count": strconv.Itoa(len(result.Edits))}))
		return
	}
	f.matches, f.truncated = result.Matches, result.Truncated
	f.current = 0
	if result.Selected != nil {
		f.current = *result.Selected
	}
	ranges := make([]editorview.Range, len(result.Matches))
	for i, r := range result.Matches {
		ranges[i] = editorview.Range{Start: r.Start, End: r.End}
	}
	d.view.SetSearchMatches(ranges)
	a.stepEditorFind(d, 0)
}

func (a *App) stepEditorFind(d *document, by int) {
	f := &d.find
	if len(f.matches) == 0 || f.pending {
		return
	}
	f.current = (f.current + by + len(f.matches)) % len(f.matches)
	match := f.matches[f.current]
	d.view.SetSelection(match.Start, match.End)
}

func editorFindFailure(language i18n.Language, failure string) string {
	switch failure {
	case "invalid_pattern":
		return i18n.Shared(language, "desktop.editorFind.invalidPattern")
	case "source_too_large", "source_too_large_or_invalid":
		return i18n.Shared(language, "desktop.editorFind.tooLarge")
	case "too_many_matches":
		return i18n.Shared(language, "desktop.editorFind.tooMany")
	case "replacement_too_large":
		return i18n.Shared(language, "desktop.editorFind.replacementTooLarge")
	default:
		return i18n.Shared(language, "desktop.editorFind.failed")
	}
}

func (a *App) editorFindBar(c ui.C, p *project, d *document) {
	f := &d.find
	if !f.open {
		return
	}
	a.refreshEditorFind(p, d)

	ui.Column(c.KeyInt(d.id).Part("find")).FillWidth().Shrink(0).PadX(8).PadY(5).Gap(4).Background(a.colors.Panel).Children(func() {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(5).Children(func() {
			queryID := ui.ID(c.KeyInt(d.id).Part("find-query"))
			if f.focus {
				c.Canvas().RequestFocus(queryID)
				f.focus = false
			}
			ui.TextFieldID(c, queryID, &f.query, i18n.Shared(a.language(), "desktop.editorFind.find"), i18n.Shared(a.language(), "desktop.editorFind.find")).Icon(icons.Search).Grow(1).MinWidth(70).OnKey(func(event gfx.KeyEvent) gfx.EventResult {
				if event.Release {
					return gfx.EventResult{}
				}
				if event.Key == gfx.KeyEscape {
					a.closeEditorFind(d)
					return gfx.EventResult{Handled: true, Repaint: true}
				}
				if event.Key == gfx.KeyEnter {
					by := 1
					if event.Modifiers&gfx.ModifierShift != 0 {
						by = -1
					}
					a.stepEditorFind(d, by)
					return gfx.EventResult{Handled: true, Repaint: true}
				}
				return gfx.EventResult{}
			})
			current := 0
			if len(f.matches) > 0 {
				current = f.current + 1
			}
			ui.Text(c, i18n.SharedFormat(a.language(), "desktop.editorFind.count", map[string]string{"current": strconv.Itoa(current), "total": strconv.Itoa(len(f.matches))})).FontSize(12).Color(a.colors.Subtle)
			if a.gitIconButton(c, i18n.Shared(a.language(), "desktop.editorFind.previous"), icons.ArrowUp, false, f.pending || len(f.matches) == 0) {
				c.After(func() { a.stepEditorFind(d, -1) })
			}
			if a.gitIconButton(c, i18n.Shared(a.language(), "desktop.editorFind.next"), icons.ArrowDown, false, f.pending || len(f.matches) == 0) {
				c.After(func() { a.stepEditorFind(d, 1) })
			}
			if a.gitIconButton(c, i18n.Shared(a.language(), "desktop.editorFind.close"), icons.X, false, false) {
				c.After(func() { a.closeEditorFind(d) })
			}
		})
		ui.Row(c.Part("find-options")).FillWidth().Items(ui.Center).Gap(18).Children(func() {
			for _, option := range []struct {
				key      string
				label    string
				value    *bool
				disabled bool
			}{{"case", i18n.Shared(a.language(), "desktop.editorFind.case"), &f.matchCase, false}, {"word", i18n.Shared(a.language(), "desktop.editorFind.word"), &f.word, false}, {"regex", i18n.Shared(a.language(), "desktop.editorFind.regex"), &f.regex, false}, {"selection", i18n.Shared(a.language(), "desktop.editorFind.selection"), &f.selection, f.scope == nil}} {
				ui.Checkbox(c.Part(option.key), option.value, option.label).Disabled(option.disabled)
			}
		})
		if f.replace {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
				ui.TextField(c.Part("replacement"), &f.replacement, i18n.Shared(a.language(), "desktop.editorFind.replace"), i18n.Shared(a.language(), "desktop.editorFind.replace")).Grow(1).MinWidth(70)
				disabled := d.view.ReadOnly() || d.view.IsComposing() || f.pending || len(f.matches) == 0 || f.failure != ""
				if ui.Button(c, i18n.Shared(a.language(), "desktop.editorFind.replaceOne")).Outline().Small().Disabled(disabled).Clicked() {
					c.After(func() {
						r := f.replacement.Text()
						at := f.matches[f.current].Start
						a.performed("editor.find.replace", surfaceButton)
						a.runEditorFind(p, d, &r, &at)
					})
				}
				if ui.Button(c, i18n.Shared(a.language(), "desktop.editorFind.replaceAll")).Outline().Small().Disabled(disabled || f.truncated).Clicked() {
					c.After(func() {
						r := f.replacement.Text()
						a.performed("editor.find.replaceAll", surfaceButton)
						a.runEditorFind(p, d, &r, nil)
					})
				}
			})
		}
		if f.failure != "" {
			ui.Wrap(c, editorFindFailure(a.language(), f.failure)).FontSize(12).Color(a.colors.Deleted)
		} else if f.pending {
			ui.Text(c, i18n.Shared(a.language(), "desktop.editorFind.loading")).FontSize(12).Color(a.colors.Subtle)
		} else if f.truncated {
			ui.Wrap(c, i18n.Shared(a.language(), "desktop.editorFind.tooMany")).FontSize(12).Color(a.colors.Subtle)
		}
	})
	ui.Divider(c)
}

func (f *editorFind) dispose() {
	f.generation++
	if f.cancel != nil {
		f.cancel()
		f.cancel = nil
	}
	if f.timer != nil {
		f.timer.Stop()
		f.timer = nil
	}
	f.open = false
	f.matches = nil
}
