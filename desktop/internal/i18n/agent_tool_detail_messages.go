package i18n

// AgentToolDetailMessages label the details of a tool call: the files it touched and its
// reported diff.
type AgentToolDetailMessages struct {
	ShowDiff   string
	HideDiff   string
	DiffBefore string
	DiffAfter  string
	DiffNote   string
	Truncated  string
}

func agentToolDetailMessages(language Language) AgentToolDetailMessages {
	return AgentToolDetailMessages{
		ShowDiff:   Shared(language, "desktop.agent.tool.showDiff"),
		HideDiff:   Shared(language, "desktop.agent.tool.hideDiff"),
		DiffBefore: Shared(language, "desktop.agent.tool.diffBefore"),
		DiffAfter:  Shared(language, "desktop.agent.tool.diffAfter"),
		DiffNote:   Shared(language, "desktop.agent.tool.diffNote"),
		Truncated:  Shared(language, "desktop.agent.tool.truncated"),
	}
}
