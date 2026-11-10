package i18n

import "strconv"

// ConsoleMessages are the words of the Git tool window's Console tab, which lists the Git
// commands Lithe ran and what they printed.
type ConsoleMessages struct {
	// The search bar.
	Find string
	// Matches says how many places match the search.
	Matches func(count int) string
	// SearchLimit says only the first count places are shown.
	SearchLimit   func(count int) string
	NoMatches     string
	PreviousMatch string
	NextMatch     string
	CloseSearch   string

	// The toolbar.
	Wrap        string
	ScrollToEnd string
	Stop        string
	Clear       string
	CopyAll     string

	// The context menu of a command.
	CopyCommand string
	CopyOutput  string
	CopyPath    string

	Empty string
	// HistoryTruncated says the oldest commands were dropped to bound memory.
	HistoryTruncated string
	// Truncated says the start of a command's output was dropped to bound memory.
	Truncated   string
	Running     string
	Unconfirmed string
	// ExitCode is the exit code of a command that did not exit as expected.
	ExitCode func(code int) string
	// Notices Core gives in place of output.
	Waiting   string
	NoOutput  string
	Unchanged string

	// ExpandLines opens a fold of count progress lines.
	ExpandLines func(count int) string
	// ExpandConfiguration opens a fold of count temporary Git settings of a command.
	ExpandConfiguration func(count int) string
	Collapse            string
	// Unavailable says the console shows the plain output because Core could not fold it.
	Unavailable string
}

func consoleMessages(language Language) ConsoleMessages {
	return ConsoleMessages{
		Find: Shared(language, "git.console.find"),
		Matches: func(n int) string {
			return SharedFormat(language, "git.console.matches", map[string]string{"count": strconv.Itoa(n)})
		},
		SearchLimit: func(n int) string {
			return SharedFormat(language, "git.console.searchLimit", map[string]string{"count": strconv.Itoa(n)})
		},
		NoMatches:     Shared(language, "native.noMatches"),
		PreviousMatch: Shared(language, "git.console.previousMatch"),
		NextMatch:     Shared(language, "git.console.nextMatch"),
		CloseSearch:   Shared(language, "git.console.closeSearch"),

		Wrap:        Shared(language, "git.console.wrap"),
		ScrollToEnd: Shared(language, "git.console.scrollToEnd"),
		Stop:        Shared(language, "git.console.cancel"),
		Clear:       Shared(language, "native.clearGitConsole"),
		CopyAll:     Shared(language, "native.copyCompleteConsole"),

		CopyCommand: Shared(language, "git.console.copyCommand"),
		CopyOutput:  Shared(language, "git.console.copyOutput"),
		CopyPath:    Shared(language, "git.console.copyPath"),

		Empty:            Shared(language, "git.console.empty"),
		HistoryTruncated: Shared(language, "git.console.historyTruncated"),
		Truncated:        Shared(language, "git.console.truncated"),
		Running:          Shared(language, "git.console.running"),
		Unconfirmed:      Shared(language, "git.console.unconfirmed"),
		ExitCode: func(code int) string {
			return SharedFormat(language, "desktop.git.console.exitCode", map[string]string{"code": strconv.Itoa(code)})
		},
		Waiting:   Shared(language, "git.console.notice.waitingForOutput"),
		NoOutput:  Shared(language, "git.console.notice.completedWithoutOutput"),
		Unchanged: Shared(language, "git.console.notice.fetchUnchanged"),

		ExpandLines: func(n int) string {
			return SharedFormat(language, "git.console.fold.lines", map[string]string{"count": strconv.Itoa(n)})
		},
		ExpandConfiguration: func(n int) string {
			return SharedFormat(language, "desktop.git.console.expandConfiguration", map[string]string{"count": strconv.Itoa(n)})
		},
		Collapse:    Shared(language, "desktop.git.console.collapse"),
		Unavailable: Shared(language, "git.console.presentationUnavailable"),
	}
}
