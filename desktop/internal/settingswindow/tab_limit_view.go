package settingswindow

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// The editor's tab limit: how many file tabs stay open and which one opening another closes.
const (
	DefaultTabLimit = 30
	// TabPolicyOldest closes the tab opened first; the default closes the least recently used.
	TabPolicyOldest = "oldest"
)

var (
	tabLimitChoices  = []int{0, 5, 10, 15, 20, 30, 50, 100}
	tabPolicyChoices = []string{"", TabPolicyOldest}
)

// TabLimitOf is a stored limit, nil being the default.
func TabLimitOf(stored *int) int {
	if stored == nil {
		return DefaultTabLimit
	}
	return max(*stored, 0)
}

// tabLimitCard is the Editor page's tab limit: the number, and the tab closed past it.
func (w *window) tabLimitCard(c ui.C) {
	language := w.marketLanguage()
	values := &w.sess.values
	limit, policy := values.EditorTabLimit, values.EditorTabPolicy
	choices := tabLimitChoices
	if !slicesContains(choices, limit) {
		choices = append(append([]int{}, choices...), limit)
	}
	limitLabel := func(n int) string {
		if n == 0 {
			return i18n.Shared(language, "desktop.settings.editor.tabLimitNone")
		}
		return strconv.Itoa(n)
	}
	policyLabel := func(p string) string {
		if p == TabPolicyOldest {
			return i18n.Shared(language, "desktop.settings.editor.tabPolicyOldest")
		}
		return i18n.Shared(language, "desktop.settings.editor.tabPolicyRecent")
	}
	row := func(name string, body func()) {
		ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
			ui.Text(c, name).FontSize(12).Color(w.pal.text).Grow(1).MinWidth(0).Ellipsis()
			body()
		})
	}
	w.card(c, i18n.Shared(language, "desktop.settings.editor.tabLimit"), i18n.Shared(language, "desktop.settings.editor.tabLimitHelp"), func() {
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			row(i18n.Shared(language, "desktop.settings.editor.tabLimitCount"), func() {
				if ui.Select(c.Part("limit"), &limit, choices, limitLabel).Width(selectWidth).Label(i18n.Shared(language, "desktop.settings.editor.tabLimitCount")).Changed() {
					w.setTabLimit(limit, policy)
				}
			})
			row(i18n.Shared(language, "desktop.settings.editor.tabPolicy"), func() {
				if ui.Select(c.Part("policy"), &policy, tabPolicyChoices, policyLabel).Width(selectWidth).Disabled(limit == 0).Label(i18n.Shared(language, "desktop.settings.editor.tabPolicy")).Changed() {
					w.setTabLimit(limit, policy)
				}
			})
		})
	})
}

func slicesContains(list []int, value int) bool {
	for _, v := range list {
		if v == value {
			return true
		}
	}
	return false
}

// setTabLimit stores the tab limit and hands it to the settings owner.
func (w *window) setTabLimit(limit int, policy string) {
	if w.sess.finished.Load() {
		return
	}
	w.sess.values.EditorTabLimit, w.sess.values.EditorTabPolicy = limit, policy
	if w.ctrl.opts.SetTabLimit != nil {
		w.ctrl.opts.SetTabLimit(limit, policy)
	}
}
