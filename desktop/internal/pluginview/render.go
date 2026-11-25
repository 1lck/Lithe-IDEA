package pluginview

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Host is what a surface lends the views it draws: its theme, its words, its icons and
// the settings page a region sits on.
type Host struct {
	Palette  Palette
	Language i18n.Language
	// Icon is the host icon a node names; ok is false for a name the host does not draw.
	Icon func(name string) (gfx.Icon, bool)
	// Images reads the PNGs of the plugin's package a canvas draws; nil draws none.
	Images *Images
	// Info draws the host's ⓘ for an info text. It is a callback the renderer calls with
	// the paint's own c, as Viva's PageConfig.View is; it keeps no context.
	Info func(c ui.C, text string) // viva:ignore kept-context
	// Settings is the settings page of a region; nil in a tool window.
	Settings SettingsHost
}

// SettingsHost is the settings page a region is drawn on. Its rows, tools, drafts and
// action flow stay the page's own: a region shows them, and never stores a value.
type SettingsHost interface {
	// Row draws the page's own row for a declared setting, exactly as the page draws it.
	// It reports false when the page has no such row.
	Row(c ui.C, setting string, key NodeKey) bool
	// Tool draws the toolchain pages' row for a tool the plugin defines or requires; with
	// choose the row is also the tool's picker, whose choice edits the page's toolchain
	// draft. It reports false when the host has no row for it.
	Tool(c ui.C, tool string, choose bool, key NodeKey) bool
	// Binding is the draft of a declared setting for a control bound to it.
	Binding(setting string) (Binding, bool)
	// Action runs a setting action through the page's confirmation flow. It runs
	// after the paint, as a native dialog must.
	Action(action string)
	// ActionEnabled reports whether the action can run now.
	ActionEnabled(action string) bool
}

// Binding is a declared setting's draft, which a control bound to it edits. Exactly
// one of Text, On and Selected is set, by the setting's kind.
type Binding struct {
	Title    string
	Text     *string
	On       *bool
	Selected *int
	// Options are the choices of an enum setting, and OptionLabel their words.
	Options     []int
	OptionLabel func(int) string
	// Editable is false while the draft cannot change: the page is saving, the setting
	// is not editable in the scope shown, or there is no file to write.
	Editable bool
	// Value is the draft value typed as the setting stores it: a number for an integer.
	Value func() any
	// Edited tells the page the control changed the draft.
	Edited func()
}

// NodeKey names a view node by ID or position without changing the current UI
// context. A host applies it only after it knows the node has a row to draw.
type NodeKey struct {
	id    string
	index int
}

// Apply names the container or control declared next. Do not call it on a path
// that can return without drawing that element.
func (k NodeKey) Apply(c ui.C) ui.C {
	if k.id != "" {
		return c.Key("#" + k.id)
	}
	return c.KeyInt(k.index)
}

// Draw declares a view in the space its parent gives it. In a tool window the view fills
// the body (fill), and a tree among its top-level nodes takes the height the others leave;
// a tree in a row or a section takes the height of its rows, up to treeRows. In a settings
// region the view takes the width and the height of its content.
func Draw(c ui.C, s *Session, host *Host, fill bool) {
	if s == nil || host == nil {
		return
	}
	// The answer that arrived is drawn in this paint, and a waiting viewport or settings
	// event asks for the paint that sends it.
	if wait := s.Take(); wait > 0 {
		if canvas := c.Canvas(); canvas != nil {
			canvas.RequestFrameIn(wait)
		}
	}
	r := &renderer{s: s, host: host}
	// The paint measures the width the nodes are laid out in: the view's, less the body's
	// padding in a tool window. It sends open, and later resize; the scroll bars of the
	// body float over it, so they take none of the width.
	if s.measure == nil {
		s.measure = s.measured
	}
	s.inset = 0
	if fill {
		s.inset = 2 * bodyPadding
	}
	root := ui.Column(c).FillWidth().Gap(10).Draw(s.measure)
	if fill {
		root = root.Fill()
	}
	root.Children(func() {
		r.frame(c)
		if !s.Drawn() {
			return
		}
		nodes := s.View()
		if fill && !hasTree(nodes) {
			ui.Scroll(c).FillWidth().Grow(1).Children(func() {
				ui.Column(c).FillWidth().Gap(10).PadX(bodyPadding).PadY(bodyPadding).Children(func() { r.nodes(c, nodes) })
			})
			return
		}
		body := ui.Column(c).FillWidth().Gap(10)
		if fill {
			body = body.Grow(1).PadX(bodyPadding).PadY(bodyPadding)
		}
		r.fillTree = fill
		body.Children(func() { r.nodes(c, nodes) })
	})
}

