package workbench

import (
	"context"
	"encoding/json"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	pluginSemanticSignatureHelp semanticKind = "signatureHelp"
	pluginMethodSignatureHelp                = "textDocument/signatureHelp"
	featureSignatureHelp                     = "signatureHelp"

	semanticAutoSignatureDelay = 60 * time.Millisecond
	signatureHelpMaxWidth      = float32(520)
	signatureHelpMinWidth      = float32(220)
)

type signatureHelpState struct {
	open            bool
	help            *core.PluginSemanticSignatureHelp
	activeSignature int
	documentID      int
	revision        int
	line, column    int
	rect            gfx.Rect
}

// signatureHelpShortcut handles explicit Parameter Info (Command+P on macOS, Control+P elsewhere).
func (a *App) signatureHelpShortcut(event gfx.KeyEvent) gfx.EventResult {
	if event.Release || event.Modifiers != primaryModifier() || !strings.EqualFold(event.Text, "p") {
		return gfx.EventResult{}
	}
	p, d := a.pluginSemanticHit(event.Target)
	if d == nil || d.caretView().IsComposing() {
		return gfx.EventResult{}
	}
	if _, offered := a.editorServer(d, featureSignatureHelp); !offered {
		return gfx.EventResult{}
	}
	line, column := d.caretView().CaretUTF16()
	a.startPluginSignatureHelp(p, d, line, column, surfaceShortcut)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// startPluginSignatureHelp explicitly invokes textDocument/signatureHelp at (line, column).
func (a *App) startPluginSignatureHelp(p *project, d *document, line, column int, surface actionSurface) {
	ctx := a.buildSignatureHelpContext(1, "", a.semantics.signatureHelp.open, a.activeSignatureHelpRaw(d))
	if surface != "" {
		a.performed("editor.semantics.signatureHelp", surface)
	}
	a.requestPluginSignatureHelp(p, d, line, column, ctx, false)
}

func (a *App) activeSignatureHelpRaw(d *document) json.RawMessage {
	st := &a.semantics.signatureHelp
	if !st.open || st.help == nil || d == nil || st.documentID != d.id {
		return nil
	}
	return st.help.Raw
}

func (a *App) buildSignatureHelpContext(triggerKind int, triggerChar string, isRetrigger bool, activeRaw json.RawMessage) json.RawMessage {
	payload := map[string]any{
		"triggerKind": triggerKind,
		"isRetrigger": isRetrigger,
	}
	if triggerKind == 2 && triggerChar != "" {
		payload["triggerCharacter"] = triggerChar
	}
	if isRetrigger && len(activeRaw) > 0 {
		payload["activeSignatureHelp"] = activeRaw
	}
	raw, _ := json.Marshal(payload)
	return raw
}

func (a *App) requestPluginSignatureHelp(p *project, d *document, line, column int, sigCtx json.RawMessage, automatic bool) {
	if a.plugins == nil || p == nil || d == nil || a.project != p || d.caretView().IsComposing() {
		return
	}
	if automatic {
		if caretLine, caretCol := d.caretView().CaretUTF16(); caretLine != line || caretCol != column {
			return
		}
	}
	retry := func(a *App) {
		a.requestPluginSignatureHelp(p, d, line, column, sigCtx, automatic)
	}
	if !a.semanticDocumentReady(d) {
		if automatic {
			// Coalesce automatic signature help behind document sync without clobbering explicit deferred actions.
			a.semantics.sigDeferred = retry
			a.semantics.project = p
			a.semantics.documentID = d.id
		} else {
			a.deferSemantic(p, d, retry)
		}
		a.startDocumentSync(p, d)
		return
	}
	server, ok := a.semanticServer(d)
	if !ok {
		if !automatic {
			a.notify(i18n.Shared(a.language(), "desktop.semantics.noServer"))
		}
		return
	}
	if !server.isReady() {
		if !automatic {
			a.deferSemantic(p, d, retry)
		}
		return
	}
	if !server.features[featureSignatureHelp] {
		if !automatic {
			a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noSignatureHelp"))
		}
		return
	}
	position := core.PluginDocumentPosition{Line: line, UTF16Column: column}
	a.cancelSemanticKind(pluginSemanticSignatureHelp)
	pending := a.newSemanticPending(pluginSemanticSignatureHelp, p, d, server, line, column, true, false)
	pending.automatic = automatic
	a.semantics.pending = append(a.semantics.pending, pending)
	request := core.PluginSemanticRequest{
		Operation:            string(pluginSemanticSignatureHelp),
		URI:                  d.sync.uri,
		Position:             &position,
		SignatureHelpContext: sigCtx,
	}
	a.background(pending.project, semanticStartTimeout, func(ctx context.Context) func(*App) {
		operation, err := a.plugins.RequestLanguageSession(ctx, pending.server.session, request)
		return func(a *App) { a.semanticRequestStarted(pending, operation, err, ctx.Err()) }
	})
}

func (a *App) scheduleAutoSignatureHelp(p *project, d *document, edit editorview.Edit) {
	if a.semantics.sigCancel != nil {
		a.semantics.sigCancel()
		a.semantics.sigCancel = nil
	}
	if a.plugins == nil || a.project != p || d == nil || d.caretView().IsComposing() {
		return
	}
	server, ok := a.semanticServer(d)
	if !ok || !server.isReady() || !server.features[featureSignatureHelp] {
		a.closeSemanticSignatureHelp()
		return
	}
	line, column := d.caretView().CaretUTF16()
	previous := &a.semantics.signatureHelp
	wasOpen := previous.open && previous.documentID == d.id
	trigger := ""
	if edit.StartLine == edit.EndLine && edit.StartColumn == edit.EndColumn &&
		utf8.RuneCountInString(edit.Text) == 1 &&
		(slices.Contains(server.signatureHelpTriggers, edit.Text) ||
			wasOpen && slices.Contains(server.signatureHelpRetriggers, edit.Text)) {
		trigger = edit.Text
	}
	if trigger == "" && !wasOpen {
		return
	}
	kind := 3 // ContentChange
	if trigger != "" {
		kind = 2 // TriggerCharacter
	}
	sigCtx := a.buildSignatureHelpContext(kind, trigger, wasOpen, a.activeSignatureHelpRaw(d))
	if wasOpen {
		previous.revision = d.view.Revision()
		previous.line, previous.column = line, column
	}
	a.queueDebouncedSignatureHelp(p, d, line, column, sigCtx)
}

func (a *App) queueDebouncedSignatureHelp(p *project, d *document, line, column int, sigCtx json.RawMessage) {
	if a.semantics.sigCancel != nil {
		a.semantics.sigCancel()
		a.semantics.sigCancel = nil
	}
	delay := a.semantics.sigDelay
	if delay == 0 {
		delay = semanticAutoSignatureDelay
	}
	ctx, cancel := context.WithCancel(p.ctx)
	a.semantics.sigCancel = cancel
	a.semantics.sigGeneration++
	generation := a.semantics.sigGeneration
	if delay < 0 {
		cancel()
		a.semantics.sigCancel = nil
		a.requestPluginSignatureHelp(p, d, line, column, sigCtx, true)
		return
	}
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			// log-exempt: 用户取消：继续输入、移动光标或关闭项目会取消签名提示防抖等待。
			return nil
		}
		return func(a *App) {
			if a.semantics.sigGeneration != generation {
				return
			}
			a.requestPluginSignatureHelp(p, d, line, column, sigCtx, true)
		}
	})
}

