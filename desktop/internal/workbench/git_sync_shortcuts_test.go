package workbench

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/keymap"
)

// Regression test for #2406: a user binding on git.pull opens the Pull dialog.
func TestGitPullUserShortcutOpensPullDialog(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)

	chord, ok := keymap.Parse(keymap.Primary|gfx.ModifierAlt, "p")
	if !ok {
		t.Fatal("failed to parse Primary+Alt+P")
	}
	h.app.settings.Keymap = h.app.settings.Keymap.With("git.pull", []keymap.Chord{chord})
	h.app.invalidator.Invalidate()
	h.settle()

	if _, err := h.driver.ShortcutChord(chord.Modifiers, 'p'); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if p.log.sync.dialog != syncDialogPull {
		t.Fatal("git.pull shortcut did not open the Pull dialog")
	}
}

// Regression test for #2406: the default git.push shortcut opens the Push dialog.
func TestGitPushDefaultShortcutOpensPushDialog(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)

	if _, err := h.driver.ShortcutChord(keymap.Primary|gfx.ModifierShift, 'k'); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if !p.review.push.open {
		t.Fatal("git.push default shortcut did not open the Push dialog")
	}
}