// bodyPadding is the space around the nodes of a view that fills a tool window.
const bodyPadding = 10

// measured is the paint callback that gives the session the width its nodes are laid
// out in, and asks for the frame that sends a resize once it is due.
func (s *Session) measured(d *ui.DrawContext) {
	if wait := s.Measured(d.Rect.Width - s.inset); wait > 0 && d.Canvas != nil {
		d.Canvas.RequestFrameIn(wait)
	}
}

// hasTree reports a tree among the top-level nodes: it scrolls by itself, so the body does not.
func hasTree(nodes []Node) bool {
	for i := range nodes {
		if nodes[i].Type == "tree" {
			return true
		}
	}
	return false
}

// renderer declares the nodes of one view in one paint.
type renderer struct {
	s    *Session
	host *Host
	// fillTree says a tree declared now is a top-level node of a view that fills its
	// window, so it takes the height the other nodes leave; a tree in a row or a section
	// sits in the scrolling body and takes the height of its rows.
	fillTree bool
}

// treeRows is the most rows a tree in the scrolling body shows before it scrolls itself.
const treeRows = 12

// frame is the view's own frame: what is loading, and the failure of the last call with
// Retry. The rest of the window stays usable, and a drawn view stays under it.
func (r *renderer) frame(c ui.C) {
	p := &r.host.Palette
	err := r.s.Err()
	if err == nil {
		if r.s.Busy() && !r.s.Drawn() {
			ui.Text(c, i18n.Shared(r.host.Language, "native.loading")).FontSize(12).Color(p.TextMuted)
		}
		return
	}
	message, detail := r.failure(err)
	ui.Row(c.Key("failure")).FillWidth().Gap(8).Items(ui.Center).PadX(10).PadY(6).Radius(6).
		Background(p.Warning.WithAlpha(0.10)).Border(1, p.Warning.WithAlpha(0.35)).Children(func() {
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
			ui.Wrap(c, message).FontSize(12).Color(p.Text)
			if detail != "" {
				ui.Wrap(c, detail).FontSize(11).Color(p.TextMuted)
			}
		})
		if ui.Button(c, i18n.Shared(r.host.Language, "desktop.everywhere.retry")).Outline().Small().Shrink(0).Clicked() {
			r.s.Retry()
		}
	})
}

// failure is the host's words for a failed call, and the diagnostic under them: Core's
// refusal with the JSON path it names, or the plugin's own error, which is not translated.
func (r *renderer) failure(err error) (message, detail string) {
	language := r.host.Language
	var rejection *core.MarketplaceRejection
	switch {
	case errors.As(err, &rejection):
		detail = rejection.Message
		if rejection.Field != "" {
			detail = rejection.Field + ": " + rejection.Message
		}
		return i18n.Shared(language, "desktop.pluginView.invalid"), detail
	case errors.Is(err, context.DeadlineExceeded):
		return i18n.Shared(language, "desktop.pluginView.timedOut"), ""
	}
	return i18n.Shared(language, "desktop.pluginView.failed"), err.Error()
}

// nodes declares nodes in order. Containers and controls are keyed by ID or place;
// labels are leaves without identity.
func (r *renderer) nodes(c ui.C, nodes []Node) {
	for i := range nodes {
		n := &nodes[i]
		r.node(c, n, NodeKey{id: n.ID, index: i})
	}
}

