package workbench

import (
	"context"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// debugBreakpoint is one source breakpoint of a file. The line is one-based. A condition
// stops only when the expression holds, a hit condition stops on a count, and a log
// message turns the breakpoint into a log point that prints instead of stopping. Core
// validates none of them: the adapter decides what it supports.
type debugBreakpoint struct {
	line         int64
	condition    string
	hitCondition string
	logMessage   string
}

// debugBreakpointEdit is the open breakpoint editor: the breakpoint it edits and the
// text the user is changing. The edit is applied only on Save.
type debugBreakpointEdit struct {
	open         bool
	path         string
	line         int64
	condition    string
	hitCondition string
	logMessage   string
}

// breakpointIndex finds where line sits in the sorted breakpoints of one file.
func breakpointIndex(lines []debugBreakpoint, line int64) (int, bool) {
	index := sort.Search(len(lines), func(i int) bool { return lines[i].line >= line })
	return index, index < len(lines) && lines[index].line == line
}

// sourceBreakpoints is the file's breakpoints in the form Core sends to the adapter.
func sourceBreakpoints(lines []debugBreakpoint) []core.DebugSourceBreakpoint {
	points := make([]core.DebugSourceBreakpoint, 0, len(lines))
	for _, line := range lines {
		points = append(points, core.DebugSourceBreakpoint{
			Line:         line.line,
			Enabled:      true,
			Condition:    line.condition,
			HitCondition: line.hitCondition,
			LogMessage:   line.logMessage,
		})
	}
	return points
}

// breakpointMarker is the short mark a row shows for the options a breakpoint carries.
func breakpointMarker(line debugBreakpoint, conditional, logPoint string) string {
	var marks []string
	if line.condition != "" || line.hitCondition != "" {
		marks = append(marks, conditional)
	}
	if line.logMessage != "" {
		marks = append(marks, logPoint)
	}
	return strings.Join(marks, " ")
}

// openBreakpointEdit opens the editor on one breakpoint, copying its current options.
func (a *App) openBreakpointEdit(p *project, path string, line int64) {
	lines := p.debug.breakpoints[path]
	index, found := breakpointIndex(lines, line)
	if !found {
		return
	}
	current := lines[index]
	p.debug.breakpointEdit = debugBreakpointEdit{
		open:         true,
		path:         path,
		line:         line,
		condition:    current.condition,
		hitCondition: current.hitCondition,
		logMessage:   current.logMessage,
	}
}

// saveBreakpointEdit stores the edited options and, with a session, sends the file's
// breakpoints to the adapter again. A breakpoint removed while the editor was open is
// left alone.
func (a *App) saveBreakpointEdit(p *project) {
	edit := p.debug.breakpointEdit
	p.debug.breakpointEdit = debugBreakpointEdit{}
	lines := p.debug.breakpoints[edit.path]
	index, found := breakpointIndex(lines, edit.line)
	if !found {
		return
	}
	lines[index].condition = strings.TrimSpace(edit.condition)
	lines[index].hitCondition = strings.TrimSpace(edit.hitCondition)
	lines[index].logMessage = strings.TrimSpace(edit.logMessage)
	if p.debug.session != nil {
		a.sendDebugBreakpoints(p, edit.path)
	}
}

// debugBreakpointEditor declares the breakpoint editor modal while it is open.
func (a *App) debugBreakpointEditor(c ui.C, p *project) {
	edit := &p.debug.breakpointEdit
	if !edit.open {
		return
	}
	t := a.text.Debug.Breakpoint
	open := true
	title := t.Title(debugFileName(edit.path), strconv.FormatInt(edit.line, 10))
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 460}, func() {
		ui.Column(c.Part("breakpoint-editor")).FillWidth().Gap(10).Children(func() {
			ui.TextField(c.Part("condition"), &edit.condition, t.Condition, t.ConditionPlaceholder).FillWidth()
			ui.TextField(c.Part("hit-condition"), &edit.hitCondition, t.HitCondition, t.HitConditionPlaceholder).FillWidth()
			ui.TextField(c.Part("log-message"), &edit.logMessage, t.LogMessage, t.LogMessagePlaceholder).FillWidth()
		})
	}, func() {
		if ui.Button(c, t.Cancel).Outline().Clicked() {
			c.After(func() { p.debug.breakpointEdit = debugBreakpointEdit{} })
		}
		if ui.Button(c, t.Save).Clicked() {
			c.After(func() { a.saveBreakpointEdit(p) })
		}
	})
	if closed || !open {
		c.After(func() { p.debug.breakpointEdit = debugBreakpointEdit{} })
	}
}

