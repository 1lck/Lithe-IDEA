package i18n

// AgentEditorMessages label the placement of the AI conversation in the editor area and
// back in the Agent tool window.
type AgentEditorMessages struct {
	OpenInEditor string
	InEditor     string
	ShowInEditor string
}

func agentEditorMessages(language Language) AgentEditorMessages {
	return AgentEditorMessages{
		OpenInEditor: Shared(language, "desktop.agent.editor.open"),
		InEditor:     Shared(language, "desktop.agent.editor.inEditor"),
		ShowInEditor: Shared(language, "desktop.agent.editor.show"),
	}
}
