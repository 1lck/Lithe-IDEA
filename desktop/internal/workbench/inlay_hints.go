package workbench

import (
	"context"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	pluginSemanticInlayHints       semanticKind = "inlayHints"
	pluginSemanticResolveInlayHint semanticKind = "resolveInlayHint"

	pluginMethodInlayHints       = "textDocument/inlayHint"
	pluginMethodResolveInlayHint = "inlayHint/resolve"

	pluginInlayHintsRefresh = "inlayHintsRefresh"

	featureInlayHints       = "inlayHints"
	featureInlayHintResolve = "inlayHintResolve"

	inlayHintsPrefetchMargin = 40
	inlayHintsDelay          = 120 * time.Millisecond
)

type documentInlayHints struct {
	initialized   bool
	revision      int
	coveredStart  int
	coveredEnd    int
	reqStart      int
	reqEnd        int
	dirty         bool
	changedAt     time.Time
	seenRevision  int
	seenFirst     int
	seenLast      int
	pending       *semanticPending
	resolve       *semanticPending
	resolveIndex  int
	prepareCancel context.CancelFunc
	prepareGen    uint64
	hints         []core.PluginSemanticInlayHint
	resolved      map[int]bool
}

type inlayHintHoverState struct {
	open       bool
	documentID int
	revision   int
	hintIndex  int
	anchor     gfx.Rect
	rect       gfx.Rect
}

func (a *App) clearDocumentInlayHints(d *document) {
	if d == nil {
		return
	}
	ih := &d.inlay
	if ih.pending != nil {
		a.cancelSemantic(ih.pending)
		ih.pending = nil
	}
	if ih.resolve != nil {
		a.cancelSemantic(ih.resolve)
		ih.resolve = nil
	}
	if ih.prepareCancel != nil {
		ih.prepareCancel()
		ih.prepareCancel = nil
	}
	ih.prepareGen++
	ih.hints = nil
	ih.resolved = nil
	ih.revision = -1
	ih.coveredStart, ih.coveredEnd = 0, -1
	ih.dirty = false
	if d.view != nil && d.view.ClearInlayHints() {
		a.invalidator.Invalidate()
	}
	if a.semantics.inlayHover.open && a.semantics.inlayHover.documentID == d.id {
		a.semantics.inlayHover = inlayHintHoverState{}
	}
}

func (a *App) applyInlayHintsPreference(enabled bool) {
	p := a.project
	if p == nil {
		return
	}
	if !enabled {
		a.semantics.inlayHover = inlayHintHoverState{}
		for _, d := range p.docs.list {
			a.clearDocumentInlayHints(d)
		}
		return
	}
	for _, d := range p.docs.list {
		d.inlay.dirty = true
	}
	a.invalidator.Invalidate()
}

func (a *App) inlayHintsRefresh(server *pluginServer) {
	if server == nil || server.session == nil || !a.isCurrentPluginServer(server.session.PluginID, server) {
		return
	}
	p := a.project
	if p == nil || p != server.project {
		return
	}
	changed := false
	for _, d := range p.docs.list {
		if srv, _ := a.documentSyncServer(d); srv == server {
			d.inlay.dirty = true
			d.inlay.changedAt = a.now()
			changed = true
		}
	}
	if changed && a.editorPreferences.InlayHints {
		a.invalidator.Invalidate()
	}
}

