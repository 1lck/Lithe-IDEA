package i18n

// AgentExportMessages label the export of the open conversation to a Markdown file.
type AgentExportMessages struct {
	Export       string
	DialogTitle  string
	Failed       func(reason string) string
	ProcessSteps string
	// Batch labels the batch export of several history sessions.
	BatchSelect   string
	BatchDone     string
	BatchCancel   string
	BatchExport   func(count string) string
	BatchProgress func(done, total string) string
}

func agentExportMessages(language Language) AgentExportMessages {
	return AgentExportMessages{
		Export:      Shared(language, "desktop.agent.export.button"),
		DialogTitle: Shared(language, "desktop.agent.export.dialogTitle"),
		Failed: func(reason string) string {
			return SharedFormat(language, "desktop.agent.export.failed", map[string]string{"reason": reason})
		},
		ProcessSteps: Shared(language, "desktop.agent.export.processSteps"),
		BatchSelect:  Shared(language, "desktop.agent.export.batchSelect"),
		BatchDone:    Shared(language, "desktop.agent.export.batchDone"),
		BatchCancel:  Shared(language, "desktop.agent.export.batchCancel"),
		BatchExport: func(count string) string {
			return SharedFormat(language, "desktop.agent.export.batchExport", map[string]string{"count": count})
		},
		BatchProgress: func(done, total string) string {
			return SharedFormat(language, "desktop.agent.export.batchProgress", map[string]string{"done": done, "total": total})
		},
	}
}
