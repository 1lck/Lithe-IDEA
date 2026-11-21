package workbench

import "github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"

// This file applies the Git Log card of the Git settings (matrix id git-history):
// the most commits the log reads of one repository, and of several merged by date. Core reads a
// walk up to its limit and says when the history goes on past it (git.historyPage's
// limitReached), so the log ends there with a note that offers this card instead of failing.

// gitLogLimit is the most commits the log reads of one repository.
func (a *App) gitLogLimit() int {
	return settingswindow.ClampGitLogLimit(a.settings.GitLogLimit, settingswindow.DefaultGitLogLimit)
}

// gitLogMergedLimit is the most commits the log reads in all while it walks several repositories.
func (a *App) gitLogMergedLimit() int {
	return settingswindow.ClampGitLogLimit(a.settings.GitLogMergedLimit, settingswindow.DefaultGitLogMergedLimit)
}

// setGitLogLimits stores the Git Log's limits, a default as zero, and reads the open log again
// when the limit it walks with changed.
func (a *App) setGitLogLimits(single, merged int) {
	stored := func(limit, fallback int) int {
		if limit = settingswindow.ClampGitLogLimit(limit, fallback); limit == fallback {
			return 0
		}
		return limit
	}
	single = stored(single, settingswindow.DefaultGitLogLimit)
	merged = stored(merged, settingswindow.DefaultGitLogMergedLimit)
	if a.settings.GitLogLimit == single && a.settings.GitLogMergedLimit == merged {
		return
	}
	singleChanged, mergedChanged := a.settings.GitLogLimit != single, a.settings.GitLogMergedLimit != merged
	a.settings.GitLogLimit, a.settings.GitLogMergedLimit = single, merged
	a.saveSettings()
	p := a.project
	if p == nil || !p.log.started {
		return
	}
	if p.walksSeveral() && mergedChanged || !p.walksSeveral() && singleChanged {
		a.loadLog(p)
	}
}

// openGitLogLimitSettings opens the Git settings page, where the Git Log's limits are, from
// the end of a log that reached one.
func (a *App) openGitLogLimitSettings() {
	a.openSettingsPage(surfaceButton, settingsGit)
}
