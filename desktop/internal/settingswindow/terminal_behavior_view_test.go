package settingswindow

import (
	"slices"
	"testing"

	"github.com/vivaui/viva/gfx"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
)

// TestTerminalBehaviorSwitchesApplyWhenFlipped covers the Terminal page's switches: the stored
// values show without being rewritten by opening the page, each flip reaches the settings owner
// at once with the other switches kept, and Restore Defaults puts every one back.
func TestTerminalBehaviorSwitchesApplyWhenFlipped(t *testing.T) {
	offered := optionAsMetaOffered
	optionAsMetaOffered = true
	t.Cleanup(func() { optionAsMetaOffered = offered })
	var changed []TerminalBehavior
	w := newWindow(NewController(Options{
		TerminalShells: func() ([]localshell.Choice, string) {
			return []localshell.Choice{{Name: "zsh", Path: "/bin/zsh", Default: true}}, "/bin/zsh"
		},
		SetTerminalBehavior: func(behavior TerminalBehavior) { changed = append(changed, behavior) },
	}), Values{TerminalBehavior: TerminalBehavior{DisableClickMove: true}})
	w.sess.page = pageTerminal
	d := openWindow(t, w)
	language := w.marketLanguage()
	word := func(key string) string { return i18n.Shared(language, "desktop.settings.terminal."+key) }

	for _, check := range []struct {
		key string
		on  bool
	}{{"shellIntegration", true}, {"clickMove", false}, {"optionAsMeta", false}} {
		if hit := d.hit(word(check.key)); hit.Role != gfx.RoleSwitch || hit.Checked != check.on {
			t.Fatalf("%s shows %+v, want on=%v", check.key, hit, check.on)
		}
	}
	if len(changed) != 0 {
		t.Fatalf("opening the page wrote %v", changed)
	}

	d.click(word("shellIntegration"))
	d.click(word("clickMove"))
	d.click(word("optionAsMeta"))
	want := []TerminalBehavior{
		{DisableShellIntegration: true, DisableClickMove: true},
		{DisableShellIntegration: true},
		{DisableShellIntegration: true, OptionAsMeta: true},
	}
	if !slices.Equal(changed, want) {
		t.Fatalf("flips wrote %v, want %v", changed, want)
	}

	d.click("Restore Defaults")
	if last := changed[len(changed)-1]; last != (TerminalBehavior{}) || w.sess.values.TerminalBehavior != (TerminalBehavior{}) {
		t.Fatalf("restore wrote %+v and kept %+v", last, w.sess.values.TerminalBehavior)
	}
}

// Only macOS has an Option key that types characters, so the other platforms' page does not
// offer the switch.
func TestOptionAsMetaIsOfferedOnlyOnTheMac(t *testing.T) {
	offered := optionAsMetaOffered
	optionAsMetaOffered = false
	t.Cleanup(func() { optionAsMetaOffered = offered })
	w := newWindow(NewController(Options{
		TerminalShells: func() ([]localshell.Choice, string) { return nil, "" },
	}), Values{})
	w.sess.page = pageTerminal
	d := openWindow(t, w)
	word := func(key string) string { return i18n.Shared(w.marketLanguage(), "desktop.settings.terminal."+key) }
	if hit := d.hit(word("shellIntegration")); hit.Role != gfx.RoleSwitch {
		t.Fatalf("the shell integration switch is %+v", hit)
	}
	if d.has(word("optionAsMeta")) {
		t.Fatal("the page offers Option as Meta off the Mac")
	}
}
