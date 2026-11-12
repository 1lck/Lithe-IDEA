package settingswindow

import (
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// TestProcessTerminationPageAppliesAndRestores walks the Process Termination page: the
// stored values are shown, each choice reaches the settings owner at once with only the
// changed fields set, and Restore Defaults clears them back to Core's defaults.
func TestProcessTerminationPageAppliesAndRestores(t *testing.T) {
	var changes []ProcessTermination
	w := newWindow(NewController(Options{
		SetProcessTermination: func(value ProcessTermination) { changes = append(changes, value) },
	}), Values{ProcessTermination: ProcessTermination{TerminalOnQuit: TerminalsTerminate}})
	w.sess.page = pageProcessTermination
	d := openWindow(t, w)
	text := func(id string) string { return i18n.Shared(i18n.English, id) }

	if !d.text(text("desktop.settings.processTermination.endWithoutAsking")) || !d.text(text("desktop.settings.processTermination.askBeforeStopping")) {
		t.Fatal("the page does not show the stored choices")
	}
	tab := text("desktop.settings.processTermination.confirmTabClose")
	if hit := d.hit(tab); hit.Role != gfx.RoleSwitch || !hit.Checked {
		t.Fatalf("closing a busy tab asks by default: %+v", hit)
	}

	d.click(text("desktop.settings.processTermination.runServices"))
	d.click(text("desktop.settings.processTermination.stopWithoutAsking"))
	if len(changes) != 1 || changes[0].RunServicesOnExit != RunServicesTerminate || changes[0].TerminalOnQuit != TerminalsTerminate {
		t.Fatalf("run services change = %+v", changes)
	}
	d.click(tab)
	if last := changes[len(changes)-1]; last.ConfirmTerminalTabClose == nil || *last.ConfirmTerminalTabClose {
		t.Fatalf("turning the tab question off = %+v", last)
	}
	if hit := d.hit(tab); hit.Checked {
		t.Fatalf("the switch kept its on state: %+v", hit)
	}

	d.click("Restore Defaults")
	if last := changes[len(changes)-1]; last != (ProcessTermination{}) {
		t.Fatalf("restore = %+v, want Core's defaults", last)
	}
}
