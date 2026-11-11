package workbench

import (
	"github.com/vivaui/viva/ui"
)

// agentKnownModeNames are the approval modes of the pinned adapters that keep a product
// title, keyed by the adapter's mode id, with the English name the adapter reports. The
// title replaces the name only when the name matches, so another adapter's mode with the
// same id keeps its own name (the macOS rule).
var agentKnownModeNames = map[string]string{
	"default":           "Manual",
	"acceptEdits":       "Accept edits",
	"plan":              "Plan",
	"auto":              "Auto",
	"bypassPermissions": "Bypass permissions",
	"read-only":         "Ask for approval",
	"agent":             "Approve for me",
	"agent-full-access": "Full access",
}

// agentConfigChoiceTitle is the name a choice shows: a known approval mode's product title
// in the interface language, and every other choice's name as the Agent reported it.
func (a *App) agentConfigChoiceTitle(option agentConfigOption, choice agentConfigChoice) string {
	if option.Category == "mode" {
		if english, ok := agentKnownModeNames[choice.Value]; ok && english == choice.Name {
			if title := a.text.Agent.Mode.Titles[choice.Value]; title != "" {
				return title
			}
		}
	}
	return choice.Name
}

// agentChoiceMenu declares a select option as a button that opens the Agent's full list. The
// approval mode is headed "Mode" and its current choice is checked on the left with the
// Agent's own description beside it; a model list keeps the Agent's groups as headings.
// Choosing one sends the same explicit command as the drop-down.
func (a *App) agentChoiceMenu(c ui.C, p *project, option *agentConfigOption, disabled bool) {
	current := option
	label := ""
	for _, choice := range current.Choices {
		if choice.Value == current.Current {
			label = a.agentConfigChoiceTitle(*current, choice)
		}
	}
	if label == "" {
		label = current.Current
	}
	button := ui.Button(c.Key("mode"), label).Outline().Height(28).Grow(1).Disabled(disabled)
	if button.Clicked() {
		current.open = !current.open
	}
	ui.Menu(c, button, &current.open, func(menu *ui.MenuItems) {
		if current.Category == "mode" {
			menu.Label(a.text.Agent.Mode.Heading)
		}
		group := ""
		for _, choice := range current.Choices {
			if choice.Group != "" && choice.Group != group {
				group = choice.Group
				menu.Label(group)
			}
			item := menu.Item(a.agentConfigChoiceTitle(*current, choice)).Checked(choice.Value == current.Current)
			if choice.Description != "" {
				item = item.Description(choice.Description)
			}
			if item.Clicked() {
				id, value := current.ID, choice.Value
				c.After(func() {
					current.open = false
					a.selectAgentConfig(p, id, value)
				})
			}
		}
	})
}
