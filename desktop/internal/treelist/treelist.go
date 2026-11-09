// Package treelist is the desktop's collapsible tree list, the one the Project tool window
// shows: the rows of a hierarchy, each moved in by its depth and started by the arrow of a
// branch, with the native highlight for the selected row, hover and press.
//
// The caller owns the hierarchy, what is expanded and what is selected. Each frame it hands
// the list the rows that are visible, top to bottom, and declares what a row shows after its
// arrow (an icon and a name) in a callback. The list declares only the rows in view, with room
// for the others so the scroll bar is true, and reports what the user did — a click on a row
// or on its arrow, a key, a double click — as the row it was about. The caller then changes
// its own state, and the next frame shows it.
//
// A row's key names it across frames: the keyboard and the selection stay on an item while
// rows above it come and go, so a key must stay the item's for as long as the item exists.
package treelist

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The sizes of a row, the same in every tree list.
const (
	// RowHeight is the height of one row.
	RowHeight = 24
	// Indent is how far each level is moved in from its parent.
	Indent = 19
	// Disclosure is the width of the arrow before a branch, and of the room it takes before a
	// leaf, so a branch's leaves line up with its sub-branches.
	Disclosure = 17
	// Icon is the size of the arrow, and of the icon a row's content starts with.
	Icon = 16
	// Gap is the room between the arrow and the content, and between the content's parts.
	Gap = 2
	// Gutter is the room on either side of the rows.
	Gutter = 12
	// Trailing is the room after a row's content.
	Trailing = 8
	// PadY is the room above the first row and below the last.
	PadY = 4
	// Radius rounds the corners of a row's highlight.
	Radius = 4
)

// overscan is how many rows beyond the view are declared above it and below it, so a
// scroll of a row or two never shows an empty strip before the next frame.
const overscan = 2

// List names one tree list's controls: its scroll area, its rows and their arrows. Row k's
// hit is Rows.At(k) and its arrow's Arrows.At(k). Name each list once, when the program
// starts, with scopes of its own.
type List struct {
	Scroll gfx.ID
	Rows   gfx.Scope
	Arrows gfx.Scope
}

// Row is one visible row of the caller's hierarchy.
type Row struct {
	// Key identifies the row; it is 0 or more and stays the item's while the item exists.
	Key int
	// Label is the row's accessible name. Its arrow is named by Options.Expand or
	// Options.Collapse followed by the label.
	Label string
	// Depth is the row's level in the hierarchy, 0 for the top.
	Depth int
	// Branch says the row has children to show, and so an arrow; Expanded says they show.
	Branch, Expanded bool
}

// Options says how a list is drawn in one frame.
type Options struct {
	// Dark paints the dark theme's highlight and arrows.
	Dark bool
	// Expand and Collapse are the accessible names of an arrow that opens or closes its row.
	Expand, Collapse string
	// Width is the width of the column of rows, for a list that scrolls sideways itself, and
	// OffsetX how far the column is moved left. A Width of zero fits the rows to the list.
	Width, OffsetX float32
}

// Result is what a frame declared and what the user did to the list in it.
type Result struct {
	// Area is the scroll area and Content the column of rows in it. They are boxes of the
	// frame that drew them, valid until the next frame.
	Area, Content ui.Box
	// Clicked is the index of the row that was clicked, and Toggled the index of the row
	// whose arrow was; -1 for none.
	Clicked, Toggled int
}

// Action is what a key or a double click asks the caller to do to a row.
type Action uint8

const (
	// None: the key was the list's, and there is nothing to do, such as Up on the first row.
	None Action = iota
	// Select moves the selection to the row, which Key has scrolled into view. The caller
	// gives the row the keyboard as well, with Rows.At(row.Key).
	Select
	// Expand and Collapse open and close the row's branch.
	Expand
	Collapse
	// Activate is Enter: a branch opens or closes, and a leaf opens.
	Activate
)

// Text is the color of a row's name in the native tree.
func Text(dark bool) gfx.Color {
	if dark {
		return gfx.RGB24(0xD1D3D9)
	}
	return gfx.RGB24(0x000000)
}

// palette holds the native tree's highlights: the selected row's while the list has the
// keyboard and while it does not, and the row under the pointer's.
type palette struct {
	focused, inactive, hover gfx.Color
}