func (a *App) syncSignatureHelpCaret() {
	st := &a.semantics.signatureHelp
	if !st.open {
		return
	}
	p, d := a.currentSemanticDocument(st.documentID)
	if d == nil || p != a.project {
		a.closeSemanticSignatureHelp()
		return
	}
	line, column := d.caretView().CaretUTF16()
	if d.view.Revision() != st.revision || d.caretView().IsComposing() {
		a.closeSemanticSignatureHelp()
		return
	}
	if line == st.line && column == st.column {
		return
	}
	st.line, st.column = line, column
	sigCtx := a.buildSignatureHelpContext(3, "", true, st.help.Raw)
	a.queueDebouncedSignatureHelp(p, d, line, column, sigCtx)
}

func (a *App) applySemanticSignatureHelp(pending *semanticPending, event core.BackendEvent) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.view.Revision() != pending.revision || !a.semanticPositionCurrent(pending, d) {
		return
	}
	help, err := core.PluginSemanticSignatureHelpFromEvent(event)
	if err != nil {
		a.backgroundFailed("plugin_signature_help", err)
		return
	}
	if help == nil || len(help.Signatures) == 0 {
		a.closeSemanticSignatureHelp()
		if !pending.automatic {
			a.notifyInfo(i18n.Shared(a.language(), "desktop.semantics.noSignatureHelp"))
		}
		return
	}
	active := min(max(help.ActiveSignature, 0), len(help.Signatures)-1)
	a.semantics.signatureHelp = signatureHelpState{
		open:            true,
		help:            help,
		activeSignature: active,
		documentID:      d.id,
		revision:        pending.revision,
		line:            pending.line,
		column:          pending.column,
	}
}

