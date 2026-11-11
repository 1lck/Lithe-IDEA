package i18n

// AgentHeaderMessages label the icon-only controls at the top of the conversation: the
// shortcut to the Agent settings and the control that collapses the Assistant panel.
type AgentHeaderMessages struct {
	Settings string
	Collapse string
}

func agentHeaderMessages(language Language) AgentHeaderMessages {
	return AgentHeaderMessages{
		Settings: Shared(language, "desktop.agent.header.settings"),
		Collapse: Shared(language, "desktop.agent.header.collapse"),
	}
}
