package workbench

import (
	"context"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// colorDecorationsState owns one cancellable request per open document. These colors are
// independent of the language server's semantic tokens, which keep their normal lifecycle.
type colorDecorationsState struct {
	docs map[int]*documentColorDecorations
}

type documentColorDecorations struct {
	cancel context.CancelFunc
}

const (
	colorDecorationsDelay   = 250 * time.Millisecond
	colorDecorationsTimeout = 20 * time.Second
)

// scheduleColorDecorations replaces both the debounce and the in-flight request. Preparation
// reads an immutable text snapshot on the worker; the window applies only its current answer.
func (a *App) scheduleColorDecorations(p *project, d *document, delay time.Duration) {
	if p == nil || d == nil || d.view == nil || a.project != p {
		return
	}
	a.dropColorDecorations(d)
	if a.plugins == nil || d.virtual || d.view.TextSnapshot().Len() > pluginservice.DocumentSnapshotMaxBytes ||
		!a.plugins.HasColorDecorationsProvider(p.root, d.path, d.languageID) {
		return
	}
	if a.editor.colorDecorations.docs == nil {
		a.editor.colorDecorations.docs = make(map[int]*documentColorDecorations)
	}
	ctx, cancel := context.WithTimeout(a.operationContext(p.ctx), colorDecorationsTimeout)
	request := &documentColorDecorations{cancel: cancel}
	a.editor.colorDecorations.docs[d.id] = request
	view, text, revision := d.view, d.view.TextSnapshot(), d.view.Revision()
	plugins, root, path, language, id := a.plugins, p.root, d.path, d.languageID, documentPublicID(d)
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		if delay > 0 {
			timer := time.NewTimer(delay)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-ctx.Done():
				// log-exempt: 用户取消：新的编辑、提供者撤回或关闭文档会结束请求。
				return nil
			}
		}
		decorations, err := plugins.PluginColorDecorations(ctx, root, path, language, id, revision)
		if errors.Is(ctx.Err(), context.Canceled) {
			// log-exempt: 用户取消：过期请求不改变当前文档，也不是失败。
			return nil
		}
		spans := make([]editorview.ColorDecoration, 0, len(decorations))
		for _, decoration := range decorations {
			spans = append(spans, editorview.ColorDecoration{
				StartLine: decoration.Range.Start.Line, StartCharacter: decoration.Range.Start.Character,
				EndLine: decoration.Range.End.Line, EndCharacter: decoration.Range.End.Character,
				SourceID: decoration.SourceID, Light: decoration.Light, Dark: decoration.Dark,
			})
		}
		prepared := editorview.PrepareColorDecorations(text, spans)
		return func(a *App) {
			a.finishColorDecorations(p, d, request, view, revision, prepared, err)
		}
	})
}

func (a *App) finishColorDecorations(p *project, d *document, request *documentColorDecorations, view *editorview.View, revision int, prepared editorview.PreparedColorDecorations, err error) {
	if a.project != p || p.docs.find(d.id) != d || view != d.view || view.Revision() != revision || a.editor.colorDecorations.docs[d.id] != request {
		return
	}
	delete(a.editor.colorDecorations.docs, d.id)
	if err != nil {
		a.backgroundFailed("plugin_color_decorations", err)
	}
	view.SetPreparedColorDecorations(prepared)
}

// dropColorDecorations revokes the old request before clearing colors, so a late result can
// never resurrect ranges from an ended document or provider registration.
func (a *App) dropColorDecorations(d *document) {
	if d == nil {
		return
	}
	if state := a.editor.colorDecorations.docs[d.id]; state != nil {
		state.cancel()
		delete(a.editor.colorDecorations.docs, d.id)
	}
	if d.view != nil {
		d.view.ClearColorDecorations()
	}
}
