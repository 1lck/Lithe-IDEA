package logwindow

// The sheet that exports a diagnostic bundle. The macOS client's DiagnosticsExportSheet is
// the reference: the same sections, words, sizes and colors, in the same order.

import (
	"math"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

var (
	exportScope       = tree.Sub(page, tree.Name("export"))
	exportBackdropID  = tree.ID(exportScope, "backdrop")
	exportRangeScope  = tree.Sub(exportScope, tree.Name("range"))
	exportAllID       = tree.ID(exportScope, "all-channels")
	exportFilterID    = tree.ID(exportScope, "current-filter")
	exportEnvID       = tree.ID(exportScope, "environment")
	exportContentsID  = tree.ID(exportScope, "contents")
	exportRetryID     = tree.ID(exportScope, "retry")
	exportRevealID    = tree.ID(exportScope, "reveal")
	exportCancelID    = tree.ID(exportScope, "cancel")
	exportConfirmID   = tree.ID(exportScope, "confirm")
	exportRangeChoice = []exportRange{exportCurrent, exportRecent, exportDay}
)

const (
	// exportSheetWidth is the sheet's width, its padding exportPadX and exportPadY.
	exportSheetWidth = 560
	exportPadX       = 18
	exportPadY       = 16
	// exportGap is the space between the sheet's rows.
	exportGap = 8
	// exportFont is the size of the sheet's text, exportTitleFont its title's, exportSubtitleFont
	// the subtitle's and exportSectionFont a section's heading's.
	exportFont         = 13
	exportTitleFont    = 15
	exportSubtitleFont = 12
	exportSectionFont  = 11
	// exportContentsFont is the size of the list of files, exportContentsHeight the list's
	// height.
	exportContentsFont   = 11.5
	exportContentsHeight = 150
	// exportRadioIndent and exportCheckIndent are where the hint under a radio button or the
	// checkbox starts: past the control and the space after it.
	exportRadioIndent = 22
	exportCheckIndent = 20
	// exportButtonHeight is the height of the buttons in the sheet's rows.
	exportButtonHeight = 22
)

// exportLine is the height of a line of text at size: the system font's own line height, as
// SwiftUI lays a Text out, rather than Viva's looser default.
func exportLine(size float32) float32 {
	return float32(math.Ceil(float64(size) * 1.22))
}

// openExport opens the export sheet, closing any open menu.
func (w *window) openExport() {
	w.closeMenu()
	w.model.presentExport()
}

// drawExportSheet declares the export sheet while it is presented: a backdrop that keeps the
// window behind it from taking presses, as a macOS sheet does, and the sheet under the title
// bar, centered.
func (w *window) drawExportSheet(f *flex.Frame, bounds ui.Rect) {
	e := &w.model.export
	if !e.presented {
		return
	}
	logs := &w.text.Logs
	m := &logs.ExportDialog
	busy := w.model.exportBusy()

	f.Popup().At(0, 0).Fill().HitWith(exportBackdropID, "", ui.HitOptions{SkipFocus: true})
	x := max(0, (bounds.Width-exportSheetWidth)/2)
	f.Popup().At(x, titleHeight).Width(exportSheetWidth).
		Background(w.pal.menu).Border(1, w.pal.bd).Radius(10).Shadow(ui.ShadowMD).
		Children(func() {
			f.Column().Grow(1).Items(flex.Start).PadX(exportPadX).PadY(exportPadY).Gap(exportGap).Children(func() {
				w.sheetText(f, logs.ExportLabel, exportTitleFont, w.pal.tx).Weight(ui.WeightSemibold)
				w.sheetWrap(f, m.Subtitle, exportSubtitleFont, w.pal.tx2, 0)

				w.exportSection(f, m.Range)
				f.Column().FillWidth().Items(flex.Start).Gap(7).Children(func() {
					titles := []string{m.CurrentSession, m.RecentSessions, m.Last24Hours}
					for index, scope := range exportRangeChoice {
						f.Column().FillWidth().Items(flex.Start).Gap(2).Children(func() {
							if w.exportRadio(f, exportRangeScope.At(index), titles[index], e.scope == scope, busy) {
								w.model.setExportRange(scope)
							}
							if scope == exportRecent {
								w.sheetWrap(f, m.RecentSessionsHint, exportFont, w.pal.tx3, exportRadioIndent)
							}
						})
					}
				})

				w.exportSection(f, logs.ExportDialog.Channels)
				if w.exportRadio(f, exportAllID, logs.AllChannels, !e.currentFilterOnly, busy) {
					w.model.setExportFilterOnly(false)
				}
				f.Column().FillWidth().Items(flex.Start).Gap(2).Children(func() {
					if w.exportRadio(f, exportFilterID, m.CurrentFilter, e.currentFilterOnly, busy) {
						w.model.setExportFilterOnly(true)
					}
					channels := logs.AllChannels
					if len(e.filter.ChannelPrefixes) > 0 {
						channels = strings.Join(e.filter.ChannelPrefixes, ", ")
					}
					w.sheetWrap(f, channels, exportFont, w.pal.tx3, exportRadioIndent)
				})

				w.exportSection(f, m.Privacy)
				f.Row().FillWidth().Items(flex.Start).Gap(5).PadX(10).PadY(6).
					Background(w.pal.bg2).Radius(6).Border(1, w.pal.line).Children(func() {
					// The lock sits on the first line, as SwiftUI's first-text-baseline
					// alignment puts it.
					line := exportLine(exportFont)
					f.Icon(lockIcon).Size(9, 11).Shrink(0).Color(w.pal.grn).MarginSides((line-11)/2, 0, 0, 0)
					f.Wrap(m.RedactionNote).Grow(1).Shrink(1).MinWidth(0).
						FontSize(exportFont).LineHeight(line).Color(w.pal.grn)
				})
				if w.exportCheckbox(f, exportEnvID, m.Environment, e.includeEnvironment, busy) {
					w.model.setExportEnvironment(!e.includeEnvironment)
				}
				w.sheetWrap(f, m.EnvironmentHint(sysinfo.Name()), exportFont, w.pal.tx3, exportCheckIndent)

				w.exportSection(f, m.Contents)
				w.drawExportContents(f)
				w.drawExportStatus(f)
				w.drawExportFooter(f)
			})
		})
}

// drawExportContents is the list of the staged bundle's files with their sizes, and the
// manifest last. It is empty until the evidence is staged.
func (w *window) drawExportContents(f *flex.Frame) {
	e := &w.model.export
	area := f.ScrollArea(exportContentsID).FillWidth().Height(exportContentsHeight).Shrink(0).
		PadX(10).PadY(6).Gap(4).Background(w.pal.bg2).Radius(6).Border(1, w.pal.line)
	if e.manifest == nil {
		area.Children(func() {})
		return
	}
	line := exportLine(exportContentsFont)
	row := func(path, trailing string) {
		f.Row().FillWidth().Shrink(0).Gap(8).Items(flex.Center).Children(func() {
			w.mono(f, path, exportContentsFont, w.pal.tx).LineHeight(line).Shrink(1).MinWidth(0).Ellipsis()
			f.Spacer()
			w.mono(f, trailing, exportContentsFont, w.pal.tx3).LineHeight(line).Shrink(0)
		})
	}
	area.Children(func() {
		for _, file := range e.manifest.Files {
			row(file.RelativePath, formatBytes(int64(min(file.SizeBytes, math.MaxInt64))))
		}
		row("manifest.json", "redaction: "+e.manifest.Redaction)
	})
}

// drawExportStatus is the row under the contents that says what the export is doing: staging,
// packing, failed with a retry, or saved with a way to the file.
func (w *window) drawExportStatus(f *flex.Frame) {
	e := &w.model.export
	logs := &w.text.Logs
	m := &logs.ExportDialog
	switch e.phase {
	case exportPreparing:
		f.Spinner()
	case exportExporting:
		f.Row().Gap(8).Items(flex.Center).Children(func() {
			f.Spinner()
			w.sheetText(f, m.Packing, exportFont, w.pal.tx)
		})
	case exportFailed:
		message := m.ExportFailed
		if e.failedStage == stagePlanning {
			message = m.PrepareFailed
		}
		f.Row().FillWidth().Gap(8).Items(flex.Center).Children(func() {
			w.sheetText(f, message, exportFont, w.pal.red).Shrink(1).MinWidth(0).Ellipsis()
			retry := w.button(f, exportRetryID, "", logs.Retry, buttonOptions{proportional: true, height: exportButtonHeight})
			if retry.Clicked() {
				w.model.replanExport()
			}
		})
	case exportCompleted:
		w.sheetWrap(f, m.SavedTo(abbreviateHome(e.destination)), exportFont, w.pal.tx, 0)
		if w.button(f, exportRevealID, "", logs.RevealInFinder, buttonOptions{proportional: true}).Clicked() {
			w.model.revealExport()
		}
	}
}

// drawExportFooter is the estimate of the bundle's size and file count, and the sheet's
// buttons: Cancel, and Export, which is enabled once the evidence is staged.
func (w *window) drawExportFooter(f *flex.Frame) {
	e := &w.model.export
	logs := &w.text.Logs
	m := &logs.ExportDialog
	f.Row().FillWidth().Gap(8).Items(flex.Center).Children(func() {
		size := formatBytes(int64(min(e.estimatedBytes, math.MaxInt64)))
		w.sheetText(f, m.Size(size, e.fileCount()), exportFont, w.pal.tx3).Shrink(1).MinWidth(0).Ellipsis()
		f.Spacer()
		if w.button(f, exportCancelID, "", logs.Cancel, buttonOptions{proportional: true}).Clicked() {
			w.model.dismissExport()
		}
		ready := e.phase == exportAwaiting
		confirm := w.button(f, exportConfirmID, "", m.Export, buttonOptions{proportional: true, active: true, disabled: !ready})
		if ready && confirm.Clicked() {
			w.model.confirmExport()
		}
	})
}

// exportKey handles a key while the export sheet is presented: Escape cancels and Return
// exports once the evidence is staged, as the sheet's cancel and default actions do. Every
// other key goes to the sheet's own controls and none to the window behind it.
func (w *window) exportKey(event ui.KeyEvent) ui.EventResult {
	switch event.Key {
	case ui.KeyEscape:
		w.model.dismissExport()
	case ui.KeyEnter:
		if w.model.export.phase != exportAwaiting {
			return ui.EventResult{Handled: true}
		}
		w.model.confirmExport()
	default:
		return ui.EventResult{}
	}
	return ui.EventResult{Handled: true, Repaint: true}
}

// exportSection is the heading of one of the sheet's sections.
func (w *window) exportSection(f *flex.Frame, title string) {
	w.sheetText(f, title, exportSectionFont, w.pal.tx3).MarginSides(2, 0, 0, 0)
}

// sheetText declares a line of the sheet's text at size.
func (w *window) sheetText(f *flex.Frame, s string, size float32, color ui.Color) flex.Box {
	return f.Text(s).FontSize(size).LineHeight(exportLine(size)).Color(color)
}

// sheetWrap declares a paragraph of the sheet's text at size that takes the sheet's width,
// indent pixels in from its leading edge.
func (w *window) sheetWrap(f *flex.Frame, s string, size float32, color ui.Color, indent float32) {
	f.Row().FillWidth().PadSides(0, 0, 0, indent).Children(func() {
		f.Wrap(s).Grow(1).Shrink(1).MinWidth(0).FontSize(size).LineHeight(exportLine(size)).Color(color)
	})
}

// exportRadio declares one of the sheet's radio buttons, a hollow ring that turns the accent
// color and holds a dot when it is selected, and reports whether it was chosen.
func (w *window) exportRadio(f *flex.Frame, id ui.ID, title string, selected, disabled bool) bool {
	ring := w.pal.tx3
	if selected {
		ring = w.pal.blu
	}
	row := f.Row().Gap(7).Items(flex.Center).
		HitWith(id, title, ui.HitOptions{Role: ui.RoleRadio, Checked: selected, Disabled: disabled})
	if disabled {
		row = row.Opacity(0.45)
	}
	row.Children(func() {
		f.Row().Size(15, 15).Shrink(0).Center().Children(func() {
			// A border on a box without a background paints the box solid, so the ring
			// has the sheet's own color inside.
			f.Row().Size(13, 13).Radius(6.5).Background(w.pal.menu).Border(1.2, ring).Center().Children(func() {
				if selected {
					f.Row().Size(7, 7).Radius(3.5).Background(ring)
				}
			})
		})
		w.sheetText(f, title, exportFont, w.pal.tx)
	})
	return !disabled && row.Clicked()
}

// exportCheckbox declares the sheet's checkbox, filled with the accent color and checked when
// it is on, and reports whether it was pressed.
func (w *window) exportCheckbox(f *flex.Frame, id ui.ID, title string, checked, disabled bool) bool {
	row := f.Row().Gap(6).Items(flex.Center).
		HitWith(id, title, ui.HitOptions{Role: ui.RoleCheckbox, Checked: checked, Disabled: disabled})
	if disabled {
		row = row.Opacity(0.45)
	}
	row.Children(func() {
		box := f.Row().Size(14, 14).Shrink(0).Radius(3.5).Center()
		if checked {
			box = box.Background(w.pal.blu)
		} else {
			box = box.Background(w.pal.bg).Border(1, w.pal.bd)
		}
		box.Children(func() {
			if checked {
				f.Icon(checkIcon).Size(10, 10).Color(w.pal.white)
			}
		})
		w.sheetText(f, title, exportFont, w.pal.tx)
	})
	return !disabled && row.Clicked()
}

// lockIcon is a closed padlock, filled, the shape of the SF Symbol lock.fill the macOS sheet
// shows beside its privacy note. It is one outline, the body and the outside of the shackle,
// with the opening of the shackle wound the other way as a hole: a separate shackle contour
// that only touches the body is dropped by the nonzero fill.
var lockIcon = ui.Icon{ViewBox: 16, Commands: []ui.PathCommand{
	// The outline, clockwise: up the shackle's outside, over it and down the body.
	ui.MoveTo(3.5, 7), ui.LineTo(4, 7), ui.LineTo(4, 5),
	ui.CubicTo(4, 2.79, 5.79, 1, 8, 1), ui.CubicTo(10.21, 1, 12, 2.79, 12, 5),
	ui.LineTo(12, 7), ui.LineTo(12.5, 7), ui.CubicTo(13.33, 7, 14, 7.67, 14, 8.5), ui.LineTo(14, 13.5),
	ui.CubicTo(14, 14.33, 13.33, 15, 12.5, 15), ui.LineTo(3.5, 15), ui.CubicTo(2.67, 15, 2, 14.33, 2, 13.5),
	ui.LineTo(2, 8.5), ui.CubicTo(2, 7.67, 2.67, 7, 3.5, 7), ui.ClosePath(),
	// The opening of the shackle, counterclockwise.
	ui.MoveTo(5.8, 7), ui.LineTo(10.2, 7), ui.LineTo(10.2, 5),
	ui.CubicTo(10.2, 3.78, 9.22, 2.8, 8, 2.8), ui.CubicTo(6.78, 2.8, 5.8, 3.78, 5.8, 5), ui.ClosePath(),
}}

// checkIcon is the check mark of the sheet's checkbox.
var checkIcon = ui.Icon{ViewBox: 16, Stroke: 2.2, Cap: ui.CapRound, Join: ui.JoinRound, Commands: []ui.PathCommand{
	ui.MoveTo(3.5, 8.5), ui.LineTo(6.5, 11.5), ui.LineTo(12.5, 4.5),
}}
