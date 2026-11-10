package logwindow

// The sheet that exports a diagnostic bundle. The macOS client's DiagnosticsExportSheet is
// the reference: the same sections, words, sizes and colors, in the same order.

import (
	"math"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var exportRangeChoice = []exportRange{exportCurrent, exportRecent, exportDay}

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

// exportSheet declares the export sheet while it is presented: a modal over the window, as a
// macOS sheet is, whose subtitle is the dialog's description. Escape, a press on the dim and
// the close button cancel it.
func (w *window) exportSheet(c ui.C) {
	e := &w.model.export
	if !e.presented {
		return
	}
	logs := &w.text.Logs
	m := &logs.ExportDialog
	open := true
	ui.ModalWith(c, &open, logs.ExportLabel, ui.ModalSpec{Description: m.Subtitle, Width: exportSheetWidth}, func() {
		ui.Column(c).FillWidth().Items(ui.Start).Gap(exportGap).Children(func() {
			w.exportBody(c)
		})
	}, func() {
		size := formatBytes(int64(min(e.estimatedBytes, math.MaxInt64)))
		w.sheetText(c, m.Size(size, e.fileCount()), exportFont, w.pal.tx3).Shrink(1).MinWidth(0).Ellipsis()
		ui.Spacer(c)
		if ui.Button(c, logs.Cancel).Outline().Clicked() {
			open = false
		}
		ready := e.phase == exportAwaiting
		if ui.Button(c, m.Export).Disabled(!ready).Clicked() && ready {
			w.model.confirmExport()
		}
	})
	if !open {
		w.model.dismissExport()
	}
}

// exportBody is what the sheet asks and shows: the range of sessions, the channels, the
// privacy note, the environment, the files the bundle will hold and what the export is doing.
func (w *window) exportBody(c ui.C) {
	e := &w.model.export
	logs := &w.text.Logs
	m := &logs.ExportDialog
	busy := w.model.exportBusy()

	w.exportSection(c, m.Range)
	ui.Column(c).FillWidth().Items(ui.Start).Gap(7).Children(func() {
		titles := []string{m.CurrentSession, m.RecentSessions, m.Last24Hours}
		for index, scope := range exportRangeChoice {
			ui.Column(c.KeyInt(index)).FillWidth().Items(ui.Start).Gap(2).Children(func() {
				if w.sheetRadio(c, "range", titles[index], e.scope == scope, busy) {
					w.model.setExportRange(scope)
				}
				if scope == exportRecent {
					w.sheetWrap(c, m.RecentSessionsHint, exportFont, w.pal.tx3, exportRadioIndent)
				}
			})
		}
	})

	w.exportSection(c, m.Channels)
	if w.sheetRadio(c, "all-channels", logs.AllChannels, !e.currentFilterOnly, busy) {
		w.model.setExportFilterOnly(false)
	}
	ui.Column(c).FillWidth().Items(ui.Start).Gap(2).Children(func() {
		if w.sheetRadio(c, "current-filter", m.CurrentFilter, e.currentFilterOnly, busy) {
			w.model.setExportFilterOnly(true)
		}
		channels := logs.AllChannels
		if len(e.filter.ChannelPrefixes) > 0 {
			channels = strings.Join(e.filter.ChannelPrefixes, ", ")
		}
		w.sheetWrap(c, channels, exportFont, w.pal.tx3, exportRadioIndent)
	})

	w.exportSection(c, m.Privacy)
	ui.Row(c).FillWidth().Items(ui.Start).Gap(5).PadX(10).PadY(6).
		Background(w.pal.bg2).Radius(6).Border(1, w.pal.line).Children(func() {
		// The lock sits on the first line, as SwiftUI's first-text-baseline alignment puts it.
		line := exportLine(exportFont)
		ui.Icon(c, lockIcon).Size(9, 11).Shrink(0).Color(w.pal.grn).MarginSides((line-11)/2, 0, 0, 0)
		ui.Wrap(c, m.RedactionNote).Grow(1).Shrink(1).MinWidth(0).
			FontSize(exportFont).LineHeight(line).Color(w.pal.grn)
	})
	if w.sheetCheckbox(c, "environment", m.Environment, e.includeEnvironment, busy) {
		w.model.setExportEnvironment(!e.includeEnvironment)
	}
	w.sheetWrap(c, m.EnvironmentHint(sysinfo.Name()), exportFont, w.pal.tx3, exportCheckIndent)

	w.exportSection(c, m.Contents)
	w.exportContents(c)
	w.exportStatus(c)
}

// exportContents is the list of the staged bundle's files with their sizes, and the manifest
// last. It is empty until the evidence is staged.
func (w *window) exportContents(c ui.C) {
	e := &w.model.export
	area := ui.Scroll(c).FillWidth().Height(exportContentsHeight).Shrink(0).
		PadX(10).PadY(6).Gap(4).Background(w.pal.bg2).Radius(6).Border(1, w.pal.line)
	if e.manifest == nil {
		area.Children(func() {})
		return
	}
	line := exportLine(exportContentsFont)
	row := func(path, trailing string) {
		ui.Row(c).FillWidth().Shrink(0).Gap(8).Items(ui.Center).Children(func() {
			w.mono(c, path, exportContentsFont, w.pal.tx).LineHeight(line).Shrink(1).MinWidth(0).Ellipsis()
			ui.Spacer(c)
			w.mono(c, trailing, exportContentsFont, w.pal.tx3).LineHeight(line).Shrink(0)
		})
	}
	area.Children(func() {
		for _, file := range e.manifest.Files {
			row(file.RelativePath, formatBytes(int64(min(file.SizeBytes, math.MaxInt64))))
		}
		row("manifest.json", "redaction: "+e.manifest.Redaction)
	})
}

// exportStatus is the row under the contents that says what the export is doing: staging,
// packing, failed with a retry, or saved with a way to the file.
func (w *window) exportStatus(c ui.C) {
	e := &w.model.export
	logs := &w.text.Logs
	m := &logs.ExportDialog
	switch e.phase {
	case exportPreparing:
		ui.Spinner(c)
	case exportExporting:
		ui.Row(c).Gap(8).Items(ui.Center).Children(func() {
			ui.Spinner(c)
			w.sheetText(c, m.Packing, exportFont, w.pal.tx)
		})
	case exportFailed:
		message := m.ExportFailed
		if e.failedStage == stagePlanning {
			message = m.PrepareFailed
		}
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			w.sheetText(c, message, exportFont, w.pal.red).Shrink(1).MinWidth(0).Ellipsis()
			if ui.Button(c, logs.Retry).Outline().Small().Clicked() {
				w.model.replanExport()
			}
		})
	case exportCompleted:
		w.sheetWrap(c, m.SavedTo(abbreviateHome(e.destination)), exportFont, w.pal.tx, 0)
		if ui.Button(c, logs.RevealInFinder).Outline().Small().Clicked() {
			w.model.revealExport()
		}
	}
}

