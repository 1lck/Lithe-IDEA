package i18n

// RunSnapshotMessages are the words of the output snapshot of a run: the context
// menu item and the title of the read-only tab it opens.
type RunSnapshotMessages struct {
	Menu string
	// Tab names the read-only tab of a snapshot of the run labelled label.
	Tab func(label string) string
}

func runSnapshotMessages(language Language) RunSnapshotMessages {
	return RunSnapshotMessages{
		Menu: Shared(language, "desktop.run.snapshot.menu"),
		Tab: func(label string) string {
			return SharedFormat(language, "desktop.run.snapshot.tab", map[string]string{"label": label})
		},
	}
}