// node declares one node.
func (r *renderer) node(c ui.C, n *Node, key NodeKey) {
	p := &r.host.Palette
	switch n.Type {
	case "row", "section":
		// A tree among the children does not fill the window: rows and sections take the
		// height of their content.
		fillTree := r.fillTree
		r.fillTree = false
		defer func() { r.fillTree = fillTree }()
	}
	switch n.Type {
	case "row":
		ui.Flow(key.Apply(c)).FillWidth().Items(ui.Center).Gap(8).LineGap(6).Children(func() { r.nodes(c, n.Children) })
	case "section":
		ui.Column(key.Apply(c)).FillWidth().Gap(6).Children(func() {
			if n.Title != "" {
				ui.Row(c).FillWidth().MinHeight(28).Items(ui.Center).Gap(8).Children(func() {
					ui.Text(c, n.Title).FontSize(13).Weight(gfx.WeightSemibold).Color(p.Text).Shrink(1).MinWidth(0).Ellipsis()
					r.info(c, n.Info)
				})
			}
			ui.Column(c).FillWidth().Gap(8).Children(func() { r.nodes(c, n.Children) })
		})
	case "label":
		r.label(c, n)
	case "textField":
		r.textField(c, n, key)
	case "select", "segmented":
		r.choice(c, n, key)
	case "toggle":
		r.toggle(c, n, key)
	case "button":
		r.button(key.Apply(c), n)
	case "keyValue":
		r.keyValue(key.Apply(c), n)
	case "table":
		r.table(key.Apply(c), n)
	case "banner":
		tone := p.Tone(n.Tone, p.Accent)
		ui.Row(key.Apply(c)).FillWidth().PadX(10).PadY(8).Radius(6).Background(tone.WithAlpha(0.10)).Border(1, tone.WithAlpha(0.35)).Children(func() {
			ui.Wrap(c, n.Text).FontSize(12).Color(p.Text).Grow(1).MinWidth(0)
		})
	case "setting":
		if r.host.Settings != nil {
			r.host.Settings.Row(c, n.Setting, key)
		}
	case "tool":
		if r.host.Settings != nil {
			r.host.Settings.Tool(c, n.Tool, n.Choose, key)
		}
	case "tree":
		r.tree(key.Apply(c), n)
	case "canvas":
		r.canvas(key.Apply(c), n)
	}
}

// info draws the host's ⓘ for text, nothing for none.
func (r *renderer) info(c ui.C, text string) {
	if text != "" && r.host.Info != nil {
		r.host.Info(c, text)
	}
}

// textStyle is the font of a label style: its size, weight and whether it is monospaced.
func textStyle(style string) (size float32, weight float32, mono bool) {
	switch style {
	case "title":
		return 15, gfx.WeightSemibold, false
	case "strong":
		return 13, gfx.WeightSemibold, false
	case "caption":
		return 11, gfx.WeightRegular, false
	case "mono":
		return 12, gfx.WeightRegular, true
	}
	return 13, gfx.WeightRegular, false
}

// characterWidth is the width a reserved character takes at size: an average glyph of
// the interface font, or the monospace advance.
func characterWidth(size float32, mono bool) float32 {
	if mono {
		return size * 0.62
	}
	return size * 0.56
}

// label declares a label: body and caption wrap, the other styles are one line.
func (r *renderer) label(c ui.C, n *Node) {
	p := &r.host.Palette
	size, weight, mono := textStyle(n.Style)
	fallback := p.Text
	if n.Style == "caption" {
		fallback = p.TextSecondary
	}
	color := p.Tone(n.Tone, fallback)
	var box ui.Box
	if n.Style == "" || n.Style == "body" || n.Style == "caption" {
		box = ui.Wrap(c, n.Text)
	} else {
		box = ui.Text(c, n.Text).Ellipsis()
	}
	box = box.FontSize(size).Weight(weight).Color(color).MinWidth(0)
	if mono {
		box = box.Mono()
	}
	if count, _ := n.characters(); count > 0 {
		box.Width(float32(count) * characterWidth(size, mono)).Shrink(0)
	} else {
		box.Shrink(1)
	}
}

// caption declares a control's label and ⓘ on its leading side; nothing for no label.
func (r *renderer) caption(c ui.C, label, info string) {
	if label == "" && info == "" {
		return
	}
	ui.Row(c.Part("caption")).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).Children(func() {
		if label != "" {
			ui.Text(c, label).FontSize(12).Weight(gfx.WeightSemibold).Color(r.host.Palette.Text).Shrink(1).MinWidth(0).Ellipsis()
		}
		r.info(c, info)
	})
}

// binding is the bound draft of n, ok false for a control with its own value or a
// setting the page does not have.
func (r *renderer) binding(n *Node) (Binding, bool) {
	if n.Setting == "" || r.host.Settings == nil {
		return Binding{}, false
	}
	return r.host.Settings.Binding(n.Setting)
}