func colors(dark bool) palette {
	if dark {
		hover := gfx.RGB24(0xFFFFFF)
		hover.Alpha = 16.0 / 255
		return palette{focused: gfx.RGB24(0x2A4371), inactive: gfx.RGB24(0x33353B), hover: hover}
	}
	hover := gfx.RGB24(0x000000)
	hover.Alpha = 8.0 / 255
	return palette{focused: gfx.RGB24(0xD0DFFE), inactive: gfx.RGB24(0xE9EAEE), hover: hover}
}

// Width is how wide a row at depth is whose content, after the arrow, is content wide: what
// a list that scrolls sideways measures to make its column as wide as its widest row.
func Width(depth int, content float32) float32 {
	return 2*Gutter + float32(depth*Indent) + Disclosure + Gap + content + Trailing
}

// RowTop is where row i starts in the list's content, the offset that scrolls it to the top.
func RowTop(i int) float32 { return PadY + float32(i)*RowHeight }

// Draw declares the list in a scroll area that fills what its container leaves it. selected
// is the index of the selected row, -1 for none. content declares what row i shows after its
// arrow; it is called only for the rows in view and a few beyond.
func (l List) Draw(f *ui.Frame, view *ui.View, rows []Row, selected int, o Options, content func(i int)) Result {
	result := Result{Clicked: -1, Toggled: -1}
	first, last := l.visible(view, len(rows))
	_, rowFocused := f.Canvas().Focused().In(l.Rows)
	_, arrowFocused := f.Canvas().Focused().In(l.Arrows)
	look := colors(o.Dark)
	result.Area = f.ScrollArea(l.Scroll).Fill().PadY(PadY)
	result.Area.Children(func() {
		column := f.Column().FillWidth()
		if o.Width > 0 {
			column = column.Width(o.Width).Shrink(0)
		}
		if o.OffsetX != 0 {
			column = column.MarginSides(0, 0, 0, -o.OffsetX)
		}
		result.Content = column
		column.Children(func() {
			if first > 0 {
				f.Row().Height(float32(first) * RowHeight).Shrink(0)
			}
			for i := first; i < last; i++ {
				clicked, toggled := l.row(f, rows[i], i, i == selected, rowFocused || arrowFocused, o, look, content)
				if clicked {
					result.Clicked = i
				}
				if toggled {
					result.Toggled = i
				}
			}
			if rest := len(rows) - last; rest > 0 {
				f.Row().Height(float32(rest) * RowHeight).Shrink(0)
			}
		})
	})
	return result
}

// visible is the range of rows to declare: the rows in view and overscan more at either end.
// Before the area's first layout the view's height is not known, and a tall one is assumed.
func (l List) visible(view *ui.View, n int) (int, int) {
	scroll := view.ScrollState(l.Scroll)
	height := scroll.Viewport
	if height <= 0 {
		height = 500
	}
	first := max(0, int(max(0, scroll.Offset-PadY)/RowHeight)-overscan)
	last := min(n, int((scroll.Offset+height)/RowHeight)+overscan+1)
	return min(first, last), last
}