// addFunctionBreakpoint adds the typed method name. A duplicate or an empty name changes
// nothing; with a session the full set goes to the adapter again.
func (a *App) addFunctionBreakpoint(p *project) {
	name := strings.TrimSpace(p.debug.functionName)
	p.debug.functionName = ""
	if name == "" {
		return
	}
	for _, existing := range p.debug.functionBreakpoints {
		if existing.Name == name {
			return
		}
	}
	p.debug.functionBreakpoints = append(p.debug.functionBreakpoints, core.DebugFunctionBreakpoint{Name: name, Enabled: true})
	a.sendFunctionBreakpoints(p)
}

// removeFunctionBreakpoint drops one named breakpoint and tells the active adapter.
func (a *App) removeFunctionBreakpoint(p *project, index int) {
	if index < 0 || index >= len(p.debug.functionBreakpoints) {
		return
	}
	p.debug.functionBreakpoints = slices.Delete(p.debug.functionBreakpoints, index, index+1)
	a.sendFunctionBreakpoints(p)
}

// sendFunctionBreakpoints replaces the session's function breakpoints; without a session
// they are sent at launch instead.
func (a *App) sendFunctionBreakpoints(p *project) {
	if p == nil || p.debug.session == nil {
		return
	}
	session := p.debug.session
	breakpoints := slices.Clone(p.debug.functionBreakpoints)
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.SetDebugFunctionBreakpoints(ctx, session.id, breakpoints)
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}

// debugFunctionBreakpoints declares the name field and the list of method breakpoints. A row
// removes its breakpoint when clicked.
func (a *App) debugFunctionBreakpoints(c ui.C, p *project) {
	t := a.text.Debug.Breakpoint
	ui.Row(c).FillWidth().Height(debugRowHeight + 4).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		ui.TextField(c.Part("function-name"), &p.debug.functionName, t.FunctionName, t.FunctionPlaceholder).Grow(1)
		if ui.Button(c.Part("add-function"), t.AddFunction).Outline().Disabled(strings.TrimSpace(p.debug.functionName) == "").Clicked() {
			c.After(func() { a.addFunctionBreakpoint(p) })
		}
	})
	for index, breakpoint := range p.debug.functionBreakpoints {
		index, name := index, breakpoint.Name
		ui.Row(c).FillWidth().Height(debugRowHeight).Shrink(0).PadX(8).Items(ui.Center).Children(func() {
			if ui.Button(c.Key("function-"+strconv.Itoa(index)), t.FunctionRow(name)).Small().Outline().Tooltip(t.RemoveFunction).Clicked() {
				c.After(func() { a.removeFunctionBreakpoint(p, index) })
			}
		})
	}
}

// toggleInstructionBreakpoint adds or removes the breakpoint on one instruction address, then
// sends the full set to the adapter when there is a session. Breakpoints of an earlier process
// are never replayed: their addresses are valid for one run only.
func (a *App) toggleInstructionBreakpoint(p *project, reference string) {
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return
	}
	breakpoints := p.debug.instructionBreakpoints
	index := slices.IndexFunc(breakpoints, func(b core.DebugInstructionBreakpoint) bool {
		return b.InstructionReference == reference
	})
	if index >= 0 {
		p.debug.instructionBreakpoints = slices.Delete(breakpoints, index, index+1)
	} else {
		p.debug.instructionBreakpoints = append(breakpoints, core.DebugInstructionBreakpoint{InstructionReference: reference, Enabled: true})
	}
	if p.debug.session != nil {
		a.sendInstructionBreakpoints(p)
	}
}

// sendInstructionBreakpoints replaces the session's instruction breakpoints.
func (a *App) sendInstructionBreakpoints(p *project) {
	if p == nil || p.debug.session == nil {
		return
	}
	session := p.debug.session
	breakpoints := slices.Clone(p.debug.instructionBreakpoints)
	a.background(p, debugOperationTimeout, func(ctx context.Context) func(*App) {
		session.operationMu.Lock()
		defer session.operationMu.Unlock()
		if session.stopped.Load() {
			return nil
		}
		update, err := a.kernel.SetDebugInstructionBreakpoints(ctx, session.id, breakpoints)
		if err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		if err := session.writeFrames(update.OutboundFrames); err != nil {
			return func(a *App) { a.finishDebugError(p, session, err) }
		}
		a.postDebugUpdate(p, session, update)
		return nil
	})
}