// exportSection is the heading of one of the sheet's sections.
func (w *window) exportSection(c ui.C, title string) {
	w.sheetText(c, title, exportSectionFont, w.pal.tx3).MarginSides(2, 0, 0, 0)
}

// sheetText declares a line of the sheet's text at size.
func (w *window) sheetText(c ui.C, s string, size float32, color ui.Color) ui.Box {
	return ui.Text(c, s).FontSize(size).LineHeight(exportLine(size)).Color(color)
}

// sheetWrap declares a paragraph of the sheet's text at size that takes the sheet's width,
// indent pixels in from its leading edge.
func (w *window) sheetWrap(c ui.C, s string, size float32, color ui.Color, indent float32) {
	ui.Row(c).FillWidth().PadSides(0, 0, 0, indent).Children(func() {
		ui.Wrap(c, s).Grow(1).Shrink(1).MinWidth(0).FontSize(size).LineHeight(exportLine(size)).Color(color)
	})
}

// sheetRadio declares one of the sheet's radio buttons, a hollow ring that turns the accent
// color and holds a dot when it is selected, and reports whether it was chosen. name tells it
// from the buttons beside it.
func (w *window) sheetRadio(c ui.C, name, title string, selected, disabled bool) bool {
	ring := w.pal.tx3
	if selected {
		ring = w.pal.blu
	}
	look := func() {
		ui.Row(c).Size(15, 15).Shrink(0).Center().Children(func() {
			// A border on a box without a background paints the box solid, so the ring has
			// the sheet's own color inside.
			ui.Row(c).Size(13, 13).Radius(6.5).Background(w.pal.menu).Border(1.2, ring).Center().Children(func() {
				if selected {
					ui.Row(c).Size(7, 7).Radius(3.5).Background(ring)
				}
			})
		})
		w.sheetText(c, title, exportFont, w.pal.tx)
	}
	if disabled {
		ui.Row(c.Part(name)).Gap(7).Items(ui.Center).Opacity(0.45).Children(look)
		return false
	}
	value := 0
	if selected {
		value = 1
	}
	return ui.RadioBase(c.Part(name), &value, 1, title).Gap(7).Items(ui.Center).Children(look).Changed()
}

