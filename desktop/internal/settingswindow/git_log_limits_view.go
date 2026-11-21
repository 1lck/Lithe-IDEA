package settingswindow

import (
	"slices"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file is the Git Log card of the Git settings page (matrix id git-history): the most
// commits the log reads of one repository, and of several merged by date. The log ends there
// and says it reached the limit, with a way back to this card.

// The Git Log's limits. The defaults are what the log read before they could be changed; Core's
// git.historyPage reads at most MaxGitLogLimit commits of one walk, and git.workspaceHistoryMerge
// and git.graphProjection take as many.
const (
	DefaultGitLogLimit       = 5000
	DefaultGitLogMergedLimit = 20000
	MinGitLogLimit           = 100
	MaxGitLogLimit           = 100000
)

var gitLogLimitChoices = []int{1000, 2000, 5000, 10000, 20000, 50000, 100000}

// ClampGitLogLimit is limit within the card's limits; zero is fallback, the default.
func ClampGitLogLimit(limit, fallback int) int {
	if limit == 0 {
		return fallback
	}
	return min(max(limit, MinGitLogLimit), MaxGitLogLimit)
}

// gitLogLimitsCard declares the Git Log card: a row for each limit, each a list of the choices
// with the default marked, and the stored value among them when it is not one of them.
func (w *window) gitLogLimitsCard(c ui.C, language i18n.Language) {
	values := &w.sess.values
	single := ClampGitLogLimit(values.GitLogLimit, DefaultGitLogLimit)
	merged := ClampGitLogLimit(values.GitLogMergedLimit, DefaultGitLogMergedLimit)
	row := func(key, title, help string, value *int, fallback int) bool {
		choices := gitLogLimitChoices
		if !slices.Contains(choices, *value) {
			choices = slices.Sorted(slices.Values(append(slices.Clone(choices), *value)))
		}
		label := func(n int) string {
			if n == fallback {
				return i18n.SharedFormat(language, "desktop.git.settings.logLimitDefault", map[string]string{"count": strconv.Itoa(n)})
			}
			return strconv.Itoa(n)
		}
		changed := false
		w.settingsRow(c, title, help, func() {
			changed = ui.Select(c.Part(key), value, choices, label).Width(selectWidth).Label(title).Changed()
		})
		return changed
	}
	w.card(c, i18n.Shared(language, "desktop.git.settings.logLimits"), i18n.Shared(language, "desktop.git.settings.logLimitsHelp"), func() {
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			singleChanged := row("logLimit", i18n.Shared(language, "desktop.git.settings.logLimitSingle"),
				i18n.Shared(language, "desktop.git.settings.logLimitSingleHelp"), &single, DefaultGitLogLimit)
			mergedChanged := row("logMergedLimit", i18n.Shared(language, "desktop.git.settings.logLimitMerged"),
				i18n.Shared(language, "desktop.git.settings.logLimitMergedHelp"), &merged, DefaultGitLogMergedLimit)
			if singleChanged || mergedChanged {
				w.setGitLogLimits(single, merged)
			}
		})
	})
}

// setGitLogLimits stores the Git Log's limits and hands them to the settings owner.
func (w *window) setGitLogLimits(single, merged int) {
	if w.sess.finished.Load() {
		return
	}
	single, merged = ClampGitLogLimit(single, DefaultGitLogLimit), ClampGitLogLimit(merged, DefaultGitLogMergedLimit)
	values := &w.sess.values
	if single == ClampGitLogLimit(values.GitLogLimit, DefaultGitLogLimit) && merged == ClampGitLogLimit(values.GitLogMergedLimit, DefaultGitLogMergedLimit) {
		return
	}
	values.GitLogLimit, values.GitLogMergedLimit = single, merged
	if w.ctrl.opts.SetGitLogLimits != nil {
		w.ctrl.opts.SetGitLogLimits(single, merged)
	}
}