// changed sends change for n: the bound setting's typed draft, or the control's own value.
func (r *renderer) changed(n *Node, binding Binding, bound bool, value any) {
	event := Event{Name: "change", Node: n.ID, Value: value}
	if bound {
		event.Setting = n.Setting
		if binding.Value != nil {
			event.Value = binding.Value()
		}
	}
	r.s.Send(event)
}

// textField declares a text field. It commits on Enter or when it loses the focus with
// text that differs from what it last sent, never per keystroke.
func (r *renderer) textField(c ui.C, n *Node, key NodeKey) {
	binding, bound := r.binding(n)
	if n.Setting != "" && (!bound || binding.Text == nil) {
		return
	}
	label := n.Label
	if bound && label == "" {
		label = binding.Title
	}
	own := n.stringValue()
	state := r.s.field(n.ID, own)
	text := &state.text
	if bound {
		text = binding.Text
	} else if state.last != own && !state.focused {
		state.text, state.last, state.sent = own, own, own
	}
	if !state.started {
		state.sent, state.started = *text, true
	}
	enabled := n.enabled() && (!bound || binding.Editable)
	count, fillWidth := n.characters()
	row := ui.Row(key.Apply(c)).Items(ui.Center).Gap(8).MinWidth(0)
	if fillWidth || count == 0 {
		row = row.Grow(1).Basis(0)
	}
	row.Children(func() {
		r.caption(c, n.Label, n.Info)
		if !enabled {
			r.readOnly(c, label, *text, count, fillWidth, n.Mono)
			state.focused = false
			return
		}
		field := ui.TextField(c, text, label, n.Placeholder).Height(30).MinWidth(0)
		if n.Mono {
			field = field.Mono()
		}
		if count > 0 && !fillWidth {
			field = field.Width(float32(count)*characterWidth(13, n.Mono) + 20).Shrink(0)
		} else {
			field = field.Grow(1)
		}
		if field.Changed() && bound && binding.Edited != nil {
			binding.Edited()
		}
		focused := field.State().Focused
		if (field.Submitted() || (state.focused && !focused)) && *text != state.sent {
			state.sent = *text
			r.changed(n, binding, bound, *text)
		}
		state.focused = focused
	})
}

// readOnly is a field that takes no input: its text in a frame, which assistive
// technology reads as a read-only text field, as the settings pages draw one.
func (r *renderer) readOnly(c ui.C, label, value string, count int, fillWidth, mono bool) {
	p := &r.host.Palette
	frame := ui.Row(c).MinWidth(0).Height(30).PadX(10).Border(1, p.Line).Radius(6).Items(ui.Center).
		HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleTextField, Value: value, ReadOnly: true, Disabled: true})
	if count > 0 && !fillWidth {
		frame = frame.Width(float32(count)*characterWidth(13, mono) + 20).Shrink(0)
	} else {
		frame = frame.Grow(1)
	}
	frame.Children(func() {
		text := ui.Text(c, value).FontSize(13).Color(p.TextMuted).Ellipsis()
		if mono {
			text.Mono()
		}
	})
}

// choice declares a select or segmented control, over its own options or a bound enum's.
// A control that takes no input is the read-only frame the settings pages draw, since
// Disabled does not reach a Select or Choice in pinned Viva.
func (r *renderer) choice(c ui.C, n *Node, key NodeKey) {
	binding, bound := r.binding(n)
	if n.Setting != "" && (!bound || binding.Selected == nil) {
		return
	}
	enabled := n.enabled() && (!bound || binding.Editable)
	label := n.Label
	if bound && label == "" {
		label = binding.Title
	}
	ui.Row(key.Apply(c)).Items(ui.Center).Gap(8).MinWidth(0).Children(func() {
		r.caption(c, n.Label, n.Info)
		if bound {
			if !enabled {
				r.readOnly(c, label, binding.OptionLabel(*binding.Selected), 0, false, false)
				return
			}
			if choose(c, n, label, binding.Selected, binding.Options, binding.OptionLabel) {
				if binding.Edited != nil {
					binding.Edited()
				}
				r.changed(n, binding, true, nil)
			}
			return
		}
		state := r.s.selection(n.ID, n.stringValue())
		values, words := optionsOf(n.Options)
		name := func(value string) string { return words[value] }
		if !enabled {
			r.readOnly(c, label, name(state.value), 0, false, false)
			return
		}
		if choose(c, n, label, &state.value, values, name) {
			r.changed(n, binding, false, state.value)
		}
	})
}

