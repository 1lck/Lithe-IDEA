package i18n

import "strconv"

func terminalEndedStatus(language Language, status int) string {
	return SharedFormat(language, "desktop.terminal.sessionEndedStatus", map[string]string{"status": strconv.Itoa(status)})
}

func terminalStartFailed(language Language, reason string) string {
	return SharedFormat(language, "desktop.terminal.startFailed", map[string]string{"reason": reason})
}

func terminalShellWithPath(language Language, name, path string) string {
	return SharedFormat(language, "desktop.terminal.shellWithPath", map[string]string{"name": name, "path": path})
}

func terminalTab(language Language, number int) string {
	if number <= 1 {
		return Shared(language, "native.local")
	}
	return SharedFormat(language, "desktop.terminal.localNumber", map[string]string{"number": strconv.Itoa(number)})
}

func statusMemory(language Language, value int) string {
	return SharedFormat(language, "desktop.status.memoryValue", map[string]string{"value": strconv.Itoa(value)})
}

func statusFPS(language Language, value int) string {
	return SharedFormat(language, "desktop.status.fpsValue", map[string]string{"value": strconv.Itoa(value)})
}

func statusChanges(language Language, count int) string {
	if count == 1 {
		return SharedFormat(language, "footer.change", map[string]string{"count": strconv.Itoa(count)})
	}
	return SharedFormat(language, "footer.changes", map[string]string{"count": strconv.Itoa(count)})
}

// statusProblems is how many problems the language servers reported. One problem
// has its own wording, because "1 problems" is not English.
func statusProblems(language Language, count int) string {
	if count == 1 {
		return Shared(language, "desktop.status.oneProblem")
	}
	return SharedFormat(language, "desktop.status.problems", map[string]string{"count": strconv.Itoa(count)})
}

func commitFiles(language Language, count int) string {
	if count == 1 {
		return SharedFormat(language, "git.log.fileCountOne", map[string]string{"count": strconv.Itoa(count)})
	}
	return SharedFormat(language, "git.log.filesCount", map[string]string{"count": strconv.Itoa(count)})
}

func commitStaged(language Language, count int) string {
	return SharedFormat(language, "git.stagedFilesCount", map[string]string{"count": strconv.Itoa(count)})
}

func commitStep(language Language, number int, action, repository string) string {
	return SharedFormat(language, "desktop.commit.step", map[string]string{"number": strconv.Itoa(number), "action": action, "repository": repository})
}
