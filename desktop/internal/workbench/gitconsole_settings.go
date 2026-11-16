package workbench

import "github.com/1lck/Lithe-IDEA/desktop/internal/core"

// This file applies the Git console switches of the Version Control settings (matrix id
// git-history). They start as IntelliJ IDEA's console. The query switches say which kinds of
// internal Git queries the console records, which Core then reports for the requests that
// follow; a kind left out is never recorded, so it takes none of the journal's records. The
// display switches say how the console draws the records it keeps, which the next paint asks
// Core to present them with. The commands the user runs, failed Git requests and unexpected
// exit codes are recorded whatever the switches say.

// setGitConsolePreferences stores the Git console switches and applies them at once: the
// journal records the query kinds they show from the next request on, and the console draws
// its records with their display choices.
func (a *App) setGitConsolePreferences(preferences core.GitConsolePreferences) {
	if a.settings.GitConsole == preferences {
		return
	}
	a.settings.GitConsole = preferences
	a.saveSettings()
	a.gitConsole.SetPreferences(preferences)
	a.invalidator.Invalidate()
}

// openGitConsoleSettings opens the Version Control settings, where the console's switches are,
// from the console's toolbar.
func (a *App) openGitConsoleSettings() {
	a.openSettingsPage(surfaceButton, settingsVersionControl)
}