// choose declares the select or segmented control of n over value and reports a choice
// the user made in this paint.
func choose[T comparable](c ui.C, n *Node, label string, value *T, values []T, name func(T) string) bool {
	if n.Type == "segmented" {
		return ui.Choice(c, value, values, name).Changed()
	}
	return ui.Select(c, value, values, name).MinWidth(120).MaxWidth(230).Label(label).Changed()
}

// optionsOf splits options into their values and the words of each.
func optionsOf(options []Option) ([]string, map[string]string) {
	values := make([]string, len(options))
	words := make(map[string]string, len(options))
	for i, option := range options {
		values[i] = option.Value
		words[option.Value] = option.Label
	}
	return values, words
}

// toggle declares a switch with its label on the leading side.
func (r *renderer) toggle(c ui.C, n *Node, key NodeKey) {
	binding, bound := r.binding(n)
	if n.Setting != "" && (!bound || binding.On == nil) {
		return
	}
	enabled := n.enabled() && (!bound || binding.Editable)
	label := n.Label
	if bound && label == "" {
		label = binding.Title
	}
	ui.Row(key.Apply(c)).Items(ui.Center).Gap(8).MinWidth(0).Children(func() {
		r.caption(c, n.Label, n.Info)
		on := binding.On
		if !bound {
			on = &r.s.toggle(n.ID, n.boolValue()).on
		}
		if ui.Switch(c, on, "").Label(label).Disabled(!enabled).Changed() {
			if bound && binding.Edited != nil {
				binding.Edited()
			}
			r.changed(n, binding, bound, *on)
		}
	})
}

// button declares a button: the primary tone is filled, the others outlined. With an
// action it runs that setting action through the page's flow instead of sending click.
func (r *renderer) button(c ui.C, n *Node) {
	enabled := n.enabled()
	if n.Action != "" {
		enabled = enabled && r.host.Settings != nil && r.host.Settings.ActionEnabled(n.Action)
	}
	button := ui.Button(c, n.Text)
	if n.Tone != "primary" {
		button = button.Outline()
	}
	if icon, ok := r.icon(n.Icon); ok {
		button = button.Icon(icon)
	}
	if !button.Shrink(0).Disabled(!enabled).Clicked() {
		return
	}
	if n.Action != "" {
		action, settings := n.Action, r.host.Settings
		c.After(func() { settings.Action(action) })
		return
	}
	r.s.Send(Event{Name: "click", Node: n.ID})
}

// icon is the host icon name names, ok false for none or one the host does not draw.
func (r *renderer) icon(name string) (gfx.Icon, bool) {
	if name == "" || r.host.Icon == nil {
		return gfx.Icon{}, false
	}
	return r.host.Icon(name)
}

