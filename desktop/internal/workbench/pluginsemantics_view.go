package workbench

import (
	"math"
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	semanticRowPad              = 8
	semanticRowGap              = 8
	semanticListGap             = 1
	semanticPopupBorder         = 1
	semanticPopupMargin         = 4
	completionMinWidth          = 360
	completionMaxWidth          = 640
	completionLabelSize         = 12
	completionDetailSize        = 11
	completionPreviewLines      = 3
	completionPreviewLineHeight = 18
	completionPreviewPadY       = 4
	completionPreviewMaxHeight  = completionPreviewLines*completionPreviewLineHeight + 2*completionPreviewPadY
	completionPreviewMinHeight  = completionPreviewLineHeight + 2*completionPreviewPadY
	// Keep single-line measurement and each virtual preview block bounded,
	// including when the server sends one long line without newlines.
	completionTextBlockBytes = 512
)

// semanticPopups declares the open rename dialog or the definition, completion
// or hover popup. The popups are placed at the caret and never take the
// keyboard: the editor keeps it, and pluginSemanticsKey moves their selection.
// Lists lay out only the visible window, so a large server answer costs a
// constant number of views.
func (a *App) semanticPopups(c ui.C) {
	state := &a.semantics
	if p := a.project; p != nil {
		a.codeActionLightbulb(c, p, p.selectedDocument(p.docs.group))
		if !state.rename.open && !state.codeActions.open && !state.definition.open {
			a.editorActionHoverPopup(c, p, p.selectedDocument(p.docs.group))
		}
	}
	if a.project == nil || state.project != a.project {
		return
	}
	var completionBounds gfx.Rect
	switch {
	case state.rename.open:
		a.renameDialog(c)
	case state.codeActions.open:
		a.codeActionsPopup(c)
	case state.definition.open:
		a.definitionPopup(c)
	case state.completion.open:
		completionBounds = a.completionPopup(c)
	case state.hover.open:
		a.hoverPopup(c)
	}
	if !state.rename.open && !state.codeActions.open && !state.definition.open {
		a.signatureHelpPopup(c, completionBounds)
		a.inlayHintHoverPopup(c)
	}
}

// semanticPopup declares a popup panel at x, y over the window. The panel is
// named so a press on it does not reach the editor behind it, and takes no focus.
func (a *App) semanticPopup(c ui.C, x, y, width, maxHeight float32, label string, pad float32, body func()) {
	ui.Stack(c).Fill().Children(func() {
		ui.Column(c).Absolute().Left(x).Top(y).Width(width).MaxHeight(maxHeight).Pad(pad).
			Background(a.theme.Popover).Border(semanticPopupBorder, a.theme.Border).
			Radius(a.theme.Metrics.RadiusPopup()).Shadow(gfx.ShadowMD).
			HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleMenu, SkipFocus: true}).
			Children(body)
	})
}

// semanticRow declares one choice of a popup and reports whether it was clicked.
func (a *App) semanticRow(c ui.C, index int, label string, selected bool, content func(c ui.C)) bool {
	rc := c.KeyInt(index)
	row := ui.Row(rc).FillWidth().Height(semanticRowHeight).Items(ui.Center).PadX(semanticRowPad).Gap(semanticRowGap).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(rc), label, gfx.HitOptions{Role: gfx.RoleOption, SkipFocus: true, Cursor: gfx.PointerCursorHand}).
		Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
	if selected {
		row = row.Background(a.colors.Active)
	}
	row.Children(func() { content(rc) })
	return row.Clicked()
}

