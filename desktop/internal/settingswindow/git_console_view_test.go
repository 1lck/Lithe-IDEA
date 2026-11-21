package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// The Git console cards start as IntelliJ IDEA does: every omit switch on, and of the display
// switches only the one that omits the no-output notice. A switch the user flips reaches the
// settings owner as the preference it stands for, and Restore Defaults brings the IDEA state
// back.
func TestGitConsoleCardsStartAsIDEAAndHandOnTheirChanges(t *testing.T) {
	var changes []core.GitConsolePreferences
	w := newWindow(NewController(Options{
		SetGitConsole: func(preferences core.GitConsolePreferences) { changes = append(changes, preferences) },
	}), Values{})
	w.sess.page = pageGit
	d := openWindow(t, w, func(config *app.Config) { config.Height = 1800 })
	switchOf := func(key string) gfx.Hit {
		t.Helper()
		hit := d.hit(i18n.Shared(i18n.English, "desktop.git.settings.console."+key))
		if hit.Role != gfx.RoleSwitch {
			t.Fatalf("%s is a %v, want a switch", key, hit.Role)
		}
		return hit
	}
	expect := func(when string, on map[string]bool) {
		t.Helper()
		for _, key := range []string{"references", "reload", "diffRefresh", "diff", "log", "logPathFilter", "annotate", "panels", "checks", "foldShortQueries", "completedNotice", "temporaryConfig", "repository"} {
			want := key != "foldShortQueries" && key != "temporaryConfig" && key != "repository"
			if flipped, ok := on[key]; ok {
				want = flipped
			}
			if got := switchOf(key).Checked; got != want {
				t.Fatalf("%s: switch %s is %v, want %v", when, key, got, want)
			}
		}
	}
	expect("at first", nil)

	d.click(i18n.Shared(i18n.English, "desktop.git.settings.console.diff"))
	d.click(i18n.Shared(i18n.English, "desktop.git.settings.console.repository"))
	want := core.GitConsolePreferences{ShowDiffQueries: true, HideRepository: true}
	if len(changes) != 2 || changes[1] != want || w.sess.values.GitConsole != want {
		t.Fatalf("changes %+v, window %+v, want %+v", changes, w.sess.values.GitConsole, want)
	}
	d.pump()
	expect("after the clicks", map[string]bool{"diff": false, "repository": true})

	d.click("Restore Defaults")
	if last := changes[len(changes)-1]; len(changes) != 3 || last != (core.GitConsolePreferences{}) || w.sess.values.GitConsole != last {
		t.Fatalf("Restore Defaults handed on %+v and kept %+v", changes, w.sess.values.GitConsole)
	}
	d.pump()
	expect("after Restore Defaults", nil)
}
