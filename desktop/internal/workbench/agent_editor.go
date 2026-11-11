package workbench

import (
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// agentConversationPane declares the conversation as the body of an editor group: the
// same setup or transcript the Agent tool window shows.
func (a *App) agentConversationPane(c ui.C, p *project) {
	// The editor shows the conversation in a centred reading column of 8 parts out of 10,
	// as the macOS editor tab does, so long replies do not run across a wide editor.
	ui.Row(c.Key("editor-conversation")).Fill().Children(func() {
		ui.Column(c.Key("editor-margin-start")).Grow(1).Fill()
		reading := ui.Column(c.Key("editor-reading")).Grow(8).Fill()
		reading.Children(func() {
			if p.agent.conn == nil {
				if !p.agent.chosen {
					a.agentWelcome(c, p)
					return
				}
				a.agentSetup(c, p)
				return
			}
			a.agentConversation(c, p)
		})
		if p.agent.conn != nil {
			// The menu item and the sidebar's own buttons set the same flag, so they stay in step.
			ui.ContextMenu(c.Key("editor-menu"), reading, func(menu *ui.MenuItems) {
				shown := p.agent.detailOpen
				if menu.Item(a.text.Agent.Detail.ShowMenu).Checked(shown).Clicked() {
					c.After(func() { p.agent.detailOpen = !shown })
				}
			})
		}
		ui.Column(c.Key("editor-margin-end")).Grow(1).Fill()
		if p.agent.conn != nil {
			a.agentDetailSide(c, p)
		}
	})
}

// agentConversationMember names the AI conversation when it is a tab of the editor area.
// The conversation is one per project, so one name is enough. Its state stays in the
// project's agentState; the tab only shows it, so moving it never restarts the Agent.
const agentConversationMember = "agent:conversation"

// agentInEditor reports whether the conversation is a tab of the editor area.
func (a *App) agentInEditor(p *project) bool {
	return p != nil && p.terms.bench.GroupOf(agentConversationMember) != nil
}

// openAgentInEditor places the conversation in a new editor group, beside the existing
// layout, or as the only group of an empty editor. If it is already a tab it is shown
// there. It reports whether the kernel accepted the placement.
func (a *App) openAgentInEditor(p *project) bool {
	if p == nil {
		return false
	}
	if a.agentInEditor(p) {
		a.selectAgentTab(p)
		return true
	}
	set := &p.terms
	added := editorGroupID(set.nextGroup + 1)
	state := set.bench
	state.Groups = append(slices.Clone(state.Groups), core.EditorGroup{ID: added})
	if !a.reduceTerminals(p, state, core.OpenEditor(added, agentConversationMember, true)) {
		return false
	}
	set.nextGroup++
	if set.layout == nil {
		set.layout = newLeaf(added)
	} else {
		set.nextNode++
		set.layout = splitLeaf(set.layout, firstEditorGroup(set.layout), added, edgeRight, set.nextNode)
	}
	return true
}

// firstEditorGroup is the first group of the layout, the one a new group is split from.
func firstEditorGroup(n *splitNode) string {
	for n != nil && !n.leaf() {
		n = n.first
	}
	if n == nil {
		return ""
	}
	return n.group
}

// selectAgentTab shows the conversation's tab and gives it the keyboard.
func (a *App) selectAgentTab(p *project) {
	set := &p.terms
	g := set.bench.GroupOf(agentConversationMember)
	if g == nil {
		return
	}
	if g.Selected != agentConversationMember && !a.reduceTerminals(p, set.bench, core.ActivateEditor(g.ID, agentConversationMember)) {
		return
	}
}

// closeAgentTab moves the conversation back to the Agent tool window. The Agent keeps
// running: only the tab goes, and the layout follows as it does for a terminal.
func (a *App) closeAgentTab(p *project) {
	set := &p.terms
	g := set.bench.GroupOf(agentConversationMember)
	if g == nil {
		return
	}
	group := g.ID
	if !a.reduceTerminals(p, set.bench, core.CloseEditor(group, agentConversationMember, emptyPolicy(group), core.SelectAdjacent)) {
		return
	}
	a.focusSelected(p, group)
}

// agentEditorNotice is what the Agent tool window shows while the conversation is a tab of
// the editor: where it is, and a button that shows that tab.
func (a *App) agentEditorNotice(c ui.C, p *project) {
	t := a.text.Agent.Editor
	ui.Column(c).Fill().Items(ui.Center).Gap(8).PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, t.InEditor, 4).TextCenter().Color(a.colors.Subtle)
		if ui.Button(c, t.ShowInEditor).Outline().Clicked() {
			c.After(func() { a.selectAgentTab(p) })
		}
	})
}