func (a *App) definitionPopup(c ui.C) {
	state := &a.semantics.definition
	p, d := a.currentSemanticDocument(state.documentID)
	if d == nil || p != a.project || d.view.Revision() != state.revision {
		a.closeSemanticDefinition()
		return
	}
	var anchor gfx.Rect
	var ok bool
	if state.anchor != nil {
		anchor, ok = *state.anchor, true
	} else {
		anchor, ok = d.caretView().CaretRect()
	}
	if !ok {
		a.closeSemanticDefinition()
		return
	}
	first, last := semanticWindow(state.selected, len(state.targets))
	x, y := popupOrigin(anchor.X, anchor.Y+anchor.Height+2, semanticDefinitionWidth, c.Bounds())
	chosen := -1
	a.semanticPopup(c, x, y, semanticDefinitionWidth, float32(visibleSemanticRows)*semanticRowHeight+2*semanticPopupPad,
		a.definitionPopupTitle(), semanticPopupPad, func() {
			ui.Column(c).FillWidth().Gap(1).Children(func() {
				for i := first; i < last; i++ {
					label := a.definitionLabel(state.targets[i])
					if a.semanticRow(c, i, label, i == state.selected, func(rc ui.C) {
						ui.Text(rc, label).FontSize(12).Ellipsis()
					}) {
						chosen = i
					}
				}
			})
		})
	if chosen >= 0 {
		c.After(func() { a.choosePluginDefinition(chosen) })
	}
}

type completionRowLayout struct {
	nameWidth, detailWidth  float32
	name, detail            string
	nameClipped, moreDetail bool
}

// completionSummary reads only a bounded first line. The preview still uses the
// original text, so even a candidate whose label contains a signature is readable.
func completionSummary(value string) (string, bool) {
	end := min(len(value), completionTextBlockBytes)
	if end < len(value) {
		end = gfx.GraphemeStart(value[:min(end+utf8.UTFMax, len(value))], end)
		// A single cluster longer than the whole budget cannot appear in a summary.
		if end == 0 {
			return "…", true
		}
	}
	if line, _, found := strings.Cut(value[:end], "\n"); found {
		return strings.TrimSuffix(line, "\r"), true
	}
	return value[:end], end < len(value)
}

