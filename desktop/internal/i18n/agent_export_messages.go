package i18n

// AgentExportMessages label the export of the open conversation to a Markdown file.
type AgentExportMessages struct {
	Export       string
	DialogTitle  string
	Failed       func(reason string) string
	ProcessSteps string
}

func agentExportMessages(language Language) AgentExportMessages {
	return AgentExportMessages{
		Export:      Shared(language, "desktop.agent.export.button"),
		DialogTitle: Shared(language, "desktop.agent.export.dialogTitle"),
		Failed: func(reason string) string {
			return SharedFormat(language, "desktop.agent.export.failed", map[string]string{"reason": reason})
		},
		ProcessSteps: Shared(language, "desktop.agent.export.processSteps"),
	}
}