// inlayHintsSync requests visible-viewport (+ bounded margin) inlay hints when enabled,
// coalescing scroll and edit bursts without idle polling or idle repaints.
func (a *App) inlayHintsSync(c ui.C, p *project, d *document) {
	if p == nil || d == nil {
		return
	}
	if !a.editorPreferences.InlayHints {
		if d.view.HasInlayHints() || d.inlay.pending != nil || d.inlay.prepareCancel != nil {
			a.clearDocumentInlayHints(d)
		}
		return
	}
	ih := &d.inlay
	if !ih.initialized {
		ih.initialized = true
		ih.revision = -1
		ih.seenRevision = -1
		ih.coveredEnd = -1
	}
	server, offered := a.editorServer(d, featureInlayHints)
	if server == nil || !offered || d.virtual {
		if d.view.HasInlayHints() || ih.pending != nil {
			a.clearDocumentInlayHints(d)
		}
		return
	}
	visFirst, visLast, ok := d.view.VisibleLineRange()
	if !ok {
		return
	}
	revision := d.view.Revision()
	if !ih.dirty && ih.revision == revision && visFirst >= ih.coveredStart && visLast <= ih.coveredEnd {
		return
	}
	if a.editorRequestWaiting(ih.pending) {
		if ih.pending.revision == revision && !ih.dirty && visFirst >= ih.reqStart && visLast <= ih.reqEnd {
			return
		}
		a.cancelSemantic(ih.pending)
		ih.pending = nil
	} else {
		ih.pending = nil
	}
	if !a.semanticDocumentReady(d) {
		return
	}
	now := a.now()
	if ih.seenRevision != revision || ih.seenFirst != visFirst || ih.seenLast != visLast {
		ih.seenRevision = revision
		ih.seenFirst = visFirst
		ih.seenLast = visLast
		ih.changedAt = now
	}
	delay := a.semantics.inlayDelay
	if delay == 0 {
		delay = inlayHintsDelay
	}
	if ih.revision >= 0 && delay > 0 {
		if wait := ih.changedAt.Add(delay).Sub(now); wait > 0 {
			c.Canvas().RequestFrameIn(wait)
			return
		}
	}
	snapshot := d.view.TextSnapshot()
	lineCount := max(snapshot.LineCount(), 1)
	reqStart := max(visFirst-inlayHintsPrefetchMargin, 0)
	reqEnd := min(visLast+inlayHintsPrefetchMargin, lineCount-1)
	end := core.PluginDocumentPosition{Line: reqEnd + 1}
	if end.Line == lineCount {
		lastStart, lastEnd := snapshot.LineStart(reqEnd), snapshot.LineEnd(reqEnd)
		if lastEnd-lastStart <= 64*1024 {
			end = core.PluginDocumentPosition{Line: reqEnd, UTF16Column: utf16CountString(snapshot.Line(reqEnd))}
		} else {
			// The editor skips annotations on long-line mode's last line.
			end = core.PluginDocumentPosition{Line: reqEnd}
		}
	}

	ih.dirty = false
	ih.reqStart = reqStart
	ih.reqEnd = reqEnd
	ih.pending = a.submitEditorRequest(pluginSemanticInlayHints, p, d, server, core.PluginSemanticRequest{
		Range: &core.PluginDocumentRange{
			Start: core.PluginDocumentPosition{Line: reqStart, UTF16Column: 0},
			End:   end,
		},
	})
}

func utf16CountString(s string) int {
	n := 0
	for _, r := range s {
		n++
		if r > 0xffff {
			n++
		}
	}
	return n
}

func (a *App) applyServerInlayHints(pending *semanticPending, event core.BackendEvent, failed bool) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.inlay.pending != pending {
		return
	}
	ih := &d.inlay
	ih.pending = nil
	if !a.editorPreferences.InlayHints {
		a.clearDocumentInlayHints(d)
		return
	}
	if d.view.Revision() != pending.revision {
		return
	}
	// Settle this range on a failed request too. A visible error should
	// not turn unrelated repaints into repeated requests to the server.
	d.inlay.revision = pending.revision
	d.inlay.coveredStart, d.inlay.coveredEnd = d.inlay.reqStart, d.inlay.reqEnd
	if failed {
		return
	}
	hints, err := core.PluginSemanticInlayHints(event)
	if err != nil {
		a.backgroundFailed("plugin_inlay_hints", err)
		return
	}
	if ih.prepareCancel != nil {
		ih.prepareCancel()
		ih.prepareCancel = nil
	}
	if ih.resolve != nil {
		a.cancelSemantic(ih.resolve)
		ih.resolve = nil
	}
	if a.semantics.inlayHover.documentID == d.id {
		a.semantics.inlayHover = inlayHintHoverState{}
	}
	d.view.ClearInlayHints()
	ih.hints = hints
	ih.resolved = nil
	ih.revision = pending.revision
	ih.coveredStart = ih.reqStart
	ih.coveredEnd = ih.reqEnd
	if len(hints) == 0 {
		a.invalidator.Invalidate()
		return
	}
	specs := make([]editorview.InlayHintSpec, len(hints))
	for i, h := range hints {
		specs[i] = editorview.InlayHintSpec{
			ID:           i,
			Line:         h.Position.Line,
			UTF16Column:  h.Position.UTF16Column,
			Label:        h.Label,
			PaddingLeft:  h.PaddingLeft,
			PaddingRight: h.PaddingRight,
			Interactive:  (h.Tooltip != nil && *h.Tooltip != "") || len(h.TextEdits) > 0 || len(h.ResolvePayload) > 0,
		}
	}
	snapshot := d.view.TextSnapshot()
	revision := pending.revision
	docID := d.id
	ih.prepareGen++
	gen := ih.prepareGen
	ctx, cancel := context.WithCancel(p.ctx)
	ih.prepareCancel = cancel
	a.background(p, 10*time.Second, func(workCtx context.Context) func(*App) {
		defer cancel()
		prepared, prepErr := editorview.PrepareInlayHints(ctx, snapshot, revision, specs)
		if prepErr != nil {
			// log-exempt: 用户取消：滚动、编辑或关闭开关会取消旧的内联提示排版计算。
			return nil
		}
		return func(a *App) {
			curProj, curDoc := a.currentSemanticDocument(docID)
			if curProj != p || curDoc == nil || !a.editorPreferences.InlayHints || curDoc.inlay.prepareGen != gen {
				return
			}
			curDoc.inlay.prepareCancel = nil
			if curDoc.view.SetPreparedInlayHints(prepared) {
				a.invalidator.Invalidate()
			}
		}
	})
}