func (a *App) completionPopup(c ui.C) gfx.Rect {
	state := &a.semantics.completion
	p, d := a.currentSemanticDocument(state.documentID)
	if p != a.project || !completionPositionCurrent(d, state.revision, state.line, state.column) {
		a.closeSemanticCompletion()
		return gfx.Rect{}
	}
	anchor, ok := d.caretView().CaretRect()
	if !ok {
		a.closeSemanticCompletion()
		return gfx.Rect{}
	}

	bounds := c.Bounds().Inset(gfx.All(semanticPopupMargin))
	const (
		popupInsets = 2 * (semanticPopupPad + semanticPopupBorder)
		rowInsets   = popupInsets + 2*semanticRowPad
		caretGap    = 2
		rowStep     = semanticRowHeight + semanticListGap
	)
	above := anchor.Y - caretGap - bounds.Y
	below := bounds.Bottom() - (anchor.Bottom() + caretGap)
	if bounds.Width <= rowInsets || anchor.Bottom() <= bounds.Y || anchor.Y >= bounds.Bottom() ||
		max(above, below) < semanticRowHeight+popupInsets {
		return gfx.Rect{}
	}
	first, last := semanticWindow(state.selected, len(state.items))
	if first == last {
		return gfx.Rect{}
	}
	canvas := c.Canvas()
	var rows [visibleSemanticRows]completionRowLayout
	desiredWidth := float32(completionMinWidth)
	for i, item := range state.items[first:last] {
		name, nameClipped := completionSummary(item.Label)
		detail, moreDetail := completionSummary(item.Detail)
		nameWidth := float32(math.Ceil(float64(canvas.TextWidth(name, completionLabelSize))))
		detailWidth := float32(math.Ceil(float64(canvas.TextWidth(detail, completionDetailSize))))
		rows[i] = completionRowLayout{nameWidth, detailWidth, name, detail, nameClipped, moreDetail}
		rowWidth := rowInsets + nameWidth
		if detailWidth > 0 {
			rowWidth += semanticRowGap + detailWidth
		}
		desiredWidth = max(desiredWidth, rowWidth)
	}
	width := min(desiredWidth, completionMaxWidth, bounds.Width)
	textWidth := width - rowInsets

	selected := state.items[state.selected]
	selectedRow := rows[state.selected-first]
	var preview [2]string
	if selectedRow.nameClipped || selectedRow.nameWidth > textWidth {
		preview = [2]string{selected.Label, selected.Detail}
	} else if selectedRow.moreDetail || selectedRow.detailWidth > 0 && selectedRow.nameWidth+semanticRowGap+selectedRow.detailWidth > textWidth {
		preview[1] = selected.Detail
	}

	previewHeight := completionPreviewHeight(canvas, preview, textWidth)
	height := popupInsets + float32(last-first)*rowStep - semanticListGap
	if previewHeight > 0 {
		height += previewHeight + semanticListGap
	}
	// Choose a side before limiting the row window. Clamping a too-tall
	// popup after placement can make it cover the line being edited.
	placeAbove := height > below && above > below
	available := below
	if placeAbove {
		available = above
	}
	previewHeight = min(previewHeight, available-popupInsets-semanticRowHeight-semanticListGap)
	footerHeight := float32(0)
	if previewHeight >= completionPreviewMinHeight {
		footerHeight = previewHeight + semanticListGap
	}
	maxRows := max(1, int((available-popupInsets-footerHeight+semanticListGap)/rowStep))
	from := min(max(first, state.selected-maxRows+1), max(first, last-maxRows))
	to := min(last, from+maxRows)
	height = popupInsets + float32(to-from)*rowStep - semanticListGap + footerHeight
	x := min(max(anchor.X, bounds.X), bounds.Right()-width)
	y := anchor.Bottom() + caretGap
	if placeAbove {
		y = anchor.Y - caretGap - height
	}

	chosen := -1
	language := a.language()
	a.semanticPopup(c, x, y, width, height, i18n.Shared(language, "desktop.semantics.completion"), semanticPopupPad, func() {
		ui.Column(c).FillWidth().Gap(semanticListGap).Children(func() {
			for index := from; index < to; index++ {
				item := state.items[index]
				row := rows[index-first]
				if a.semanticRow(c, index, item.Label, index == state.selected, func(rc ui.C) {
					nameWidth := min(row.nameWidth, textWidth)
					ui.Text(rc, row.name).FontSize(completionLabelSize).Width(nameWidth).Shrink(0).Ellipsis()
					detailRoom := textWidth - nameWidth - semanticRowGap
					if row.detail != "" && detailRoom >= min(row.detailWidth, completionDetailSize*3) {
						ui.Text(rc, row.detail).FontSize(completionDetailSize).Color(a.colors.Subtle).
							Width(detailRoom).Shrink(0).Ellipsis()
					}
				}) {
					chosen = index
				}
			}
		})
		if footerHeight > 0 {
			ui.Divider(c).Height(semanticListGap)
			ui.Column(c.KeyInt(state.selected)).FillWidth().Height(previewHeight).Children(func() {
				a.completionPreview(c, preview, previewHeight)
			})
		}
	})
	if chosen >= 0 {
		c.After(func() { a.acceptPluginCompletion(chosen) })
	}
	return gfx.Rect{X: x, Y: y, Width: width, Height: height}
}

func completionPreviewHeight(canvas *gfx.Canvas, text [2]string, width float32) float32 {
	var scratch [completionPreviewLines]string
	lineCount := 0
	for _, part := range text {
		if len(part) > completionTextBlockBytes {
			return completionPreviewMaxHeight
		}
		lines := canvas.WrapLines(scratch[:0], part, completionLabelSize, gfx.WeightRegular, width, len(scratch)-lineCount)
		lineCount += len(lines)
	}
	if lineCount == 0 {
		return 0
	}
	return float32(lineCount)*completionPreviewLineHeight + 2*completionPreviewPadY
}

