package workbench

import "github.com/1lck/Lithe-IDEA/desktop/internal/core"

// This file applies the Git console switches of the Git settings (matrix id
// git-history). They start as IntelliJ IDEA's console. The query switches say which kinds of
// internal Git queries the console records, which Core then reports for the requests that
// follow; a kind left out reports nothing while it succeeds, so it takes none of the journal's
// records, and turning a kind off frees the records its successful queries took. The display
// switches say how the console draws the records it keeps, which the next paint asks Core to
// present them with, read from the settings alone. The commands the user runs, failed Git
// requests, the failed queries of the requests the user started and unexpected exit codes are
// recorded whatever the switches say.

// setGitConsolePreferences stores the Git console switches and applies them at once: the
// journal records the query kinds they show from the next request on, and the console draws
// its records with their display choices.
func (a *App) setGitConsolePreferences(preferences core.GitConsolePreferences) {
	if a.settings.GitConsole == preferences {
		return
	}
	a.settings.GitConsole = preferences
	a.saveSettings()
	a.gitConsole.RecordQueries(preferences.QueryCategories())
	a.invalidator.Invalidate()
}

// openGitConsoleSettings opens the Git settings page, where the console's switches are, from
// the console's toolbar.
func (a *App) openGitConsoleSettings() {
	a.openSettingsPage(surfaceButton, settingsGit)
}
