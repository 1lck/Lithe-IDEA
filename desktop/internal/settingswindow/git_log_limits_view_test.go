package settingswindow

import (
	"strconv"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
)

// The Git Log card shows the limits in force, the default marked and a stored limit that is no
// choice of the list among them; a choice reaches the settings owner at once, and Restore Defaults
// brings both defaults back.
func TestGitLogLimitsCardShowsAppliesAndRestores(t *testing.T) {
	type limits struct{ single, merged int }
	var changes []limits
	w := newWindow(NewController(Options{
		SetGitLogLimits: func(single, merged int) { changes = append(changes, limits{single, merged}) },
	}), Values{GitLogMergedLimit: 30000})
	w.sess.page = pageGit
	d := openWindow(t, w, func(config *app.Config) { config.Height = 1800 })
	text := func(id string) string { return i18n.Shared(i18n.English, id) }
	byDefault := func(n int) string {
		return i18n.SharedFormat(i18n.English, "desktop.git.settings.logLimitDefault", map[string]string{"count": strconv.Itoa(n)})
	}
	if !d.text(byDefault(DefaultGitLogLimit)) || !d.text("30000") {
		t.Fatal("the card does not show the limits in force")
	}

	d.click(text("desktop.git.settings.logLimitSingle"))
	d.click("10000")
	if len(changes) != 1 || changes[0] != (limits{10000, 30000}) || w.sess.values.GitLogLimit != 10000 {
		t.Fatalf("changes %+v, window %d, want 10000 handed on with 30000", changes, w.sess.values.GitLogLimit)
	}
	d.pump()
	if !d.text("10000") {
		t.Fatal("the card does not show the chosen limit")
	}

	d.click("Restore Defaults")
	if last := changes[len(changes)-1]; last != (limits{DefaultGitLogLimit, DefaultGitLogMergedLimit}) {
		t.Fatalf("Restore Defaults handed on %+v, want both defaults", last)
	}
	d.pump()
	if !d.text(byDefault(DefaultGitLogLimit)) || !d.text(byDefault(DefaultGitLogMergedLimit)) {
		t.Fatal("the card does not show the defaults after Restore Defaults")
	}
}

func TestClampGitLogLimitKeepsTheCardsRange(t *testing.T) {
	for _, tc := range []struct{ limit, want int }{
		{0, DefaultGitLogLimit}, {1, MinGitLogLimit}, {7000, 7000}, {MaxGitLogLimit + 1, MaxGitLogLimit},
	} {
		if got := ClampGitLogLimit(tc.limit, DefaultGitLogLimit); got != tc.want {
			t.Fatalf("ClampGitLogLimit(%d) = %d, want %d", tc.limit, got, tc.want)
		}
	}
}
