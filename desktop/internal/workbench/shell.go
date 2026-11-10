package workbench

import (
	"math"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The fixed sizes of the workbench's chrome. The title bar, the stripes and the status
// bar are declared by other files with exactly these sizes; this file derives the room
// of the tool windows and of the editor from them, so the two must stay in step.
const (
	stripeWidth       = 40
	statusBarHeight   = 24
	panelHeaderHeight = 32
	rowHeight         = 24
)

// Sizes only the shell needs.
const (
	// shellSplitter is the thickness Viva gives a Splitter; the panels beside it are
	// measured with it taken off.
	shellSplitter = 8
	// shellPanelMin and shellPanelHeightMin are the least width and height of a tool
	// window; shellEditorMin and shellEditorHeightMin are the least width and height the
	// editor keeps while panels are open around it.
	shellPanelMin        = 160
	shellPanelHeightMin  = 96
	shellEditorMin       = 240
	shellEditorHeightMin = 120

	// The original macOS workbench starts the left tool column at 360 points.
	shellLeftDefault  = 360
	shellRightDefault = 320
	// shellBottomShare is the part of the main column's height the bottom area opens at
	// until the user drags it: about two fifths, which leaves a log or a terminal room for
	// a screenful of lines and keeps the tool windows above it usable in a small window,
	// where a fixed height would squeeze them. The share is taken of the height of each
	// frame, so the area grows and shrinks with the window until it is dragged.
	shellBottomShare = 0.42
	// shellColumnLowerDefault is the height of the lower tool window of the left or the
	// right column while both of its tool windows are open.
	shellColumnLowerDefault = 240

	// shellTabsHeaderHeight is the header of a tool window that carries tabs. A Viva Tabs
	// strip is always 36 high, whatever the box it sits in, so the header grows to hold it
	// instead of letting the strip hang out of a 32 high one.
	shellTabsHeaderHeight = 36
	shellHeaderGap        = 8
	shellHideSize         = 24
	shellIconSize         = 16
	shellContentPad       = 16
	// shellHintWidth is the widest the empty editor's hints grow.
	shellHintWidth = 320
)

// shellSplit names the six splitters of the workbench.
type shellSplit int

const (
	// shellSplitLeft sits between the left column and the editor.
	shellSplitLeft shellSplit = iota
	// shellSplitRight sits between the editor and the right column.
	shellSplitRight
	// shellSplitBottom sits between the top row and the bottom area.
	shellSplitBottom
	// shellSplitMid sits between the two tool windows of the bottom area.
	shellSplitMid
	// shellSplitLeftColumn sits between the two tool windows of the left column.
	shellSplitLeftColumn
	// shellSplitRightColumn sits between the two tool windows of the right column.
	shellSplitRightColumn
	shellSplitCount
)

// layoutState is how the workbench divides its window: the sizes the user chose for the
// tool windows and the splitters that change them.
//
// The tool windows on the right, at the bottom and the lower one of a column keep their
// size when the window is resized and the editor (or the upper tool window of the column)
// takes the difference, which is the reverse of what a Viva Splitter does with a size it
// is only handed. So the panel is given a fixed size, the editor fills what is left, and
// each splitter's Pos is only derived from that, before the frame is declared. Viva's
// own limits then never move a Pos, and the panes follow a resize in the frame it
// happens in.
//
// The chosen sizes change only when the user drags or keys a splitter. What is shown
// is the chosen size limited to the room there is (see arrange); the limit is never
// written back, so a window made small and large again gets the panels it had.
type layoutState struct {
	// left, right and bottom are the chosen width of the left column, the chosen width
	// of the right one and the chosen height of the bottom area.
	left, right, bottom float32
	// leftLower and rightLower are the chosen heights of the lower tool window of the
	// left and of the right column. They only count while both tool windows of the
	// column are open; the upper one takes what is left, as the editor does.
	leftLower, rightLower float32
	// bottomShare is the share of the bottom area that the bottom left tool window
	// takes while both bottom tool windows are open. The two halves are peers, so they
	// share a resize instead of one of them absorbing it.
	bottomShare float32
	// gitTab is the selected tab of the Git tool window, one of the gitTab constants.
	gitTab int
	// gitLabels keeps the tab labels alive for the frame; Viva holds the slice until End.
	gitLabels [3]string

	split [shellSplitCount]ui.SplitterState

	// frame is what the last paint declared the workbench with, which a drag or a key press
	// is measured against. drawn says the workbench was declared since capture last ran.
	frame shellPlan
	drawn bool
	// insetW and insetH are the window's width and height less the main column's: the
	// stripes at both sides, the title bar and the status bar.
	insetW, insetH   float32
	windowW, windowH float32
	// mainRect is where the main column was laid out in the last paint, read by mainHook.
	mainRect gfx.Rect
	mainHook func(*ui.DrawContext)
}

func newLayoutState() layoutState {
	return layoutState{
		left:       shellLeftDefault,
		right:      shellRightDefault,
		leftLower:  shellColumnLowerDefault,
		rightLower: shellColumnLowerDefault,
		// bottom is 0 until the user drags the bottom splitter: see bottomFor.
		bottomShare: 0.5,
		insetW:      2 * stripeWidth,
		insetH:      titleBarHeight + statusBarHeight,
	}
}

// bottomFor is the height the bottom area asks for in a main column height high: the height
// the user dragged it to or, until they do, its share of the column.
func (l *layoutState) bottomFor(height float32) float32 {
	if l.bottom > 0 {
		return l.bottom
	}
	return shellSnap(height * shellBottomShare)
}

// shellPlan is one frame's division of the main column, in whole pixels.
type shellPlan struct {
	// width and height are the room of the main column.
	width, height float32
	// leftTop, leftBottom, rightTop, rightBottom, bottomLeft and bottomRight say which
	// slots have a tool window open.
	leftTop, leftBottom, rightTop, rightBottom, bottomLeft, bottomRight bool
	// leftW, rightW and bottomH are the sizes the panels get after the limits.
	leftW, rightW, bottomH float32
	// editorW and topH are the editor's width and the top row's height, which are the
	// panes the right and the bottom splitter measure from. topMin is the least height
	// the top row keeps while the bottom area is open.
	editorW, topH, topMin float32
	// leftUpperH and leftLowerH are the heights of the two tool windows of the left
	// column while both are open, rightUpperH and rightLowerH those of the right column.
	// The upper one is the pane before the column's splitter, so its height is the Pos.
	leftUpperH, leftLowerH, rightUpperH, rightLowerH float32
	// bottomRoom is the width the two bottom tool windows share, and bottomLeftW the
	// part the left one takes.
	bottomRoom, bottomLeftW float32
}

// left and right say that the column beside the editor is open: it takes its width when
// either of its slots has a tool window open, and shows both when both do.
func (p shellPlan) left() bool  { return p.leftTop || p.leftBottom }
func (p shellPlan) right() bool { return p.rightTop || p.rightBottom }

func (p shellPlan) bottom() bool { return p.bottomLeft || p.bottomRight }

// leftSplit and rightSplit say that a column holds two tool windows, one over the other.
func (p shellPlan) leftSplit() bool  { return p.leftTop && p.leftBottom }
func (p shellPlan) rightSplit() bool { return p.rightTop && p.rightBottom }

// pos is the position a splitter is declared at: the size of the pane before it.
func (p shellPlan) pos(which shellSplit) float32 {
	switch which {
	case shellSplitLeft:
		return p.leftW
	case shellSplitRight:
		return p.editorW
	case shellSplitBottom:
		return p.topH
	case shellSplitLeftColumn:
		return p.leftUpperH
	case shellSplitRightColumn:
		return p.rightUpperH
	}
	return p.bottomLeftW
}

// arrange divides the window for the tool windows open in open (a catalog index, or -1,
// per slot) and puts every splitter at the position that division gives.
//
// The sizes are floored to whole pixels and the panels limited so that the editor and
// the other panels keep their least size. Both matter: Viva clamps a Pos that lies
// outside the limits it measures from the laid out panes and asks for another frame, so
// a Pos even a fraction too large would repaint forever. The panes that are given a size
// are exact, and the one that fills is never smaller than the Pos assumes.
//
// A column beside the editor is open when either of its two slots has a tool window
// open, and then it takes the whole width L or R of the column; when both slots do, the
// column holds the two tool windows one over the other. Left of the editor, a column of
// width L has Pos = L. Right of it, the editor is the pane before the splitter, so
// Pos = room - L - R. In the bottom area the top row is the pane before the splitter, so
// Pos = height - 8 - B. In a column that holds two tool windows the upper one is the
// pane before the splitter, so Pos = top row height - 8 - LL for the left column and
// - RL for the right one, where LL and RL are the heights of the lower tool windows.
// The limits are:
//
//	L:  160 .. room - 240 - (160 if the right column is open)
//	R:  160 .. room - 240 - L
//	B:  96  .. height - 8 - T
//	LL: 96  .. top row height - 8 - 96
//	RL: 96  .. top row height - 8 - 96
//
// where room is the width less the splitters and T is the least height of the top row:
// 120, or 96 + 8 + 96 when a column is split, so that the column's own limits never
// cross. The left column is limited first, so a window too small for everything gives
// the right column the less.
func (l *layoutState) arrange(window gfx.Rect, open [slotCount]int) shellPlan {
	l.windowW, l.windowH = window.Width, window.Height
	p := shellPlan{
		width:       shellFloor(window.Width - l.insetW),
		height:      shellFloor(window.Height - l.insetH),
		leftTop:     open[slotLeftTop] >= 0,
		leftBottom:  open[slotLeftBottom] >= 0,
		rightTop:    open[slotRightTop] >= 0,
		rightBottom: open[slotRightBottom] >= 0,
		bottomLeft:  open[slotBottomLeft] >= 0,
		bottomRight: open[slotBottomRight] >= 0,
	}
	p.topMin = shellEditorHeightMin
	if p.leftSplit() || p.rightSplit() {
		p.topMin = max(p.topMin, 2*shellPanelHeightMin+shellSplitter)
	}
	p.topH = p.height
	if p.bottom() {
		p.bottomH = shellSnap(shellClamp(l.bottomFor(p.height), shellPanelHeightMin, p.height-shellSplitter-p.topMin))
		p.topH = p.height - shellSplitter - p.bottomH
	}

	// The lower tool window of a split column is the one that keeps its chosen height;
	// the upper one fills what is left, as the editor does.
	if p.leftSplit() {
		p.leftLowerH = shellSnap(shellClamp(l.leftLower, shellPanelHeightMin, p.topH-shellSplitter-shellPanelHeightMin))
		p.leftUpperH = p.topH - shellSplitter - p.leftLowerH
	}
	if p.rightSplit() {
		p.rightLowerH = shellSnap(shellClamp(l.rightLower, shellPanelHeightMin, p.topH-shellSplitter-shellPanelHeightMin))
		p.rightUpperH = p.topH - shellSplitter - p.rightLowerH
	}

	room := p.width
	if p.left() {
		room -= shellSplitter
	}
	if p.right() {
		room -= shellSplitter
	}
	if p.left() {
		keep := float32(shellEditorMin)
		if p.right() {
			keep += shellPanelMin
		}
		p.leftW = shellSnap(shellClamp(l.left, shellPanelMin, room-keep))
	}
	if p.right() {
		p.rightW = shellSnap(shellClamp(l.right, shellPanelMin, room-shellEditorMin-p.leftW))
	}
	p.editorW = room - p.leftW - p.rightW

	// The bottom halves: the left one takes its share of the room, the right one fills.
	// The share is limited so that neither goes under the least width.
	if p.bottomLeft && p.bottomRight {
		p.bottomRoom = p.width - shellSplitter
		p.bottomLeftW = shellSnap(shellClamp(shellSnap(l.bottomShare*p.bottomRoom), shellPanelMin, p.bottomRoom-shellPanelMin))
	}

	for which := range l.split {
		l.split[which].Pos = p.pos(shellSplit(which))
	}
	l.frame, l.drawn = p, true
	return p
}

// capture keeps what the paint before this one tells: the sizes a drag chose.
//
// A position counts as the user's only while the splitter is being dragged and has moved
// from where it was declared. Anything else that moved it would be Viva keeping it
// inside limits, which says nothing about what the user wants and must not be
// remembered. It runs at the start of a paint, before arrange puts every splitter back
// at the position the chosen sizes give.
func (l *layoutState) capture() {
	if !l.drawn {
		return
	}
	l.drawn = false
	for which := range l.split {
		if s := &l.split[which]; s.Dragging() && s.Pos != l.frame.pos(shellSplit(which)) {
			l.adopt(shellSplit(which))
		}
	}
}

// key gives a key press to the splitters; only the one that has the keyboard focus acts
// on it, and its answer is the answer. An arrow key moves a splitter by a step the
// frame has not been drawn with yet, so the new position is remembered at once.
func (l *layoutState) key(event gfx.KeyEvent) gfx.EventResult {
	for which := range l.split {
		if result := l.split[which].Key(event); result.Handled {
			l.adopt(shellSplit(which))
			return result
		}
	}
	return gfx.EventResult{}
}

// adopt remembers the position of a splitter as the size it stands for, measured against
// the sizes the last frame was declared with. A panel after its splitter gets what the
// pane before it leaves of their sum.
func (l *layoutState) adopt(which shellSplit) {
	pos := shellSnap(l.split[which].Pos)
	p := &l.frame
	switch which {
	case shellSplitLeft:
		l.left = pos
	case shellSplitRight:
		l.right = p.editorW + p.rightW - pos
	case shellSplitBottom:
		l.bottom = p.topH + p.bottomH - pos
	case shellSplitLeftColumn:
		l.leftLower = p.leftUpperH + p.leftLowerH - pos
	case shellSplitRightColumn:
		l.rightLower = p.rightUpperH + p.rightLowerH - pos
	case shellSplitMid:
		if p.bottomRoom > 0 {
			l.bottomShare = shellClamp(pos/p.bottomRoom, 0, 1)
		}
	}
}

func shellClamp(v, lo, hi float32) float32 { return max(min(v, hi), lo) }
func shellSnap(v float32) float32          { return float32(math.Round(float64(v))) }
func shellFloor(v float32) float32         { return float32(math.Floor(float64(v))) }
