package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// A conversation shows in the Agent tool window or in an editor tab, and moves between them both
// ways: ↗ in the tool window's bar opens it in a tab, ↙ in the tab's bar takes it back. The tab
// is a member of a tab group named agentMember of the conversation's tab number, which numbers
// the tabs a project opened, so a conversation moved back and out again gets a new tab. Closing
// the tab only moves the conversation back: its session keeps running until the conversation is
// closed, which closes its tab too. Tabs are not saved with the editor session, whose sessions
// end with the window.

// agentMemberPrefix starts the member name of a conversation's editor tab.
const agentMemberPrefix = "agent:"

// agentMember is the member name of the conversation's editor tab number id.
func agentMember(id int) string { return agentMemberPrefix + strconv.Itoa(id) }

// memberAgent is the tab number of a conversation's tab member, false for another member.
func memberAgent(member string) (int, bool) {
	rest, ok := strings.CutPrefix(member, agentMemberPrefix)
	if !ok {
		return 0, false
	}
	id, err := strconv.Atoi(rest)
	return id, err == nil && id > 0
}

// tabConversation is the conversation editor tab number id shows, nil when none does.
func (v *agentsState) tabConversation(id int) *agentConversation {
	for _, conversation := range v.conversations {
		if conversation.tab == id {
			return conversation
		}
	}
	return nil
}

// selectedAgentTab is the conversation the editor group shows, nil when it shows another tab.
func (a *App) selectedAgentTab(group string) *agentConversation {
	p := a.project
	if p == nil {
		return nil
	}
	g := p.terms.bench.Group(group)
	if g == nil {
		return nil
	}
	id, ok := memberAgent(g.Selected)
	if !ok {
		return nil
	}
	return a.agentsView.tabConversation(id)
}

// openAgentTab moves the conversation into an editor tab in the group a file opens in, or shows
// its tab when it has one.
func (a *App) openAgentTab(p *project, conversation *agentConversation) {
	if p == nil || conversation == nil {
		return
	}
	if conversation.tab != 0 && p.terms.bench.GroupOf(agentMember(conversation.tab)) != nil {
		a.selectAgentTab(p, conversation.tab)
		return
	}
	v := &a.agentsView
	id := v.nextTab + 1
	if _, ok := a.placeEditorMember(p, agentMember(id)); !ok {
		return
	}
	v.nextTab, conversation.tab = id, id
	a.performed("agents.openInEditor", surfaceButton)
	a.selectAgentTab(p, id)
}

// selectAgentTab shows conversation tab number id in its group; files open in its group after
// it.
func (a *App) selectAgentTab(p *project, id int) {
	member := agentMember(id)
	g := p.terms.bench.GroupOf(member)
	if g == nil {
		return
	}
	if g.Selected != member && !a.reduceTerminals(p, p.terms.bench, core.ActivateEditor(g.ID, member)) {
		return
	}
	p.docs.group = g.ID
	a.focus = focusTarget{}
}

// closeAgentTab closes the conversation's editor tab, which moves it back to the Agent tool
// window; its group shows the neighbouring tab.
func (a *App) closeAgentTab(p *project, conversation *agentConversation) {
	if conversation.tab == 0 {
		return
	}
	if p != nil {
		member := agentMember(conversation.tab)
		if g := p.terms.bench.GroupOf(member); g != nil {
			group := g.ID
			if !a.reduceTerminals(p, p.terms.bench, core.CloseEditor(group, member, emptyPolicy(group), core.SelectAdjacent)) {
				return
			}
			a.focusSelected(p, group)
		}
	}
	conversation.tab = 0
}

// dockAgentTab moves the conversation from its editor tab back to the Agent tool window and
// shows it there.
func (a *App) dockAgentTab(p *project, conversation *agentConversation) {
	a.closeAgentTab(p, conversation)
	if conversation.tab != 0 {
		return
	}
	a.performed("agents.moveToSidebar", surfaceButton)
	a.selectConversation(conversation)
	a.agentsView.tab = agentsTabChat
	a.openToolWindow(itemAgents)
}

// sidebarConversation is the conversation the Agent tool window shows: the current one unless
// an editor tab shows it, else the first an editor tab does not show; nil when every one is in a
// tab.
func (a *App) sidebarConversation() *agentConversation {
	if conversation := a.currentConversation(); conversation != nil && conversation.tab == 0 {
		return conversation
	}
	for _, conversation := range a.agentsView.conversations {
		if conversation.tab == 0 {
			return conversation
		}
	}
	return nil
}
