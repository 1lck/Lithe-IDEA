// Package uistyle holds the few shared metrics the client's windows paint with, so one
// number describes the same surface everywhere instead of each window choosing its own.
package uistyle

import (
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Bars is the geometry every scrollbar of the client draws with: IDEA's eleven point track
// with a five point thumb, a one point gap from the track's edge, and a twenty point least
// thumb. A window hands it to ui.PageConfig.BarStyle, so its lists, trees and areas agree
// without each one asking for it.
var Bars = components.ScrollBarStyle{Size: 11, HoverSize: 5, Inset: 1, MinThumb: 20}

// Tooltip is the hover tip every window of the client draws, set on each window's theme so
// the workbench, the settings window and the log window show the same tip. Both looks give
// it a dark body with light text and no border: over a white panel a dark tip reads as a
// layer above it without an outline, and IDEA's light look draws its tooltips the same way
// (ToolTip.background #27282E under white text, the border in the body's color). The dark
// look keeps the gray its tips have had. Twelve point text, a four point corner and Viva's
// six point vertical padding keep the tip compact.
func Tooltip(dark bool) gfx.TooltipStyle {
	style := gfx.TooltipStyle{
		Radius: 4, PadX: 12, PadY: 6, FontSize: 12,
		Background: gfx.RGB24(0x27282E), Text: gfx.RGB24(0xFFFFFF),
	}
	if dark {
		style.Background, style.Text = gfx.RGB24(0x33353B), gfx.RGB24(0xD1D3D9)
	}
	return style
}

// SettingsRow is the vertical spacing for an individual settings form entry.
func SettingsRow(c ui.C) ui.Box {
	return ui.Column(c).FillWidth().Shrink(0).Gap(4).PadY(6)
}

// SettingsLine wraps the title and its control together on narrow pages.
func SettingsLine(c ui.C) ui.Box {
	return ui.Flow(c).FillWidth().MinHeight(30).Items(ui.Center).Gap(8).LineGap(6)
}

// SettingsTitle aligns labels and their host-provided information buttons.
func SettingsTitle(c ui.C) ui.Box {
	return ui.Row(c.Part("title")).Basis(0).Grow(2).Shrink(1).MinWidth(120).Items(ui.Center).Gap(8)
}
