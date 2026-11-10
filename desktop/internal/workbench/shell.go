package workbench

import (
	"math"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
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

var (
	shellSplitIDs = [shellSplitCount]gfx.ID{
		shellSplitLeft:        tree.ID(shellPage, "split-left"),
		shellSplitRight:       tree.ID(shellPage, "split-right"),
		shellSplitBottom:      tree.ID(shellPage, "split-bottom"),
		shellSplitMid:         tree.ID(shellPage, "split-bottom-mid"),
		shellSplitLeftColumn:  tree.ID(shellPage, "split-left-column"),
		shellSplitRightColumn: tree.ID(shellPage, "split-right-column"),
	}
	// shellGitTabs identifies the tabs of the Git tool window.
	shellGitTabs = tree.Sub(shellPage, tree.Name("git-tabs"))
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
	// gitTab is the selected tab of the Git tool window.
	gitTab int
	// gitLabels keeps the tab labels alive for the frame; Viva holds the slice until End.
	gitLabels [3]string

	split [shellSplitCount]ui.SplitterState

	// frame is what the last drawWorkbench declared, which a drag or a key press is
	// measured against. drawn says the workbench was declared since capture last ran.
	frame shellPlan
	drawn bool
	// main is the column between the stripes in the frame being drawn. The room it was
	// given in the last frame tells how much of the window the chrome around it takes,
	// so the panels are sized against the room that is really there.
	main ui.Box
	// insetW and insetH are the window's width and height less the main column's.
	insetW, insetH   float32
	windowW, windowH float32
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

// capture keeps what the frame that just finished tells: the sizes a drag chose and the
// room the chrome around the main column takes.
//
// A position counts as the user's only while the splitter is being dragged and has moved
// from where it was declared. Anything else that moved it would be Viva keeping it
// inside limits, which says nothing about what the user wants and must not be
// remembered.
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
	if r := l.main.Rect(); r.Width > 0 && r.Height > 0 {
		l.insetW, l.insetH = l.windowW-r.Width, l.windowH-r.Height
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

// drawWorkbench is the window of an open project: the title bar over the tool stripes
// and the main column, over the status bar. The main column holds the tool windows
// around the editor, and the bottom area under them when a bottom tool window is open.
func (a *App) drawWorkbench(f *ui.Frame) {
	// A copy: a click on a stripe button changes a.chrome while this frame is still being
	// declared, and the panels must be declared for the same tool windows the sizes were
	// worked out for.
	open := a.chrome.open
	plan := a.layout.arrange(f.Bounds(), open)
	// The hide button is only noted while the frame is declared and acted on at its end,
	// so the stripes and the status bar are declared with the same state as the panels.
	hidden := slotCount
	f.Column().Fill().Children(func() {
		a.drawTitleBar(f)
		f.Row().Fill().Children(func() {
			a.drawStripe(f, true)
			a.layout.main = f.Column().Fill().Children(func() {
				a.drawShellMain(f, plan, open, &hidden)
			})
			a.drawStripe(f, false)
		})
		a.drawStatusBar(f)
	})
	a.drawBranchDialog(f)
	a.drawSyncDialog(f)
	if hidden != slotCount {
		a.hidePanel(hidden)
	}
}

// drawShellMain declares the top row, which holds the editor and the columns of tool
// windows at its sides, and under it the bottom area when a bottom tool window is open.
// The columns and the panels have fixed sizes and the editor and the top row fill what is
// left; each splitter is declared right after the pane its Pos measures and before the
// next one.
func (a *App) drawShellMain(f *ui.Frame, plan shellPlan, open [slotCount]int, hidden *slot) {
	f.Row().Fill().Children(func() {
		if plan.left() {
			a.drawShellColumn(f, open, hidden, slotLeftTop, slotLeftBottom, shellSplitLeftColumn, plan.leftUpperH).Width(plan.leftW).Shrink(0)
			a.drawShellSplitter(f, shellSplitLeft).Mins(shellPanelMin, shellEditorMin)
		}
		a.drawShellEditor(f)
		if plan.right() {
			a.drawShellSplitter(f, shellSplitRight).Mins(shellEditorMin, shellPanelMin)
			a.drawShellColumn(f, open, hidden, slotRightTop, slotRightBottom, shellSplitRightColumn, plan.rightUpperH).Width(plan.rightW).Shrink(0)
		}
	})
	if !plan.bottom() {
		return
	}
	a.drawShellSplitter(f, shellSplitBottom).Mins(plan.topMin, shellPanelHeightMin)
	f.Row().Height(plan.bottomH).Children(func() {
		switch {
		case plan.bottomLeft && plan.bottomRight:
			a.drawShellPanel(f, slotBottomLeft, open[slotBottomLeft], hidden).Width(plan.bottomLeftW).Shrink(0)
			a.drawShellSplitter(f, shellSplitMid).Mins(shellPanelMin, shellPanelMin)
			a.drawShellPanel(f, slotBottomRight, open[slotBottomRight], hidden).Fill()
		case plan.bottomLeft:
			a.drawShellPanel(f, slotBottomLeft, open[slotBottomLeft], hidden).Fill()
		default:
			a.drawShellPanel(f, slotBottomRight, open[slotBottomRight], hidden).Fill()
		}
	})
}

// drawShellColumn declares a column of tool windows beside the editor, which is the left
// or the right one depending on its slots. A column with one tool window open shows it
// over the whole height; with both open it shows the upper one (the top slot) over the
// lower one (the bottom slot), the upper one upperH high and the lower one filling, with
// the column's splitter between them. The caller gives the column its width. The splitter
// is declared right after the upper tool window, the pane its Pos measures.
func (a *App) drawShellColumn(f *ui.Frame, open [slotCount]int, hidden *slot, top, bottom slot, which shellSplit, upperH float32) ui.Box {
	return f.Column().Children(func() {
		switch {
		case open[top] >= 0 && open[bottom] >= 0:
			a.drawShellPanel(f, top, open[top], hidden).Height(upperH).Shrink(0)
			a.drawShellSplitter(f, which).Mins(shellPanelHeightMin, shellPanelHeightMin)
			a.drawShellPanel(f, bottom, open[bottom], hidden).Fill()
		case open[top] >= 0:
			a.drawShellPanel(f, top, open[top], hidden).Fill()
		default:
			a.drawShellPanel(f, bottom, open[bottom], hidden).Fill()
		}
	})
}

// drawShellSplitter declares one of the workbench's splitters. Its accessibility label
// is set because Viva's own is an English word that would ignore the chosen language.
func (a *App) drawShellSplitter(f *ui.Frame, which shellSplit) ui.Box {
	return f.Splitter(shellSplitIDs[which], &a.layout.split[which]).Label(a.text.Panel.Resize)
}

// drawShellPanel declares the tool window open in slot s, the catalog item index: a
// header with its name and a button that hides it, over a body. Most tool windows have no
// contents yet, so their body says so, in the middle. The Git tool window has more in its
// header, the tabs its views will be shown under, and a body of its own on the log tab; the
// Terminal tool window of an open project holds that project's terminals, one tab each in
// its header, and the body shows the selected one.
func (a *App) drawShellPanel(f *ui.Frame, s slot, index int, hidden *slot) ui.Box {
	tool := catalog[index]
	tabbed := tool.id == itemGit
	// The log tab of the Git tool window has its own body and adds buttons to the header.
	log := tabbed && a.layout.gitTab == 0 && a.project != nil
	// The Terminal tool window of an open project shows its terminals' tabs in its header.
	terminals := tool.id == itemTerminal && a.project != nil
	// The Commit tool window of an open project shows its changes and the commit area.
	commit := tool.id == itemCommit && a.project != nil
	// The Project tool window of an open project shows the tree of its folder.
	tree := tool.id == itemProject && a.project != nil
	search := tool.id == itemFind && a.project != nil
	// The Problems tool window of an open project lists what its servers published.
	problems := tool.id == itemProblems && a.project != nil
	// The Tests tool window runs one workspace test selection and shows its tree.
	tests := tool.id == itemTests && a.project != nil
	// The Debug tool window owns one adapter session, its breakpoints and stack.
	debug := tool.id == itemDebug && a.project != nil
	// The AI Assistant tool window holds the project's Agent conversation.
	assistant := tool.id == itemAssistant && a.project != nil
	header := float32(panelHeaderHeight)
	if tabbed {
		header = shellTabsHeaderHeight
	} else if search {
		header = 39
	}
	return f.Column().Background(a.colors.Panel).Clip().Children(func() {
		f.Row().Height(header).Items(ui.Center).Gap(shellHeaderGap).PadSides(0, 8, 0, 12).Children(func() {
			f.Text(tool.label(a.text)).Color(a.colors.Text).Weight(gfx.WeightMedium).Ellipsis()
			if tabbed {
				a.drawShellGitTabs(f)
			}
			if log {
				a.drawLogHeaderLeading(f, a.project)
			}
			if terminals {
				// The tabs of the open project's terminals take the room a spacer would.
				a.drawTerminalTabs(f)
			} else {
				f.Spacer()
			}
			if log {
				a.drawLogHeaderTrailing(f, a.project)
			}
			if search {
				a.drawSearchRefresh(f, a.project)
			}
			if tree {
				a.drawProjectTreeActions(f, a.project)
			}
			// A ui Button cannot show an icon in this version of Viva, so the hide
			// control is a hit row with an icon, as the notice's dismiss button is.
			hide := f.Row().Size(shellHideSize, shellHideSize).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
				HitWith(panelHide.At(int(s)), a.text.Panel.Hide, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
				Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
			hide.Children(func() {
				f.Icon(icons.Minus).Size(shellIconSize, shellIconSize).Color(a.colors.Subtle).StateFrom(hide).Hover(ui.Look{}.Color(a.colors.Text))
			})
			if hide.Clicked() {
				*hidden = s
			}
		})
		if log {
			a.drawGitLog(f, a.project)
			return
		}
		if terminals {
			a.drawTerminal(f)
			return
		}
		if commit {
			a.drawCommitPanel(f, a.project)
			return
		}
		if tree {
			a.drawProjectTree(f, a.project)
			return
		}
		if search {
			a.drawProjectSearch(f, a.project)
			return
		}
		if problems {
			a.drawProblemsPanel(f, a.project)
			return
		}
		if tool.id == itemRun {
			a.drawBuildPanel(f, a.project)
			return
		}
		if tests {
			a.drawTestsPanel(f, a.project)
			return
		}
		if debug {
			a.drawDebugPanel(f, a.project)
			return
		}
		if assistant {
			a.drawAgentPanel(f, a.project)
			return
		}
		f.Row().Fill().Items(ui.Center).PadX(shellContentPad).Children(func() {
			f.Paragraph(a.text.Panel.Placeholder, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
		})
	})
}

// toolIconButton declares an icon button of a tool window and reports a click on it. on
// shows it pressed, for the buttons that toggle a view; a disabled one is dimmed and takes no
// click. out, when not nil, receives the button's box, for a popover to hang from. A ui
// Button cannot show an icon in this version of Viva, so the button is a hit row with one;
// a box's Disabled dims only what it draws, so the hit says it is disabled itself.
func (a *App) toolIconButton(f *ui.Frame, id gfx.ID, label string, icon gfx.Icon, on, disabled bool, out *ui.Box) bool {
	button := f.Row().Size(shellHideSize, shellHideSize).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
		HitWith(id, label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Disabled: disabled}).Disabled(disabled)
	switch {
	case on:
		button = button.Background(a.colors.Active)
	case !disabled:
		button = button.Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
	}
	tint := a.colors.Subtle
	if disabled {
		tint.Alpha *= 0.4
	}
	button.Children(func() {
		f.Icon(icon).Size(shellIconSize, shellIconSize).Color(tint).StateFrom(button).Hover(ui.Look{}.Color(a.colors.Text))
	})
	if out != nil {
		*out = button
	}
	return !disabled && button.Clicked()
}

// drawShellGitTabs declares the tabs of the Git tool window's header and takes a click
// on one as the new selection. The strip may give up width, with the labels cut, before
// it pushes the hide button out of a narrow panel.
func (a *App) drawShellGitTabs(f *ui.Frame) {
	l := &a.layout
	l.gitLabels = [3]string{a.text.Git.Log, a.text.Git.Worktrees, a.text.Git.Console}
	if p := a.project; p != nil && p.log.reference != "" {
		l.gitLabels[0] = a.text.Git.LogTab(p.log.referenceLabel)
	}
	tabs := f.Tabs(shellGitTabs, l.gitLabels[:], l.gitTab).Line().Height(shellTabsHeaderHeight).Shrink(1)
	if i, ok := tabs.TabClicked(); ok {
		l.gitTab = i
	}
}

// drawShellEditor declares the editor area. Once a terminal has been dragged into it, it is
// the groups of tabs those terminals are in (see drawEditorGroups). Until then there is no
// editor, so it shows what an empty one shows: the commands that open something and where
// to drop files, which is also where a dragged tab opens the first group. The shortcuts are
// key symbols, not words, and so are not translated.
func (a *App) drawShellEditor(f *ui.Frame) {
	if a.drawEditorGroups(f) {
		return
	}
	hints := [...]struct{ label, keys string }{
		{a.text.Editor.SearchEverywhere, "⇧⇧"},
		{a.text.Editor.GoToFile, "⇧⌘O"},
		{a.text.Editor.FindInFiles, "⇧⌘F"},
		{a.text.Editor.RecentFiles, "⌘E"},
	}
	editor := f.Column().Fill().Clip().Center().Pad(shellContentPad).Background(a.colors.Editor).Children(func() {
		f.Column().FillWidth().MaxWidth(shellHintWidth).Children(func() {
			// Labels end and shortcuts start at one line down the middle, so the two
			// read as columns however long the words are.
			for _, hint := range hints {
				f.Row().Height(rowHeight).Items(ui.Center).Gap(12).Children(func() {
					f.Text(hint.label).Color(a.colors.Subtle).TextEnd().Ellipsis().FillWidth()
					f.Text(hint.keys).Color(a.colors.Text).FillWidth()
				})
			}
			f.Row().Height(rowHeight).Items(ui.Center).Children(func() {
				f.Text(a.text.Editor.DropFiles).Color(a.colors.Subtle).TextCenter().Ellipsis().FillWidth()
			})
		})
	})
	a.declareEmptyEditor(editor)
}
