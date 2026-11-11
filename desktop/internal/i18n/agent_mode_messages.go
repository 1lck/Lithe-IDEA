package i18n

// AgentModeMessages label the approval modes. Only the known modes of the pinned adapters
// have a product title; any other mode keeps the adapter's own name.
type AgentModeMessages struct {
	Heading string
	// Titles is keyed by the adapter's mode id.
	Titles map[string]string
}

func agentModeMessages(language Language) AgentModeMessages {
	return AgentModeMessages{
		Heading: Shared(language, "desktop.agent.mode.heading"),
		Titles: map[string]string{
			"default":           Shared(language, "desktop.agent.mode.manual"),
			"acceptEdits":       Shared(language, "desktop.agent.mode.acceptEdits"),
			"plan":              Shared(language, "desktop.agent.mode.plan"),
			"auto":              Shared(language, "desktop.agent.mode.auto"),
			"bypassPermissions": Shared(language, "desktop.agent.mode.bypassPermissions"),
			"read-only":         Shared(language, "desktop.agent.mode.askForApproval"),
			"agent":             Shared(language, "desktop.agent.mode.approveForMe"),
			"agent-full-access": Shared(language, "desktop.agent.mode.fullAccess"),
		},
	}
}