func (a *App) completionPreview(c ui.C, text [2]string, height float32) {
	first := completionBlockCount(text[0])
	total := first + completionBlockCount(text[1])
	language := a.language()
	vertical := i18n.Shared(language, "desktop.editor.verticalScrollbar")
	horizontal := i18n.Shared(language, "desktop.editor.horizontalScrollbar")
	if len(text[0]) <= completionTextBlockBytes && len(text[1]) <= completionTextBlockBytes {
		ui.Scroll(c).FillWidth().Height(height).Scrollbars().ScrollbarLabels(vertical, horizontal).Children(func() {
			ui.Column(c).FillWidth().PadX(semanticRowPad).PadY(completionPreviewPadY).Children(func() {
				for _, part := range text {
					if part != "" {
						ui.Wrap(c, part).FillWidth().FontSize(completionLabelSize).LineHeight(completionPreviewLineHeight)
					}
				}
			})
		})
		return
	}

	list := ui.State[ui.ListState](c, "preview-blocks")
	ui.List(c, list, total, func(row ui.ListRow) {
		part, index := 0, row.Index
		if index >= first {
			part, index = 1, index-first
		}
		row.Element.PadX(semanticRowPad).Items(ui.Start).
			HitWith(row.ID, "", gfx.HitOptions{Role: gfx.RoleGroup, SkipFocus: true})
		if row.Index == 0 {
			row.Element.PadTop(completionPreviewPadY)
		}
		if row.Index == total-1 {
			row.Element.PadBottom(completionPreviewPadY)
		}
		start := completionBlockStart(text[part], index)
		end := completionBlockStart(text[part], index+1)
		value := text[part][start:end]
		ui.Wrap(row.C, value).Grow(1).MinWidth(0).FontSize(completionLabelSize).LineHeight(completionPreviewLineHeight)
	}).FillWidth().Height(height).Scrollbars().ScrollbarLabels(vertical, horizontal)
}

func completionBlockCount(value string) int {
	return (len(value) + completionTextBlockBytes - 1) / completionTextBlockBytes
}

// Block offsets are calculated independently so the scrollbar can jump without
// reading preceding text. Prefer a nearby whitespace break, then a grapheme
// boundary in the same bounded window.
func completionBlockStart(value string, index int) int {
	if index == 0 {
		return 0
	}
	offset := index * completionTextBlockBytes
	if offset >= len(value) {
		return len(value)
	}
	const lookBehind = 64
	start := offset - lookBehind
	if at := strings.LastIndexAny(value[start:offset], " \t\n"); at >= 0 {
		return start + at + 1
	}
	for !utf8.RuneStart(value[start]) {
		start++
	}
	return start + gfx.GraphemeStart(value[start:min(offset+utf8.UTFMax, len(value))], offset-start)
}

// renameDialog is the thin view over renameState: it shows the name field and
// reports confirm or cancel to the rename logic.
func (a *App) renameDialog(c ui.C) {
	state := &a.semantics.rename
	language := a.language()
	label := i18n.Shared(language, "desktop.semantics.renameName")
	submitted, cancelled, confirmed := false, false, false
	closed := ui.Modal(c, &state.open, i18n.Shared(language, "desktop.semantics.renameTitle"),
		ui.ModalSpec{Description: i18n.Shared(language, "desktop.semantics.renameDescription"), Width: 420}, func() {
			submitted = ui.TextField(c, &state.name, label, label).FillWidth().Disabled(state.busy).Submitted()
		}, func() {
			cancelled = ui.Button(c, i18n.Shared(language, "desktop.semantics.renameCancel")).Outline().Clicked()
			confirmed = ui.Button(c, i18n.Shared(language, "desktop.semantics.renameButton")).Disabled(!a.renameReady()).Clicked()
		})
	switch {
	case closed || cancelled:
		state.open = true
		c.After(a.cancelPluginRename)
	case confirmed || submitted:
		c.After(a.confirmPluginRename)
	}
}