// sheetCheckbox declares the sheet's checkbox, filled with the accent color and checked when
// it is on, and reports whether it was pressed.
func (w *window) sheetCheckbox(c ui.C, name, title string, checked, disabled bool) bool {
	look := func() {
		box := ui.Row(c).Size(14, 14).Shrink(0).Radius(3.5).Center()
		if checked {
			box = box.Background(w.pal.blu)
		} else {
			box = box.Background(w.pal.bg).Border(1, w.pal.bd)
		}
		box.Children(func() {
			if checked {
				ui.Icon(c, checkIcon).Size(10, 10).Color(w.pal.white)
			}
		})
		w.sheetText(c, title, exportFont, w.pal.tx)
	}
	if disabled {
		ui.Row(c.Part(name)).Gap(6).Items(ui.Center).Opacity(0.45).Children(look)
		return false
	}
	value := checked
	return ui.CheckboxBase(c.Part(name), &value, title).Gap(6).Items(ui.Center).Children(look).Changed()
}

// lockIcon is a closed padlock, filled, the shape of the SF Symbol lock.fill the macOS sheet
// shows beside its privacy note. It is one outline, the body and the outside of the shackle,
// with the opening of the shackle wound the other way as a hole: a separate shackle contour
// that only touches the body is dropped by the nonzero fill.
var lockIcon = gfx.Icon{ViewBox: 16, Commands: []gfx.PathCommand{
	// The outline, clockwise: up the shackle's outside, over it and down the body.
	gfx.MoveTo(3.5, 7), gfx.LineTo(4, 7), gfx.LineTo(4, 5),
	gfx.CubicTo(4, 2.79, 5.79, 1, 8, 1), gfx.CubicTo(10.21, 1, 12, 2.79, 12, 5),
	gfx.LineTo(12, 7), gfx.LineTo(12.5, 7), gfx.CubicTo(13.33, 7, 14, 7.67, 14, 8.5), gfx.LineTo(14, 13.5),
	gfx.CubicTo(14, 14.33, 13.33, 15, 12.5, 15), gfx.LineTo(3.5, 15), gfx.CubicTo(2.67, 15, 2, 14.33, 2, 13.5),
	gfx.LineTo(2, 8.5), gfx.CubicTo(2, 7.67, 2.67, 7, 3.5, 7), gfx.ClosePath(),
	// The opening of the shackle, counterclockwise.
	gfx.MoveTo(5.8, 7), gfx.LineTo(10.2, 7), gfx.LineTo(10.2, 5),
	gfx.CubicTo(10.2, 3.78, 9.22, 2.8, 8, 2.8), gfx.CubicTo(6.78, 2.8, 5.8, 3.78, 5.8, 5), gfx.ClosePath(),
}}

// checkIcon is the check mark of the sheet's checkbox.
var checkIcon = gfx.Icon{ViewBox: 16, Stroke: 2.2, Cap: gfx.CapRound, Join: gfx.JoinRound, Commands: []gfx.PathCommand{
	gfx.MoveTo(3.5, 8.5), gfx.LineTo(6.5, 11.5), gfx.LineTo(12.5, 4.5),
}}
