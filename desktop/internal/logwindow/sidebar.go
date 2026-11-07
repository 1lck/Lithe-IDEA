package logwindow

import (
	"cmp"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// The identities of the channel list and of the diagnostics card under it. Each row of the
// list is a hit of its own, so a press carries the modifier keys it was made with.
var (
	sidebarScope           = tree.Sub(page, tree.Name("sidebar"))
	sidebarRowScope        = tree.Sub(sidebarScope, tree.Name("rows"))
	sidebarList            = tree.ID(sidebarScope, "list")
	sidebarChannelHelp     = tree.ID(sidebarScope, "channel-help")
	sidebarDiagnosticsHelp = tree.ID(sidebarScope, "diagnostics-help")
	sidebarEnable          = tree.ID(sidebarScope, "enable")
	sidebarStop            = tree.ID(sidebarScope, "stop")
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

// sidebarState is the part of the channel list that outlives a frame.
type sidebarState struct {
	// anchor is the channel a Shift-click extends the selection from; hasAnchor says there
	// is one. The macOS client keeps the row's number; keeping the channel makes the anchor
	// survive channels appearing above it.
	anchor    string
	hasAnchor bool
}

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

// sidebarSelect is the selection a press on target makes, given the rows that can be chosen,
// in order, and what is selected. Shift extends from the anchor to target, replacing the
// selection or, with toggling, adding to it; toggling alone adds target or, if it is selected
// already, removes it; a plain press selects target alone.
func sidebarSelect(target string, order []string, selected map[string]bool, anchor string, hasAnchor, extending, toggling bool) map[string]bool {
	end := slices.Index(order, target)
	if end < 0 {
		return selected
	}
	result := make(map[string]bool, len(selected)+1)
	if toggling {
		maps.Copy(result, selected)
	}
	if extending && hasAnchor {
		if start := slices.Index(order, anchor); start >= 0 {
			for _, id := range order[min(start, end) : max(start, end)+1] {
				result[id] = true
			}
			return result
		}
	}
	if toggling {
		if result[target] {
			delete(result, target)
		} else {
			result[target] = true
		}
		return result
	}
	result[target] = true
	return result
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

// sidebarChoose applies a press on the row of channel target made with modifiers. Command or
// Control toggles the row and Shift extends the selection, as in the macOS client. The
// model is asked to restrict the channels only when the selection changes. Choosing the
// "all channels" row together with others clears the restriction, as does an empty selection.
func (w *window) sidebarChoose(rows []sidebarRow, target string, modifiers ui.Modifiers) {
	order := make([]string, 0, len(rows))
	for _, row := range rows {
		if row.selectable() {
			order = append(order, row.id)
		}
	}
	extending := modifiers&ui.ModifierShift != 0
	toggling := modifiers&(ui.ModifierMeta|ui.ModifierControl) != 0
	current := w.sidebarSelection(rows)
	chosen := sidebarSelect(target, order, current, w.sidebar.anchor, w.sidebar.hasAnchor, extending, toggling)
	if !extending || !w.sidebar.hasAnchor {
		w.sidebar.anchor, w.sidebar.hasAnchor = target, true
	}
	if maps.Equal(chosen, current) {
		return
	}
	// The "all channels" row chosen on top of a restriction lifts it, whatever else is chosen.
	clears := chosen[""] && len(w.model.prefs.Query.ChannelPrefixes) > 0
	var channels []string
	if !clears {
		for id := range chosen {
			if id != "" {
				channels = append(channels, id)
			}
		}
	}
	w.model.setChannels(channels)
}

// sidebarPointer follows a press on a row of the list. The macOS client selects when the
// button goes down, so this does too.
func (w *window) sidebarPointer(canvas *ui.Canvas, rows []sidebarRow) {
	index, event, ok := canvas.PointerIn(sidebarRowScope)
	if !ok || event.Kind != ui.PointerDown || event.Button != ui.PointerButtonPrimary {
		return
	}
	if index >= len(rows) || !rows[index].selectable() {
		return
	}
	w.sidebarChoose(rows, rows[index].id, event.Modifiers)
	canvas.Consume()
}

// drawSidebar is the column at the leading side of the window: the list of channels, which
// scrolls; under it the hint on selecting several channels; and at the bottom the card of
// the detailed diagnostics.
func (w *window) drawSidebar(f *flex.Frame) {
	rows := sidebarChannelRows(w.model.channels)
	canvas := f.Canvas()
	w.sidebarPointer(canvas, rows)
	selected := w.sidebarSelection(rows)
	_, focused := canvas.Focused().In(sidebarRowScope)

	f.ScrollArea(sidebarList).Grow(1).Shrink(1).MinHeight(0).Children(func() {
		for i, row := range rows {
			w.drawSidebarRow(f, i, row, selected[row.id], focused)
			// Pressing with the pointer is handled above, before the rows are declared; this is
			// a row activated from the keyboard, which has no modifiers.
			if row.selectable() && canvas.ClickedByKey(sidebarRowScope.At(i)) {
				w.sidebarChoose(rows, row.id, 0)
			}
		}
	})
	f.Row().Shrink(0).Gap(4).Items(flex.Center).Children(func() {
		f.Row().Shrink(1).MinWidth(0).PadX(sidebarInset).PadY(6).Children(func() {
			w.mono(f, w.text.Logs.SelectSeveral, 10.5, w.pal.tx3).LineHeight(13).Ellipsis()
		})
		w.info(f, sidebarChannelHelp, w.text.Logs.ChannelHelp)
	})
	if left := w.model.diagnosticsLeft(); left > 0 {
		w.drawDiagnosticsOn(f, left)
	} else {
		w.drawDiagnosticsOff(f)
	}
}

// drawSidebarRow declares row i of the list. A heading is text; the other rows are hits that
// highlight when selected.
func (w *window) drawSidebarRow(f *flex.Frame, i int, row sidebarRow, selected, focused bool) {
	if !row.selectable() {
		f.Row().Height(sidebarRowHeight).Shrink(0).Children(func() {
			f.Row().Grow(1).MarginX(sidebarInset).Items(flex.Center).Children(func() {
				w.sidebarName(f, row.heading, w.pal.tx3)
			})
		})
		return
	}
	name, color := "□ "+w.text.Logs.AllChannels, w.pal.tx
	options := ui.HitOptions{Role: ui.RoleOption, Selected: selected}
	if row.id != "" {
		name, color = "■ "+sidebarTitle(row.id), channelColor(row.id)
		if w.model.unreadErrors[row.id] {
			name += " ●"
			options.Hint = w.text.Logs.UnreadErrors
		}
	}
	// The hit spans the whole width, as a table row does; the highlight and the text inside it
	// keep the list's inset.
	f.Row().Height(sidebarRowHeight).Shrink(0).HitWith(sidebarRowScope.At(i), name, options).Children(func() {
		inner := f.Row().Grow(1).MarginX(sidebarInset).Radius(sidebarRadius).Gap(4).Items(flex.Center)
		if selected {
			inner = inner.Background(w.sidebarSelectionColor(focused))
		}
		inner.Children(func() {
			w.sidebarName(f, name, color).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
			w.mono(f, groupNumber(row.count), 11, w.pal.tx3).LineHeight(18).
				Width(sidebarCountWidth).Shrink(0).TextEnd()
		})
	})
}

// sidebarName declares the text of a row's name, in the interface font.
func (w *window) sidebarName(f *flex.Frame, s string, color ui.Color) flex.Box {
	return f.Text(s).FontSize(12).LineHeight(18).Color(color)
}

// sidebarSelectionColor is the fill of a selected row: the accent tint while the list has
// the keyboard focus and the neutral one otherwise. They are the colors of the macOS
// client's lists.
func (w *window) sidebarSelectionColor(focused bool) ui.Color {
	switch {
	case w.pal.dark && focused:
		return ui.RGB24(0x2A4371)
	case w.pal.dark:
		return ui.RGB24(0x33353B)
	case focused:
		return ui.RGB24(0xD0DFFE)
	}
	return ui.RGB24(0xE9EAEE)
}

// sidebarCard declares the box of the diagnostics card, with the margin around it, and
// returns it for the caller to fill.
func (w *window) sidebarCard(f *flex.Frame, fill, outline ui.Color) flex.Box {
	return f.Column().Height(sidebarCardHeight).Shrink(0).PadX(10).PadY(8).Gap(3).
		MarginSides(0, 10, 6, 10).Radius(sidebarCardRadius).Background(fill).Stroke(1, outline)
}

// drawDiagnosticsOn is the green card shown while detailed diagnostics are on: what it is,
// the category it covers, the time left before it turns itself off and a way to turn it off.
func (w *window) drawDiagnosticsOn(f *flex.Frame, left time.Duration) {
	category := w.model.diagnosticCategory
	if category == "" {
		category = w.text.Logs.AllChannels
	}
	seconds := int(left / time.Second)
	remaining := fmt.Sprintf("%02d:%02d", seconds/60, seconds%60)
	small := func(s string) flex.Box {
		return w.mono(f, s, 10.5, w.pal.tx2).LineHeight(13)
	}
	w.sidebarCard(f, w.pal.grn.WithAlpha(0.10), w.pal.grn.WithAlpha(0.4)).Children(func() {
		f.Row().Gap(5).Items(flex.Center).Children(func() {
			w.mono(f, "●", 12.5, w.pal.grn).LineHeight(15)
			w.mono(f, w.text.Logs.DiagnosticsOn, 12.5, w.pal.grn).LineHeight(15).Ellipsis()
		})
		small(w.text.Logs.Category(category)).Ellipsis()
		f.Row().Gap(4).Items(flex.Center).Children(func() {
			small(w.text.Logs.AutoOff(remaining))
			small("·")
			stop := f.Row().HitWith(sidebarStop, w.text.Logs.StopDiagnostics, ui.HitOptions{Role: ui.RoleButton}).Children(func() {
				w.mono(f, w.text.Logs.StopDiagnostics, 10.5, w.pal.blu).LineHeight(13)
			})
			if stop.Clicked() {
				w.model.setDiagnosticsEnabled(false)
			}
		})
	})
}

// drawDiagnosticsOff is the card shown while detailed diagnostics are off: its title with an
// explanation, and the button that turns them on.
func (w *window) drawDiagnosticsOff(f *flex.Frame) {
	w.sidebarCard(f, w.pal.bg3, w.pal.bd).Children(func() {
		f.Row().Gap(5).Items(flex.Center).Children(func() {
			w.mono(f, w.text.Logs.Diagnostics, 12.5, w.pal.tx).LineHeight(15).Ellipsis()
			w.info(f, sidebarDiagnosticsHelp, w.text.Logs.DiagnosticsHelp)
		})
		f.Spacer()
		// The button keeps its own width and sits at the leading end.
		f.Row().Shrink(0).Children(func() {
			if w.button(f, sidebarEnable, "", w.text.Logs.EnableDiagnostics, buttonOptions{height: 22}).Clicked() {
				w.model.setDiagnosticsEnabled(true)
			}
		})
	})
}