// row declares one row: its highlight, its arrow or the room of one, and its content. It
// reports whether the row was clicked and whether its arrow was.
func (l List) row(f *ui.Frame, r Row, i int, selected, focused bool, o Options, look palette, content func(int)) (bool, bool) {
	options := gfx.HitOptions{Role: gfx.RoleOption, Selected: selected, Expandable: r.Branch, Expanded: r.Branch && r.Expanded, Level: uint8(min(r.Depth+1, 255))}
	row := f.Row().Height(RowHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(Gap).
		MarginSides(0, Gutter, 0, Gutter).Radius(Radius).
		PadSides(0, Trailing, 0, float32(r.Depth*Indent)).
		HitWith(l.Rows.At(r.Key), r.Label, options).
		Pressed(ui.Look{}.Background(look.focused))
	if selected {
		color := look.inactive
		if focused {
			color = look.focused
		}
		row = row.Background(color)
	} else {
		row = row.Hover(ui.Look{}.Background(look.hover))
	}
	toggled := false
	row.Children(func() {
		if !r.Branch {
			f.Row().Size(Disclosure, Disclosure).Shrink(0)
		} else {
			label := o.Expand
			if r.Expanded {
				label = o.Collapse
			}
			arrow := f.Row().Size(Disclosure, Icon).Shrink(0).Items(ui.Center).
				HitWith(l.Arrows.At(r.Key), label+" "+r.Label, gfx.HitOptions{Role: gfx.RoleButton})
			arrow.Children(func() { f.Icon(fileicons.TreeChevron(r.Expanded, o.Dark)).Size(Icon, Icon) })
			toggled = arrow.Clicked()
		}
		content(i)
	})
	return row.Clicked(), toggled
}

// Key reads a key pressed while a row or an arrow of the list has the keyboard: the arrow
// keys, Home, End and the page keys move and open as a desktop tree does, and Enter
// activates. current is the index of the selected row; when it is -1, as when the selection
// is inside a closed branch, the row with the keyboard is used. Key returns what to do and the
// index of the row to do it to; false says the key is not the list's. It scrolls a row it
// selects into view.
func (l List) Key(event gfx.KeyEvent, view *ui.View, rows []Row, current int) (Action, int, bool) {
	if event.Release || event.Modifiers != 0 {
		return None, -1, false
	}
	key, ok := event.Target.In(l.Rows)
	if !ok {
		key, ok = event.Target.In(l.Arrows)
	}
	if !ok {
		return None, -1, false
	}
	if current < 0 || current >= len(rows) {
		if current = Index(rows, key); current < 0 {
			return None, -1, false
		}
	}
	if event.Key == gfx.KeyEnter {
		return Activate, current, true
	}
	items := make([]components.TreeNavigationItem, len(rows))
	for i, r := range rows {
		items[i] = components.TreeNavigationItem{Depth: uint8(min(r.Depth, 255)), Branch: r.Branch, Expanded: r.Expanded}
	}
	page := 1
	if scroll := view.ScrollState(l.Scroll); scroll.Viewport > 0 {
		page = max(1, int(scroll.Viewport/RowHeight))
	}
	next, action, handled := components.NavigateTree(items, current, event.Key, page)
	switch {
	case !handled:
		return None, -1, false
	case action == components.TreeNavigationMove:
		l.Reveal(view, next)
		return Select, next, true
	case action == components.TreeNavigationExpand:
		return Expand, current, true
	case action == components.TreeNavigationCollapse:
		return Collapse, current, true
	}
	return None, current, true
}

// DoubleClicked reports the key of the row a primary press with no modifier held lands on
// when it is the second press of a double click. The caller opens or closes the row and
// handles the event, so the release that follows does not act on the row again.
func (l List) DoubleClicked(event gfx.PointerEvent) (int, bool) {
	if event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonPrimary || event.Modifiers != 0 || event.ClickCount != 2 {
		return 0, false
	}
	return event.Target.In(l.Rows)
}

// Index is the index of the row with key, and -1 when no row has it.
func Index(rows []Row, key int) int {
	for i, r := range rows {
		if r.Key == key {
			return i
		}
	}
	return -1
}

// Reveal scrolls the list as little as needed to show row i whole.
func (l List) Reveal(view *ui.View, i int) {
	scroll := view.ScrollState(l.Scroll)
	top := RowTop(i)
	if top < scroll.Offset {
		scroll.ScrollTo(top)
	} else if bottom := top + RowHeight; bottom > scroll.Offset+scroll.Viewport {
		scroll.ScrollTo(bottom - scroll.Viewport)
	}
}

// Center scrolls row i to the middle of the view unless it is already in view whole, as
// locating an item does.
func (l List) Center(view *ui.View, i int) {
	scroll := view.ScrollState(l.Scroll)
	top := RowTop(i)
	if top >= scroll.Offset && top+RowHeight <= scroll.Offset+scroll.Viewport {
		return
	}
	scroll.ScrollTo(top - max(scroll.Viewport-RowHeight, 0)/2)
}

// TopRow is the index of the row at the top of the view, of n rows, and how far the view is
// scrolled into it; -1 when there are none. With ScrollToRow it keeps that row in place while
// rows above it are added or removed.
func (l List) TopRow(view *ui.View, n int) (int, float32) {
	if n == 0 {
		return -1, 0
	}
	offset := view.ScrollState(l.Scroll).Offset
	i := min(n-1, int(max(0, offset-PadY)/RowHeight))
	return i, offset - RowTop(i)
}

// ScrollToRow scrolls so the view starts offset pixels into row i.
func (l List) ScrollToRow(view *ui.View, i int, offset float32) {
	view.ScrollState(l.Scroll).ScrollTo(RowTop(i) + offset)
}