func (a *App) applyResolvedInlayHint(pending *semanticPending, event core.BackendEvent, failed bool) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.inlay.resolve != pending {
		return
	}
	ih := &d.inlay
	idx := ih.resolveIndex
	ih.resolve = nil
	if failed || d.view.Revision() != pending.revision || idx < 0 || idx >= len(ih.hints) {
		return
	}
	resolved, err := core.PluginSemanticResolvedInlayHint(event)
	if err != nil || resolved == nil {
		if err != nil {
			a.backgroundFailed("plugin_inlay_hint_resolve", err)
		}
		return
	}
	ih.hints[idx] = *resolved
	if ih.resolved == nil {
		ih.resolved = make(map[int]bool)
	}
	ih.resolved[idx] = true
	a.invalidator.Invalidate()
}

func (a *App) inlayHintPointer(event gfx.PointerEvent, p *project, d *document, view *editorview.View) (gfx.EventResult, bool) {
	if p == nil || d == nil || view == nil || !a.editorPreferences.InlayHints {
		return gfx.EventResult{}, false
	}
	switch event.Kind {
	case gfx.PointerMove:
		if pointInRect(a.semantics.inlayHover.rect, event.X, event.Y) {
			return gfx.EventResult{}, false
		}
		id, rect, ok := view.InlayHintAt(event.X, event.Y)
		if !ok || id < 0 || id >= len(d.inlay.hints) {
			if a.semantics.inlayHover.open {
				a.semantics.inlayHover = inlayHintHoverState{}
				a.invalidator.Invalidate()
			}
			return gfx.EventResult{}, false
		}
		hint := d.inlay.hints[id]
		server, _ := a.editorServer(d, featureInlayHintResolve)
		canResolve := server != nil && server.features[featureInlayHintResolve] && len(hint.ResolvePayload) > 0 && !d.inlay.resolved[id]
		hasTooltip := hint.Tooltip != nil && strings.TrimSpace(*hint.Tooltip) != ""
		hasEdits := len(hint.TextEdits) > 0 && !d.view.ReadOnly()
		if !hasTooltip && !hasEdits && !canResolve {
			return gfx.EventResult{}, false
		}
		if canResolve && !hasTooltip && !hasEdits && d.inlay.resolve == nil {
			d.inlay.resolveIndex = id
			d.inlay.resolve = a.submitEditorRequest(pluginSemanticResolveInlayHint, p, d, server, core.PluginSemanticRequest{
				InlayHint: hint.Raw,
			})
		}
		if !a.semantics.inlayHover.open || a.semantics.inlayHover.documentID != d.id || a.semantics.inlayHover.hintIndex != id {
			a.semantics.project = p
			a.semantics.inlayHover = inlayHintHoverState{
				open:       true,
				documentID: d.id,
				revision:   d.view.Revision(),
				hintIndex:  id,
				anchor:     rect,
			}
			a.invalidator.Invalidate()
		}
		return gfx.EventResult{}, false
	case gfx.PointerDown:
		if event.Button == gfx.PointerButtonPrimary && event.ClickCount >= 2 && !d.view.ReadOnly() && !d.caretView().IsComposing() {
			id, _, ok := view.InlayHintAt(event.X, event.Y)
			if ok && id >= 0 && id < len(d.inlay.hints) && len(d.inlay.hints[id].TextEdits) > 0 {
				a.applyInlayHintEdits(p, d, id)
				return gfx.EventResult{Handled: true, Repaint: true}, true
			}
		}
		if a.semantics.inlayHover.open && !pointInRect(a.semantics.inlayHover.rect, event.X, event.Y) {
			a.semantics.inlayHover = inlayHintHoverState{}
		}
	case gfx.PointerExit:
		if a.semantics.inlayHover.open {
			a.semantics.inlayHover = inlayHintHoverState{}
			a.invalidator.Invalidate()
		}
	}
	return gfx.EventResult{}, false
}

