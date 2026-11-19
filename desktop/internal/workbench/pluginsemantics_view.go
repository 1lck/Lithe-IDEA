package workbench

import (
	"math"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	semanticRowPad              = 8
	semanticRowGap              = 8
	semanticListGap             = 1
	completionMinWidth          = 360
	completionMaxWidth          = 640
	completionLabelSize         = 12
	completionDetailSize        = 11
	completionPreviewLines      = 3
	completionPreviewLineHeight = 18
	completionPreviewPadY       = 4
	completionPreviewMaxHeight  = completionPreviewLines*completionPreviewLineHeight + 2*completionPreviewPadY
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
			Background(a.theme.Popover).Border(1, a.theme.Border).
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
	anchor, ok := d.caretView().CaretRect()
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
	nameWidth, detailWidth float32
	detail                 string
	multiline              bool
}

func (a *App) completionPopup(c ui.C) gfx.Rect {
	state := &a.semantics.completion
	p, d := a.currentSemanticDocument(state.documentID)
	if d == nil || p != a.project || d.view.Revision() != state.revision {
		a.closeSemanticCompletion()
		return gfx.Rect{}
	}
	anchor, ok := d.caretView().CaretRect()
	if !ok {
		a.closeSemanticCompletion()
		return gfx.Rect{}
	}

	bounds := c.Bounds().Inset(gfx.All(4))
	const rowInsets = 2 * (semanticPopupPad + semanticRowPad)
	if bounds.Width <= rowInsets || bounds.Height < semanticRowHeight+2*semanticPopupPad {
		return gfx.Rect{}
	}
	first, last := semanticWindow(state.selected, len(state.items))
	if first == last {
		return gfx.Rect{}
	}
	// Reserve a footer's worth of space in short windows so the selected row and its
	// details can both be shown. Normal windows retain the full candidate window.
	previewHeight := min(float32(completionPreviewMaxHeight), max(0, bounds.Height-semanticRowHeight-2*semanticPopupPad-semanticListGap))
	maxRows := max(1, int((bounds.Height-previewHeight-2*semanticPopupPad)/(semanticRowHeight+semanticListGap)))
	if last-first > maxRows {
		first = min(max(first, state.selected-maxRows+1), last-maxRows)
		last = first + maxRows
	}

	canvas := c.Canvas()
	var rows [visibleSemanticRows]completionRowLayout
	desiredWidth := float32(completionMinWidth)
	for i, item := range state.items[first:last] {
		detail, _, multiline := strings.Cut(item.Detail, "\n")
		nameWidth := float32(math.Ceil(float64(canvas.TextWidth(item.Label, completionLabelSize))))
		detailWidth := float32(math.Ceil(float64(canvas.TextWidth(detail, completionDetailSize))))
		rows[i] = completionRowLayout{nameWidth: nameWidth, detailWidth: detailWidth, detail: detail, multiline: multiline}
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
	var previewLabel, previewDetail string
	if selectedRow.nameWidth > textWidth {
		previewLabel, previewDetail = selected.Label, selected.Detail
	} else if selectedRow.multiline || selectedRow.detailWidth > 0 && selectedRow.nameWidth+semanticRowGap+selectedRow.detailWidth > textWidth {
		previewDetail = selected.Detail
	}
	preview := [2]string{previewLabel, previewDetail}

	height := 2*semanticPopupPad + float32(last-first)*(semanticRowHeight+semanticListGap) - semanticListGap
	showPreview := (previewLabel != "" || previewDetail != "") && previewHeight >= completionPreviewLineHeight+2*completionPreviewPadY
	if showPreview {
		var scratch [completionPreviewLines]string
		style := gfx.TextStyle{Size: completionLabelSize}
		var lineCount int
		for _, part := range preview {
			lines := canvas.WrapLinesStyle(scratch[:0], part, style, textWidth, len(scratch)-lineCount, nil)
			lineCount += len(lines)
		}
		previewHeight = min(previewHeight, float32(lineCount)*completionPreviewLineHeight+2*completionPreviewPadY)
		height += previewHeight + semanticListGap
	}
	x := min(max(anchor.X, bounds.X), bounds.Right()-width)
	y := anchor.Bottom() + 2
	if y+height > bounds.Bottom() && anchor.Y-2-bounds.Y > bounds.Bottom()-y {
		y = anchor.Y - 2 - height
	}
	y = min(max(y, bounds.Y), bounds.Bottom()-height)

	chosen := -1
	language := a.language()
	a.semanticPopup(c, x, y, width, height, i18n.Shared(language, "desktop.semantics.completion"), semanticPopupPad, func() {
		ui.Column(c).FillWidth().Gap(semanticListGap).Children(func() {
			for i, item := range state.items[first:last] {
				index := first + i
				row := rows[i]
				if a.semanticRow(c, index, item.Label, index == state.selected, func(rc ui.C) {
					nameWidth := min(row.nameWidth, textWidth)
					ui.Text(rc, item.Label).FontSize(completionLabelSize).Width(nameWidth).Shrink(0).Ellipsis()
					if row.detail != "" && textWidth-nameWidth-semanticRowGap >= min(row.detailWidth, completionDetailSize*3) {
						ui.Text(rc, row.detail).FontSize(completionDetailSize).Color(a.colors.Subtle).
							Grow(1).Shrink(1).MinWidth(0).Ellipsis()
					}
				}) {
					chosen = index
				}
			}
		})
		if showPreview {
			pc := c.Part("completion-preview").KeyInt(state.selected)
			ui.Divider(pc).Height(semanticListGap)
			ui.Scroll(pc).FillWidth().Height(previewHeight).Scrollbars().
				ScrollbarLabels(i18n.Shared(language, "desktop.editor.verticalScrollbar"), i18n.Shared(language, "desktop.editor.horizontalScrollbar")).
				Children(func() {
					ui.Column(pc).FillWidth().PadX(semanticRowPad).PadY(completionPreviewPadY).Children(func() {
						for _, part := range preview {
							if part != "" {
								ui.Wrap(pc, part).FillWidth().FontSize(completionLabelSize).LineHeight(completionPreviewLineHeight)
							}
						}
					})
				})
		}
	})
	if chosen >= 0 {
		c.After(func() { a.acceptPluginCompletion(chosen) })
	}
	return gfx.Rect{X: x, Y: y, Width: width, Height: height}
}

// renameDialog is the thin view over renameState: it shows the name field and
// reports confirm or cancel to the rename logic.
func (a *App) renameDialog(c ui.C) {
	state := &a.semantics.rename
	language := a.language()
	label := i18n.Shared(language, "desktop.semantics.renameName")
	submitted, cancelled, confirmed := false, false, false
	closed := ui.ModalWith(c, &state.open, i18n.Shared(language, "desktop.semantics.renameTitle"),
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
