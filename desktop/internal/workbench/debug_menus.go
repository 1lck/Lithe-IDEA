package workbench

import (
	"path/filepath"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The context menus of the Debug tool window, with the items the earlier client's debugger
// had: the thread picker copies the thread's name; a stack frame copies its method name, its
// instruction address and its source location, and shows its disassembly; a variable is given
// a new value, watched or copied; a watch is evaluated again, copied or removed; a line
// breakpoint is edited, shown in its file or removed, alone or with the others. Each item acts
// through the action the panel's own controls run.

// debugVarMenu is the open context menu of one row of the variables tree. A tree row is
// painted by the tree, so its menu is opened from the right-click on the row and declared
// after the tree.
type debugVarMenu struct {
	open bool
	at   ui.Rect
	node *debugVarNode
}

// copyDebugText puts one value the debugger shows on the clipboard.
func (a *App) copyDebugText(action, text string) {
	a.performed(action, surfaceMenu)
	_ = app.SetClipboardText(text)
}

// debugThreadMenu is the menu of the row of the thread picker: it copies the selected thread's
// name.
func (a *App) debugThreadMenu(c ui.C, picker ui.Box, p *project) {
	ui.ContextMenu(c, picker, func(menu *ui.MenuItems) {
		menu.WidthRange(160, 240)
		thread := threadIndexOf(p.debug.threads, p.debug.selectedThread)
		if thread >= len(p.debug.threads) {
			return
		}
		name := p.debug.threads[thread].Name
		if menu.Item(i18n.Shared(a.language(), "native.copyThreadName")).Disabled(name == "").Clicked() {
			c.After(func() { a.copyDebugText("debug.thread.copyName", name) })
		}
	})
}

// debugFrameMenu is the menu of the stack frame at index.
func (a *App) debugFrameMenu(c ui.C, row ui.Box, p *project, index int) {
	ui.ContextMenu(c, row, func(menu *ui.MenuItems) {
		d := &p.debug
		if index >= len(d.frames) {
			return
		}
		lang := a.language()
		frame := d.frames[index]
		menu.WidthRange(180, 260)
		if menu.Item(i18n.Shared(lang, "native.copyMethodName")).Clicked() {
			c.After(func() { a.copyDebugText("debug.frame.copyName", frame.Name) })
		}
		if address := frame.InstructionPointerReference; address != "" {
			if menu.Item(i18n.Shared(lang, "debugger.disassembly.copyAddress")).Clicked() {
				c.After(func() { a.copyDebugText("debug.frame.copyAddress", address) })
			}
			if d.capabilities != nil && d.capabilities.SupportsDisassembleRequest &&
				menu.Item(i18n.Shared(lang, "debugger.disassembly.showDisassembly")).Disabled(d.state != "paused").Clicked() {
				c.After(func() { a.showFrameDisassembly(p, index) })
			}
		}
		if frame.SourcePath == "" {
			return
		}
		line, column := strconv.FormatInt(frame.Line, 10), strconv.FormatInt(frame.Column, 10)
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "native.copySourceLocation")).Clicked() {
			location := frame.SourcePath + ":" + line + ":" + column
			c.After(func() { a.copyDebugText("debug.frame.copyLocation", location) })
		}
		if menu.Item(i18n.Shared(lang, "native.copyRelativeLocation")).Clicked() {
			location := filepath.Base(frame.SourcePath) + ":" + line + ":" + column
			c.After(func() { a.copyDebugText("debug.frame.copyRelativeLocation", location) })
		}
	})
}

// showFrameDisassembly makes the frame at index current and shows the Disassembly section,
// which loads the code around that frame's instruction pointer.
func (a *App) showFrameDisassembly(p *project, index int) {
	a.performed("debug.frame.showDisassembly", surfaceMenu)
	if index != p.debug.vars.frame {
		a.selectDebugFrame(p, index)
	}
	p.debug.section = debugSectionDisassembly
}

// debugVariablePointer opens the menu of variable row i when the row is right-clicked.
func (a *App) debugVariablePointer(c ui.C, p *project, i int, node *debugVarNode) {
	v := &p.debug.vars
	canvas := c.Canvas()
	if node.moreFor != nil || canvas == nil {
		return
	}
	event, ok := canvas.PointerOn(v.tree.RowID(i))
	if !ok || event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonSecondary {
		return
	}
	canvas.Consume()
	v.menu = debugVarMenu{open: true, at: ui.Rect{X: event.X, Y: event.Y}, node: node}
}