func (a *App) closeSemanticSignatureHelp() {
	if a.semantics.sigCancel != nil {
		a.semantics.sigCancel()
		a.semantics.sigCancel = nil
	}
	a.semantics.sigGeneration++
	a.semantics.sigDeferred = nil
	a.semantics.signatureHelp = signatureHelpState{}
	a.cancelSemanticKind(pluginSemanticSignatureHelp)
}

func (a *App) stepSignatureOverload(delta int) {
	st := &a.semantics.signatureHelp
	if !st.open || st.help == nil || len(st.help.Signatures) <= 1 {
		return
	}
	n := len(st.help.Signatures)
	st.activeSignature = (st.activeSignature + delta + n) % n
}

func (a *App) signatureHelpKey(event gfx.KeyEvent) gfx.EventResult {
	st := &a.semantics.signatureHelp
	if !st.open || st.help == nil {
		return gfx.EventResult{}
	}
	if event.Key == gfx.KeyEscape && !a.semantics.completion.open && !a.semantics.codeActions.open && !a.semantics.definition.open {
		a.closeSemanticSignatureHelp()
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if len(st.help.Signatures) > 1 {
		noOtherList := !a.semantics.completion.open && !a.semantics.codeActions.open && !a.semantics.definition.open
		if (event.Modifiers == gfx.ModifierAlt || (event.Modifiers == 0 && noOtherList)) && event.Key == gfx.KeyUp {
			a.stepSignatureOverload(-1)
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		if (event.Modifiers == gfx.ModifierAlt || (event.Modifiers == 0 && noOtherList)) && event.Key == gfx.KeyDown {
			a.stepSignatureOverload(1)
			return gfx.EventResult{Handled: true, Repaint: true}
		}
	}
	return gfx.EventResult{}
}

func (a *App) signatureHelpPopup(c ui.C, completion gfx.Rect) {
	st := &a.semantics.signatureHelp
	if !st.open || st.help == nil || len(st.help.Signatures) == 0 {
		return
	}
	p, d := a.currentSemanticDocument(st.documentID)
	if d == nil || p != a.project {
		a.closeSemanticSignatureHelp()
		return
	}
	anchor, ok := d.caretView().CaretRect()
	if !ok {
		a.closeSemanticSignatureHelp()
		return
	}
	sigIdx := min(max(st.activeSignature, 0), len(st.help.Signatures)-1)
	sig := st.help.Signatures[sigIdx]
	activeParam := st.help.ActiveParameter
	if sig.ActiveParameter != nil {
		activeParam = sig.ActiveParameter
	}

	var prefix, highlighted, suffix string
	var paramDoc string
	prefix = sig.Label
	if activeParam != nil && *activeParam >= 0 && *activeParam < len(sig.Parameters) {
		param := sig.Parameters[*activeParam]
		if param.Documentation != nil {
			paramDoc = truncateDisplayText(*param.Documentation, 180)
		}
		if param.ByteStart != nil && param.ByteEnd != nil {
			bs, be := *param.ByteStart, *param.ByteEnd
			if bs >= 0 && bs <= be && be <= len(sig.Label) {
				prefix = sig.Label[:bs]
				highlighted = sig.Label[bs:be]
				suffix = sig.Label[be:]
			}
		}
	}
	sigDoc := ""
	if sig.Documentation != nil {
		sigDoc = truncateDisplayText(*sig.Documentation, 200)
	}

	const (
		padX             = 10
		padY             = 6
		gap              = 4
		headerHeight     = 22
		docLineHeight    = 18
		paramDocSize     = 11.5
		signatureDocSize = 11
	)
	const horizontalInsets = 2 * (padX + semanticPopupBorder)
	bounds := c.Bounds().Inset(gfx.All(semanticPopupMargin))
	if bounds.Width <= horizontalInsets {
		st.rect = gfx.Rect{}
		return
	}
	charWidth := max(d.view.CellWidth(), 7.5)
	labelRunes := float32(utf8.RuneCountInString(sig.Label))
	overloadRoom := float32(28)
	if len(st.help.Signatures) > 1 {
		overloadRoom = 96
	}
	width := min(max(labelRunes*charWidth+overloadRoom, signatureHelpMinWidth), signatureHelpMaxWidth, bounds.Width)
	height := float32(headerHeight + 2*(padY+semanticPopupBorder))
	hasDocs := paramDoc != "" || sigDoc != ""
	if hasDocs {
		height += gap + 1
		var scratch [8]string
		for _, doc := range []struct {
			text string
			size float32
		}{{paramDoc, paramDocSize}, {sigDoc, signatureDocSize}} {
			if doc.text != "" {
				lines := c.Canvas().WrapLinesStyle(scratch[:0], doc.text, gfx.TextStyle{Size: doc.size},
					width-horizontalInsets, utf8.RuneCountInString(doc.text), nil)
				height += float32(len(lines))*docLineHeight + gap
			}
		}
	}
	rect := signatureHelpPosition(bounds, anchor, completion, width, height)
	st.rect = rect
	if rect.Height == 0 {
		return
	}
	lang := a.language()
	title := i18n.Shared(lang, "desktop.semantics.signatureHelp")
	stepDelta := 0

	ui.Stack(c.Part("signature-help-layer")).Fill().Children(func() {
		sc := c.Part("signature-help-card")
		ui.Column(sc).Absolute().Left(rect.X).Top(rect.Y).Width(width).Height(height).PadX(padX).PadY(padY).Gap(gap).
			Background(a.theme.Popover).Border(semanticPopupBorder, a.theme.Border).
			Radius(a.theme.Metrics.RadiusPopup()).Shadow(gfx.ShadowMD).
			HitWith(ui.ID(sc), title, gfx.HitOptions{Role: gfx.RoleGroup, SkipFocus: true}).
			Children(func() {
				ui.Row(sc).FillWidth().Height(headerHeight).Items(ui.Center).Gap(6).Children(func() {
					ui.Row(sc).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Gap(0).Clip().Children(func() {
						if prefix != "" {
							ui.Text(sc, prefix).Mono().FontSize(12).Color(a.colors.Subtle).Shrink(1).Ellipsis()
						}
						if highlighted != "" {
							ui.Row(sc.Part("active-param")).PadX(3).PadY(1).Radius(3).
								Background(a.colors.Active).Shrink(0).Children(func() {
								ui.Text(c, highlighted).Mono().FontSize(12).
									Weight(gfx.WeightBold).Color(a.colors.Text)
							})
						}
						if suffix != "" {
							ui.Text(sc, suffix).Mono().FontSize(12).Color(a.colors.Subtle).Shrink(1).Ellipsis()
						}
					})
					if len(st.help.Signatures) > 1 {
						counter := i18n.SharedFormat(lang, "desktop.semantics.signatureOverload", map[string]string{
							"current": strconv.Itoa(sigIdx + 1),
							"total":   strconv.Itoa(len(st.help.Signatures)),
						})
						prevLabel := i18n.Shared(lang, "desktop.semantics.signaturePrevious")
						nextLabel := i18n.Shared(lang, "desktop.semantics.signatureNext")
						ui.Row(sc.Part("overloads")).Shrink(0).Items(ui.Center).Gap(2).Children(func() {
							prevC := sc.Part("sig-prev")
							prevBtn := ui.Row(prevC).Size(16, 16).Center().Radius(3).
								HitWith(ui.ID(prevC), prevLabel, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Cursor: gfx.PointerCursorHand}).
								Hover(ui.Look{}.Background(a.colors.Hover))
							prevBtn.Children(func() {
								ui.Icon(prevC, icons.ChevronUp).Size(11, 11).Color(a.colors.Subtle)
							})
							if prevBtn.Clicked() {
								stepDelta = -1
							}
							ui.Text(sc, counter).FontSize(11).Color(a.colors.Subtle)
							nextC := sc.Part("sig-next")
							nextBtn := ui.Row(nextC).Size(16, 16).Center().Radius(3).
								HitWith(ui.ID(nextC), nextLabel, gfx.HitOptions{Role: gfx.RoleButton, SkipFocus: true, Cursor: gfx.PointerCursorHand}).
								Hover(ui.Look{}.Background(a.colors.Hover))
							nextBtn.Children(func() {
								ui.Icon(nextC, icons.ChevronDown).Size(11, 11).Color(a.colors.Subtle)
							})
							if nextBtn.Clicked() {
								stepDelta = 1
							}
						})
					}
				})
				if hasDocs {
					ui.Row(sc).FillWidth().Height(1).Background(a.theme.Border)
					if paramDoc != "" {
						ui.Wrap(sc, paramDoc).FillWidth().FontSize(paramDocSize).LineHeight(docLineHeight).Color(a.colors.Text)
					}
					if sigDoc != "" {
						ui.Wrap(sc, sigDoc).FillWidth().FontSize(signatureDocSize).LineHeight(docLineHeight).Color(a.colors.Subtle)
					}
				}
			})
	})
	if stepDelta != 0 {
		c.After(func() { a.stepSignatureOverload(stepDelta) })
	}
}

// signatureHelpPosition keeps the active editor line visible even when the
// completion popup has moved above it. If no position fits, completion wins.
func signatureHelpPosition(bounds, caret, completion gfx.Rect, width, height float32) gfx.Rect {
	const caretGap, popupGap = 4, 8
	x := min(max(caret.X, bounds.X), bounds.Right()-width)
	above := caret.Y - caretGap - height
	below := caret.Bottom() + caretGap
	positions := [...]gfx.Point{
		{X: x, Y: above},
		{X: x, Y: below},
		{X: completion.Right() + popupGap, Y: above},
		{X: completion.X - popupGap - width, Y: above},
		{X: completion.Right() + popupGap, Y: below},
		{X: completion.X - popupGap - width, Y: below},
		{X: x, Y: max(completion.Bottom()+popupGap, below)},
		{X: x, Y: min(completion.Y-popupGap-height, above)},
	}
	options := positions[:]
	if completion.Height == 0 {
		options = options[:2]
	}
	for _, origin := range options {
		if origin.X < bounds.X || origin.X+width > bounds.Right() || origin.Y < bounds.Y || origin.Y+height > bounds.Bottom() {
			continue
		}
		if completion.Height > 0 && origin.X < completion.Right() && origin.X+width > completion.X &&
			origin.Y < completion.Bottom() && origin.Y+height > completion.Y {
			continue
		}
		return gfx.Rect{X: origin.X, Y: origin.Y, Width: width, Height: height}
	}
	return gfx.Rect{}
}
