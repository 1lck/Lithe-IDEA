package i18n

import "strconv"

// RunMessages are the words of the plugin-started run entries shown beside the
// build output.
type RunMessages struct {
	Build          string
	Rerun          string
	Ended          string
	LinkMissing    string
	LinkUnresolved string
	// Snapshot words the output snapshot of a run (run_snapshot_messages.go).
	Snapshot RunSnapshotMessages
	// Exited reports a finished process and its exit code.
	Exited func(code int) string
	// Signalled reports a process ended by a signal.
	Signalled func(signal string) string
}

func runMessages(language Language) RunMessages {
	return RunMessages{
		Build:          Shared(language, "desktop.run.build"),
		Rerun:          Shared(language, "desktop.run.rerun"),
		Ended:          Shared(language, "desktop.run.ended"),
		LinkMissing:    Shared(language, "desktop.run.linkMissing"),
		LinkUnresolved: Shared(language, "desktop.run.linkUnresolved"),
		Snapshot:       runSnapshotMessages(language),
		Exited: func(code int) string {
			return SharedFormat(language, "desktop.run.exited", map[string]string{"code": strconv.Itoa(code)})
		},
		Signalled: func(signal string) string {
			return SharedFormat(language, "desktop.run.signalled", map[string]string{"signal": signal})
		},
	}
}
