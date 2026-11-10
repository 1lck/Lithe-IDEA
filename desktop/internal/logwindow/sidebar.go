package logwindow

import (
	"cmp"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The metrics of the sidebar, after the macOS client's channel list and diagnostics card.
const (
	// sidebarRowHeight is the height of a row of the list.
	sidebarRowHeight = 24
	// sidebarInset is the distance of a row's highlight, and of the text in it, from the
	// edges of the list.
	sidebarInset = 12
	// sidebarRadius is the corner radius of a row's highlight.
	sidebarRadius = 4
	// sidebarCountWidth is the width of the count at the trailing end of a row.
	sidebarCountWidth = 36
	// sidebarCardHeight is the height of the diagnostics card: 50 for its lines and 8 above
	// and below them.
	sidebarCardHeight = 66
	// sidebarCardRadius is the corner radius of the diagnostics card.
	sidebarCardRadius = 6
)

// sidebarRootOrder is the order of the channels' first path components in the list. A
// component that is not in it follows these, in alphabetical order.
var sidebarRootOrder = []string{"app", "lsp", "vcs", "plugins"}

// sidebarRow is one row of the channel list: the "all channels" row, the heading of a group
// of channels that share a first path component, or a channel.
type sidebarRow struct {
	// id is the channel; it is empty for the "all channels" row and for a heading.
	id string
	// heading is the text of a heading row, the group's root and a slash; it is empty for the
	// two other kinds of row.
	heading string
	// count is how many records the channel holds, in every level; for the "all channels"
	// row, how many records there are in all.
	count int
}

// selectable says the row can be chosen: a heading cannot.
func (r sidebarRow) selectable() bool { return r.heading == "" }

// sidebarRoot is the first path component of a channel, which groups it under a heading. A
// channel without a component is its own group.
func sidebarRoot(channel string) string {
	if parts := sidebarParts(channel); len(parts) > 0 {
		return parts[0]
	}
	return channel
}

// sidebarParts splits a channel into its path components, leaving out the empty ones.
func sidebarParts(channel string) []string {
	return strings.FieldsFunc(channel, func(r rune) bool { return r == '/' })
}

// sidebarRank is the position of a group in the list: the well-known roots first, in
// sidebarRootOrder, then every other.
func sidebarRank(root string) int {
	if i := slices.Index(sidebarRootOrder, root); i >= 0 {
		return i
	}
	return len(sidebarRootOrder)
}

// sidebarChannelRows builds the rows of the list from the channels the query found: the
// "all channels" row with the total count, then each group under a heading with its channels
// in name order. The groups follow sidebarRootOrder.
func sidebarChannelRows(channels map[string]core.LogChannelCount) []sidebarRow {
	ids := make([]string, 0, len(channels))
	total := 0
	for id, count := range channels {
		ids = append(ids, id)
		total += count.Total
	}
	slices.SortFunc(ids, func(a, b string) int {
		if byRank := cmp.Compare(sidebarRank(sidebarRoot(a)), sidebarRank(sidebarRoot(b))); byRank != 0 {
			return byRank
		}
		return strings.Compare(a, b)
	})
	rows := make([]sidebarRow, 1, 2*len(ids)+1)
	rows[0] = sidebarRow{count: total}
	previous := ""
	for _, id := range ids {
		if root := sidebarRoot(id); root != previous {
			rows = append(rows, sidebarRow{heading: root + "/"})
			previous = root
		}
		rows = append(rows, sidebarRow{id: id, count: channels[id].Total})
	}
	return rows
}

// sidebarTitle is the name a channel has in the list, under the heading of its group: the
// channel itself when it has one component, otherwise the components after the first without
// the "host" ones, which every plugin has and which say nothing.
func sidebarTitle(channel string) string {
	parts := sidebarParts(channel)
	switch len(parts) {
	case 0:
		return ""
	case 1:
		return channel
	}
	kept := make([]string, 0, len(parts)-1)
	for _, part := range parts[1:] {
		if part != "host" {
			kept = append(kept, part)
		}
	}
	return strings.Join(kept, "/")
}

// sidebarSelectionColor is the fill of a selected row: the accent tint while the list has
// the keyboard focus and the neutral one otherwise. They are the colors of the macOS
// client's lists.
func (w *window) sidebarSelectionColor(focused bool) gfx.Color {
	switch {
	case w.pal.dark && focused:
		return gfx.RGB24(0x2A4371)
	case w.pal.dark:
		return gfx.RGB24(0x33353B)
	case focused:
		return gfx.RGB24(0xD0DFFE)
	}
	return gfx.RGB24(0xE9EAEE)
}

// sidebarState is the part of the channel list that outlives a frame.
type sidebarState struct {
	// list holds the rows and chosen the rows the user chose, by their position. A press
	// chooses one row, ⌘ or Ctrl adds a row or takes it out and ⇧ chooses a range, as in
	// the macOS client's list. The channels the query is restricted to are the truth: a
	// choice the list reports is handed to the model, and the list takes its choice from the
	// model's.
	list   ui.ListState
	chosen ui.Selection
	// rows are the rows of the paint being declared, which list.Header reads.
	rows []sidebarRow
}

// init makes the headings of the groups the sections of the list: they stay at its top while
// the group's channels scroll under them, and cannot be chosen.
func (s *sidebarState) init() {
	s.list.Selection = &s.chosen
	s.list.Header = func(i int) bool { return !s.rows[i].selectable() }
}

// sidebarSelection is the rows of the list that are selected: the channels the query is
// restricted to, or, when it is not, the "all channels" row.
func (w *window) sidebarSelection(rows []sidebarRow) map[string]bool {
	prefixes := w.model.prefs.Query.ChannelPrefixes
	selected := map[string]bool{}
	for _, row := range rows {
		switch {
		case !row.selectable():
		case row.id == "":
			if len(prefixes) == 0 {
				selected[""] = true
			}
		case slices.Contains(prefixes, row.id):
			selected[row.id] = true
		}
	}
	return selected
}

// sidebarApply hands the choice the user made in the list to the model. The model is asked
// to restrict the channels only when the selection changes. Choosing the "all channels" row
// together with others while a restriction is on clears the restriction, as does an empty
// selection.
func (w *window) sidebarApply(rows []sidebarRow) {
	s := &w.sidebar
	chosen := map[string]bool{}
	for index := range s.chosen.All() {
		if index >= 0 && index < len(rows) && rows[index].selectable() {
			chosen[rows[index].id] = true
		}
	}
	if maps.Equal(chosen, w.sidebarSelection(rows)) {
		return
	}
	clears := chosen[""] && len(w.model.prefs.Query.ChannelPrefixes) > 0
	var channels []string
	if !clears {
		for id := range chosen {
			if id != "" {
				channels = append(channels, id)
			}
		}
		slices.Sort(channels)
	}
	w.model.setChannels(channels)
}

// sidebarPanel is the column at the leading side of the window: the list of channels, which
// scrolls; under it the hint on selecting several channels; and at the bottom the card of
// the detailed diagnostics.
func (w *window) sidebarPanel(c ui.C) {
	s := &w.sidebar
	rows := sidebarChannelRows(w.model.channels)
	s.rows = rows
	if !s.list.Changed() {
		selected := w.sidebarSelection(rows)
		s.chosen.Clear()
		for i, row := range rows {
			if row.selectable() && selected[row.id] {
				s.chosen.Add(i)
			}
		}
	}
	ui.List(c, &s.list, len(rows), func(row ui.ListRow) {
		w.sidebarRow(row, rows[row.Index])
	}).Label(w.text.Logs.Channel).Grow(1).Shrink(1).MinHeight(0)
	if s.list.Changed() {
		w.sidebarApply(rows)
	}
	ui.Row(c).Shrink(0).Gap(4).Items(ui.Center).Children(func() {
		ui.Row(c).Shrink(1).MinWidth(0).PadX(sidebarInset).PadY(6).Children(func() {
			w.mono(c, w.text.Logs.SelectSeveral, 10.5, w.pal.tx3).LineHeight(13).Ellipsis()
		})
		w.info(c, w.text.Logs.ChannelHelp)
	})
	if left := w.model.diagnosticsLeft(); left > 0 {
		w.diagnosticsOn(c, left)
	} else {
		w.diagnosticsOff(c)
	}
}

// sidebarRow declares one row of the list. A heading is text; the other rows highlight when
// selected.
func (w *window) sidebarRow(row ui.ListRow, r sidebarRow) {
	c := row.C
	if !r.selectable() {
		row.Element.Height(sidebarRowHeight).FillWidth().Background(w.pal.bg2)
		ui.Row(c).Grow(1).MarginX(sidebarInset).Items(ui.Center).Children(func() {
			w.sidebarName(c, r.heading, w.pal.tx3)
		})
		return
	}
	name, color := "□ "+w.text.Logs.AllChannels, w.pal.tx
	if r.id != "" {
		name, color = "■ "+sidebarTitle(r.id), channelColor(r.id)
		if w.model.unreadErrors[r.id] {
			name += " ●"
			row.Element.Tooltip(w.text.Logs.UnreadErrors)
		}
	}
	// The row spans the whole width, as a table row does; the highlight and the text inside
	// it keep the list's inset.
	row.Element.Height(sidebarRowHeight).FillWidth()
	_, focused := c.Canvas().Focused().In(row.ID.Scope())
	inner := ui.Row(c).Grow(1).MarginX(sidebarInset).Radius(sidebarRadius).Gap(4).Items(ui.Center)
	if row.Selected() {
		inner = inner.Background(w.sidebarSelectionColor(focused))
	}
	inner.Children(func() {
		w.sidebarName(c, name, color).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
		w.mono(c, groupNumber(r.count), 11, w.pal.tx3).LineHeight(18).
			Width(sidebarCountWidth).Shrink(0).TextEnd()
	})
}

// sidebarName declares the text of a row's name, in the interface font.
func (w *window) sidebarName(c ui.C, s string, color ui.Color) ui.Box {
	return ui.Text(c, s).FontSize(12).LineHeight(18).Color(color)
}

// sidebarCard declares the box of the diagnostics card, with the margin around it, and
// returns it for the caller to fill.
func (w *window) sidebarCard(c ui.C, fill, outline ui.Color) ui.Box {
	return ui.Column(c).Height(sidebarCardHeight).Shrink(0).PadX(10).PadY(8).Gap(3).
		MarginSides(0, 10, 6, 10).Radius(sidebarCardRadius).Background(fill).Stroke(1, outline)
}

// diagnosticsOn is the green card shown while detailed diagnostics are on: what it is, the
// category it covers, the time left before it turns itself off and a way to turn it off.
func (w *window) diagnosticsOn(c ui.C, left time.Duration) {
	category := w.model.diagnosticCategory
	if category == "" {
		category = w.text.Logs.AllChannels
	}
	seconds := int(left / time.Second)
	remaining := fmt.Sprintf("%02d:%02d", seconds/60, seconds%60)
	small := func(s string) ui.Box {
		return w.mono(c, s, 10.5, w.pal.tx2).LineHeight(13)
	}
	w.sidebarCard(c, w.pal.grn.WithAlpha(0.10), w.pal.grn.WithAlpha(0.4)).Children(func() {
		ui.Row(c).Gap(5).Items(ui.Center).Children(func() {
			w.mono(c, "●", 12.5, w.pal.grn).LineHeight(15)
			w.mono(c, w.text.Logs.DiagnosticsOn, 12.5, w.pal.grn).LineHeight(15).Ellipsis()
		})
		small(w.text.Logs.Category(category)).Ellipsis()
		ui.Row(c).Gap(4).Items(ui.Center).Children(func() {
			small(w.text.Logs.AutoOff(remaining))
			small("·")
			stop := ui.ButtonBase(c.Part("stop-diagnostics"), w.text.Logs.StopDiagnostics).Children(func() {
				w.mono(c, w.text.Logs.StopDiagnostics, 10.5, w.pal.blu).LineHeight(13)
			})
			if stop.Clicked() {
				w.model.setDiagnosticsEnabled(false)
			}
		})
	})
}

// diagnosticsOff is the card shown while detailed diagnostics are off: its title with an
// explanation, and the button that turns them on.
func (w *window) diagnosticsOff(c ui.C) {
	w.sidebarCard(c, w.pal.bg3, w.pal.bd).Children(func() {
		ui.Row(c).Gap(5).Items(ui.Center).Children(func() {
			w.mono(c, w.text.Logs.Diagnostics, 12.5, w.pal.tx).LineHeight(15).Ellipsis()
			w.info(c, w.text.Logs.DiagnosticsHelp)
		})
		ui.Spacer(c)
		// The button keeps its own width and sits at the leading end.
		ui.Row(c).Shrink(0).Children(func() {
			if w.button(c, "enable-diagnostics", "", w.text.Logs.EnableDiagnostics, buttonOptions{height: 22}).Clicked() {
				w.model.setDiagnosticsEnabled(true)
			}
		})
	})
}
