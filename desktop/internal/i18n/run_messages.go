package i18n

import (
	"strconv"
	"time"
)

// RunMessages are the words of the Run tool window: its execution tabs, tree and console.
type RunMessages struct {
	Rerun          string
	Ended          string
	LinkMissing    string
	LinkUnresolved string
	// CloseSession closes the tab of a finished execution; Empty is the window before anything ran.
	CloseSession    string
	Empty           string
	ExpandDetails   string
	CollapseDetails string
	DetachTab       string
	MergeIntoGroup  string
	// Running, Succeeded, Failed and Stopped name where an execution stands, beside its icon.
	Running, Succeeded, Failed, Stopped string
	// Snapshot words the output snapshot of a run (run_snapshot_messages.go).
	Snapshot RunSnapshotMessages
	// Performance words the CPU and memory readings of a run (run_performance_messages.go).
	Performance RunPerformanceMessages
	// Ports words the listening TCP ports row and actions of a running run (run_ports_messages.go).
	Ports RunPortsMessages
	// Exited reports a finished process and its exit code.
	Exited func(code int) string
	// Signalled reports a process ended by a signal.
	Signalled func(signal string) string
	// StartedAt follows an execution's name in the tree with when it started, already formatted.
	StartedAt func(time string) string
	// Duration is how long an execution took, given in milliseconds: seconds and milliseconds
	// under a minute, then minutes and seconds, then hours and minutes.
	Duration func(milliseconds int) string
}

func runMessages(language Language) RunMessages {
	return RunMessages{
		Rerun:           Shared(language, "desktop.run.rerun"),
		Ended:           Shared(language, "desktop.run.ended"),
		LinkMissing:     Shared(language, "desktop.run.linkMissing"),
		LinkUnresolved:  Shared(language, "desktop.run.linkUnresolved"),
		CloseSession:    Shared(language, "desktop.run.closeSession"),
		Empty:           Shared(language, "desktop.run.empty"),
		ExpandDetails:   Shared(language, "desktop.run.expandDetails"),
		CollapseDetails: Shared(language, "desktop.run.collapseDetails"),
		DetachTab:       Shared(language, "desktop.run.detachTab"),
		MergeIntoGroup:  Shared(language, "desktop.run.mergeIntoGroup"),
		Running:         Shared(language, "desktop.run.statusRunning"),
		Succeeded:       Shared(language, "desktop.run.statusSucceeded"),
		Failed:          Shared(language, "desktop.run.statusFailed"),
		Stopped:         Shared(language, "desktop.run.statusStopped"),
		Snapshot:        runSnapshotMessages(language),
		Performance:     runPerformanceMessages(language),
		Ports:           runPortsMessages(language),
		Exited: func(code int) string {
			return SharedFormat(language, "desktop.run.exited", map[string]string{"code": strconv.Itoa(code)})
		},
		Signalled: func(signal string) string {
			return SharedFormat(language, "desktop.run.signalled", map[string]string{"signal": signal})
		},
		StartedAt: func(time string) string {
			return SharedFormat(language, "desktop.run.startedAt", map[string]string{"time": time})
		},
		Duration: func(milliseconds int) string {
			return runDuration(language, time.Duration(milliseconds)*time.Millisecond)
		},
	}
}

func runDuration(language Language, elapsed time.Duration) string {
	elapsed = max(elapsed, 0)
	count := func(value time.Duration) string { return strconv.FormatInt(int64(value), 10) }
	switch {
	case elapsed < time.Second:
		return SharedFormat(language, "desktop.run.durationMilliseconds", map[string]string{"milliseconds": count(elapsed / time.Millisecond)})
	case elapsed < time.Minute:
		return SharedFormat(language, "desktop.run.durationSeconds", map[string]string{
			"seconds": count(elapsed / time.Second), "milliseconds": count(elapsed % time.Second / time.Millisecond),
		})
	case elapsed < time.Hour:
		return SharedFormat(language, "desktop.run.durationMinutes", map[string]string{
			"minutes": count(elapsed / time.Minute), "seconds": count(elapsed % time.Minute / time.Second),
		})
	default:
		return SharedFormat(language, "desktop.run.durationHours", map[string]string{
			"hours": count(elapsed / time.Hour), "minutes": count(elapsed % time.Hour / time.Minute),
		})
	}
}