// debugVariableMenu declares the menu of the variable right-clicked while it is open: Set
// Value selects the row, which shows the field that gives it a new value; Break on Field
// Access watches it; Add to Watches evaluates its expression at each stop.
func (a *App) debugVariableMenu(c ui.C, p *project) {
	d := &p.debug
	v := &d.vars
	if !v.menu.open {
		return
	}
	node := v.menu.node
	ui.MenuAt(c.Key("debug-var-menu"), v.menu.at.X, v.menu.at.Y, &v.menu.open, func(menu *ui.MenuItems) {
		lang := a.language()
		menu.WidthRange(180, 260)
		edits := canEditDebugVariable(d, node)
		if edits && menu.Item(i18n.Shared(lang, "native.setValue")).Clicked() {
			c.After(func() {
				a.performed("debug.variable.setValue", surfaceMenu)
				v.json, v.selected = false, node
			})
		}
		if !node.scope && node.parentRef > 0 && d.state == "paused" && d.capabilities != nil && d.capabilities.SupportsDataBreakpoints &&
			menu.Item(i18n.Shared(lang, "native.breakOnFieldAccess")).Clicked() {
			name, parent := node.name, node.parentRef
			c.After(func() {
				a.performed("debug.variable.breakOnAccess", surfaceMenu)
				a.requestDataBreakpoint(p, name, parent)
			})
		}
		if !node.scope {
			menu.Separator()
			if menu.Item(i18n.Shared(lang, "native.copyValue")).Clicked() {
				value := node.value
				c.After(func() { a.copyDebugText("debug.variable.copyValue", value) })
			}
			expression := node.evaluateName
			if expression == "" {
				expression = node.name
			}
			if menu.Item(i18n.Shared(lang, "native.copyExpression")).Clicked() {
				c.After(func() { a.copyDebugText("debug.variable.copyExpression", expression) })
			}
		}
		if menu.Item(i18n.Shared(lang, "native.copyName")).Clicked() {
			name := node.name
			c.After(func() { a.copyDebugText("debug.variable.copyName", name) })
		}
		if watched := node.evaluateName; !node.scope && watched != "" {
			menu.Separator()
			if menu.Item(i18n.Shared(lang, "native.addToWatches")).Disabled(d.state != "paused").Clicked() {
				c.After(func() {
					a.performed("debug.variable.addWatch", surfaceMenu)
					d.watch.input = watched
					a.addDebugWatch(p)
				})
			}
		}
	})
}

// debugWatchMenu is the menu of the watch at index.
func (a *App) debugWatchMenu(c ui.C, row ui.Box, p *project, index int) {
	ui.ContextMenu(c, row, func(menu *ui.MenuItems) {
		t, w := a.text.Debug, &p.debug.watch
		if index >= len(w.entries) {
			return
		}
		lang := a.language()
		entry := w.entries[index]
		menu.WidthRange(160, 240)
		if menu.Item(t.Reload).Clicked() {
			c.After(func() {
				a.performed("debug.watch.refresh", surfaceMenu)
				a.refreshDebugWatches(p)
			})
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "native.copyValue")).Disabled(entry.value == "").Clicked() {
			c.After(func() { a.copyDebugText("debug.watch.copyValue", entry.value) })
		}
		if menu.Item(i18n.Shared(lang, "native.copyExpression")).Clicked() {
			c.After(func() { a.copyDebugText("debug.watch.copyExpression", entry.expression) })
		}
		menu.Separator()
		if menu.Item(t.RemoveWatch).Clicked() {
			c.After(func() {
				a.performed("debug.watch.remove", surfaceMenu)
				a.removeDebugWatch(p, index)
			})
		}
	})
}

// debugBreakpointMenu is the menu of the line breakpoint in path at line.
func (a *App) debugBreakpointMenu(c ui.C, row ui.Box, p *project, path string, line int64) {
	ui.ContextMenu(c, row, func(menu *ui.MenuItems) {
		t := a.text.Debug
		lang := a.language()
		menu.WidthRange(160, 240)
		if menu.Item(t.Breakpoint.Edit).Clicked() {
			c.After(func() { a.openBreakpointEdit(p, path, line) })
		}
		if menu.Item(i18n.Shared(lang, "git.jumpToSource")).Clicked() {
			c.After(func() {
				a.performed("debug.breakpoint.jumpToSource", surfaceMenu)
				a.openFileAtPosition(p, path, int(max(line-1, 0)), 0)
			})
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "debugger.removeBreakpoint")).Clicked() {
			c.After(func() {
				a.performed("debug.breakpoint.remove", surfaceMenu)
				a.removeBreakpoint(p, path, line)
			})
		}
		if menu.Item(i18n.Shared(lang, "native.removeAll")).Clicked() {
			c.After(func() {
				a.performed("debug.breakpoint.removeAll", surfaceMenu)
				a.removeAllBreakpoints(p)
			})
		}
	})
}

// removeAllBreakpoints drops every stored line breakpoint and tells the active adapter, file by
// file, that those files have none left.
func (a *App) removeAllBreakpoints(p *project) {
	paths := make([]string, 0, len(p.debug.breakpoints))
	for path := range p.debug.breakpoints {
		paths = append(paths, path)
	}
	for _, path := range paths {
		delete(p.debug.breakpoints, path)
		if p.debug.activeSession() != nil {
			a.sendDebugBreakpoints(p, path)
		}
	}
}
