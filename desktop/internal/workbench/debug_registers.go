package workbench

import "github.com/vivaui/viva/ui"

// debugRegistersTabs declares the Variables and Registers switch when the adapter reports a registers
// scope. Registers shows that scope alone, the way a native debugger does, and opens it when it has not
// been loaded: an expensive scope otherwise waits for the user, and choosing the tab is that choice. The
// tabs are not shown for an adapter without registers.
func (a *App) debugRegistersTabs(c ui.C, p *project) {
	v := &p.debug.vars
	scope := v.registersScope()
	if scope == nil {
		v.registersView = false
		return
	}
	t := a.text.Debug
	tab := "variables"
	if v.registersView {
		tab = "registers"
	}
	ui.Tabs(c, &tab, []string{"variables", "registers"}, func(name string) string {
		if name == "registers" {
			return t.Registers
		}
		return t.Variables
	})
	v.registersView = tab == "registers"
	if v.registersView && scope.ref > 0 && scope.container == nil && !scope.expanded && p.debug.activeSession() != nil {
		c.After(func() { a.expandDebugNode(p, scope) })
	}
}
