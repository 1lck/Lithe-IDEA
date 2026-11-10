package workbench

import "github.com/vivaui/viva/ui"

// The AI Assistant panel is the component agentPanel (agent_view.go). Until the workbench
// window is one Page, the Frame window hosts it in a Page of its own, which is all this file
// does: it makes the Page on first use and puts it in the tool window's slot, which
// registers it with the page host. Delete this file and call agentPanel from the window's
// view when the window becomes a Page.

// drawAgentPanel puts the Agent panel's host page in the room the tool window leaves under
// its header.
func (a *App) drawAgentPanel(f *ui.Frame, p *project) {
	if p.agentPage == nil {
		p.agentPage = a.newHostedPage("agent-panel")
	}
	a.embedPage(f, p.agentPage, a.agentPanel)
}