func (a *App) applyInlayHintEdits(p *project, d *document, hintIndex int) {
	if p == nil || d == nil || p != a.project || d.view.ReadOnly() || d.caretView().IsComposing() {
		return
	}
	if hintIndex < 0 || hintIndex >= len(d.inlay.hints) || d.inlay.revision != d.view.Revision() {
		return
	}
	edits := d.inlay.hints[hintIndex].TextEdits
	if len(edits) == 0 {
		return
	}
	a.semantics.inlayHover = inlayHintHoverState{}
	a.performed("editor.inlayHint.apply", surfaceButton)
	a.applyEditsToDocument(p, d, edits, "plugin_inlay_hint_apply")
}

func (a *App) inlayHintHoverPopup(c ui.C) {
	st := &a.semantics.inlayHover
	if !st.open || !a.editorPreferences.InlayHints {
		return
	}
	p, d := a.currentSemanticDocument(st.documentID)
	if d == nil || p != a.project || d.view.Revision() != st.revision || st.hintIndex < 0 || st.hintIndex >= len(d.inlay.hints) {
		*st = inlayHintHoverState{}
		return
	}
	hint := d.inlay.hints[st.hintIndex]
	tooltip := ""
	if hint.Tooltip != nil {
		tooltip = truncateDisplayText(*hint.Tooltip, 260)
	}
	hasEdits := len(hint.TextEdits) > 0 && !d.view.ReadOnly()
	if tooltip == "" && !hasEdits {
		return
	}
	bounds := c.Bounds()
	width := float32(300)
	if tooltip == "" {
		width = 180
	}
	height := float32(40)
	if tooltip != "" && hasEdits {
		height = 68
	} else if tooltip != "" && utf8.RuneCountInString(tooltip) > 42 {
		height = 56
	}
	x, y := popupOrigin(st.anchor.X, st.anchor.Y+st.anchor.Height+2, width, bounds)
	st.rect = gfx.Rect{X: x, Y: y, Width: width, Height: height}
	lang := a.language()
	label := i18n.Shared(lang, "desktop.semantics.inlayHintTooltip")
	applyClicked := false
	ui.Stack(c.Part("inlay-hover-layer")).Fill().Children(func() {
		hc := c.Part("inlay-hover-card")
		ui.Column(hc).Absolute().Left(x).Top(y).Width(width).Pad(8).Gap(6).
			Background(a.theme.Popover).Border(1, a.theme.Border).
			Radius(a.theme.Metrics.RadiusPopup()).Shadow(gfx.ShadowMD).
			HitWith(ui.ID(hc), label, gfx.HitOptions{Role: gfx.RoleGroup, SkipFocus: true}).
			Children(func() {
				if tooltip != "" {
					ui.Wrap(hc, tooltip).FontSize(11.5).Color(a.colors.Text)
				}
				if hasEdits {
					btnLabel := i18n.Shared(lang, "desktop.semantics.inlayHintApply")
					bc := hc.Part("apply-inlay-edit")
					btn := ui.Row(bc).Height(22).PadX(8).Center().Radius(4).
						Background(a.colors.Active).
						HitWith(ui.ID(bc), btnLabel, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Cursor: gfx.PointerCursorHand}).
						Hover(ui.Look{}.Background(a.colors.Hover))
					btn.Children(func() {
						ui.Text(bc, btnLabel).FontSize(11.5).Color(a.colors.Text)
					})
					if btn.Clicked() {
						applyClicked = true
					}
				}
			})
	})
	if applyClicked {
		idx := st.hintIndex
		c.After(func() { a.applyInlayHintEdits(p, d, idx) })
	}
}