// tree declares a tree: the host opens and closes items without the plugin, a click or
// Return on an item selects it (select), and a double click or Return activates it
// (activate). Activating a branch also opens or closes it, as an IDE's tree does.
func (r *renderer) tree(c ui.C, n *Node) {
	p := &r.host.Palette
	state := r.s.tree(n.ID)
	state.flatten(n.Items)
	content := func(i int) {
		item := state.rows[i].item
		if icon, ok := r.icon(item.Icon); ok {
			ui.Icon(c, icon).Size(14, 14).Shrink(0)
		}
		ui.Text(c, item.Label).FontSize(12.5).Color(p.Text).Shrink(1).MinWidth(0).Ellipsis().LabelFor(state.tree.RowID(i))
		if item.Detail != "" {
			ui.Text(c, item.Detail).FontSize(11.5).Color(p.TextMuted).Shrink(2).MinWidth(0).Ellipsis()
		}
	}
	box := ui.Tree(c, &state.tree, len(state.rows), state.tree.Label, content).Scrollbars().Label(n.Label).FillWidth()
	if r.fillTree {
		box.Grow(1).MinHeight(80)
	} else {
		box.Height(state.tree.RowHeight * float32(max(1, min(len(state.rows), treeRows))))
	}
	toggled := -1
	if i, ok := state.tree.Toggled(); ok {
		toggled = i
		item := state.rows[i].item
		open := !state.expanded(item)
		c.After(func() {
			state.open[item.ID] = open
			if item.HasChildren {
				r.s.Send(Event{Name: "expand", Node: n.ID, Item: item.ID, Value: open})
			}
		})
	}
	// Only viewport changes cross Core; a failed event pauses until explicit Retry.
	if r.s.options.Page != nil {
		if state.paging == nil {
			state.paging = ui.NewEffectKeyed(func(ctx context.Context, key pageKey) (bool, error) {
				bounded, cancel := context.WithTimeout(ctx, 2*time.Second)
				defer cancel()
				var result struct {
					Load bool `json:"load"`
				}
				err := r.s.options.Page(bounded, map[string]any{"operation": "treePage", "cursor": key.Cursor, "lastCursor": key.LastCursor, "count": key.Count, "lastCount": key.LastCount, "rows": key.Rows, "lastVisible": key.Visible}, &result)
				return result.Load, err
			})
		}
		_, last := state.tree.Visible()
		key := pageKey{n.Cursor, state.cursor, len(n.Items), state.count, len(state.rows), max(0, last)}
		ui.Effect(c.Part("paging"), state.paging, key)
		if load, err, ok := state.paging.Take(); ok {
			if err != nil {
				if r.s.options.Failed != nil {
					r.s.options.Failed(err)
				}
			} else if load && r.s.Err() == nil {
				cursor, count := n.Cursor, len(n.Items)
				c.After(func() {
					state.cursor = cursor
					state.count = count
					r.s.Send(Event{Name: "loadMore", Node: n.ID, Cursor: cursor})
				})
			}
		}
	}
	i, ok := state.tree.Chosen()
	if !ok {
		return
	}
	canvas := c.Canvas()
	byKey := canvas.ClickedByKey(state.tree.RowID(i))
	info, _ := canvas.ClickInfo()
	item, tree, session := state.rows[i].item, n.ID, r.s
	activate := byKey || info.Clicks >= 2
	branch := (len(item.Children) > 0 || item.HasChildren) && toggled != i
	open := !state.expanded(item)
	c.After(func() {
		if item.ID != state.selected {
			state.selected = item.ID
			session.Send(Event{Name: "select", Node: tree, Item: item.ID})
		}
		if !activate {
			return
		}
		if branch {
			state.open[item.ID] = open
			if item.HasChildren {
				session.Send(Event{Name: "expand", Node: tree, Item: item.ID, Value: open})
			}
		}
		session.Send(Event{Name: "activate", Node: tree, Item: item.ID})
	})
}

// keyValue declares label and value pairs, the labels in one column.
func (r *renderer) keyValue(c ui.C, n *Node) {
	p := &r.host.Palette
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		for i, item := range n.Items {
			ui.Row(c.KeyInt(i)).FillWidth().Items(ui.Start).Gap(12).Children(func() {
				ui.Text(c, item.Label).FontSize(12).Color(p.TextSecondary).Basis(0).Grow(1).MinWidth(80).Ellipsis()
				ui.Wrap(c, item.Value).FontSize(12).Color(p.Tone(item.Tone, p.Text)).Basis(0).Grow(2).MinWidth(0)
			})
		}
	})
}

// table declares a read-only table: a header row, then one single-line cell per column.
func (r *renderer) table(c ui.C, n *Node) {
	p := &r.host.Palette
	cell := func(c ui.C, text string, column int, header bool) {
		box := ui.Text(c, text).FontSize(12).Basis(0).Grow(1).MinWidth(0).Ellipsis()
		if header {
			box = box.Weight(gfx.WeightSemibold).Color(p.TextSecondary)
		} else {
			box = box.Color(p.Text)
		}
		if column < len(n.Columns) {
			switch n.Columns[column].Align {
			case "end":
				box.TextEnd()
			case "center":
				box.TextCenter()
			}
		}
	}
	ui.Column(c).FillWidth().Border(1, p.Line).Radius(6).Clip().Children(func() {
		ui.Row(c.Key("header")).FillWidth().Height(26).PadX(10).Gap(12).Items(ui.Center).Background(p.Sidebar).Children(func() {
			for i, column := range n.Columns {
				cell(c, column.Title, i, true)
			}
		})
		for i, cells := range n.Rows {
			ui.Row(c.Key("line-" + strconv.Itoa(i))).FillWidth().Height(1).Background(p.Line)
			ui.Row(c.KeyInt(i)).FillWidth().Height(26).PadX(10).Gap(12).Items(ui.Center).Children(func() {
				for column := range n.Columns {
					text := ""
					if column < len(cells) {
						text = cells[column]
					}
					cell(c, text, column, false)
				}
			})
		}
	})
}
