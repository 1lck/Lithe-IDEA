package workbench

import (
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// The Run, Tests and Debug tool windows are Pages drawn into the Frame window, so
// these tests drive them as a person does: they find controls by name, click, type
// and press keys through the headless driver, and read what the model says after.

// openAttachPanel opens the Debug tool window over the attach-only adapter.
func openAttachPanel(t *testing.T) (*harness, *project) {
	t.Helper()
	h := debugPluginHarness(t, "dev.lithe.test.debug-attach", debugAttachManifest, true)
	root, _ := fixtureWorkspace(t)
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemDebug))
	for range 4 {
		h.settle()
	}
	p := h.app.project
	if len(p.debug.adapters) != 1 || !debugAttachOnly(p.debug.adapters[0]) {
		t.Fatalf("adapters = %+v, want the attach-only adapter", p.debug.adapters)
	}
	return h, p
}

func TestDebugAttachFieldsTakeTypingThroughThePage(t *testing.T) {
	h, _ := openAttachPanel(t)
	debug := h.app.text.Debug
	h.clickNamed(debug.AttachHost)
	if err := h.driver.Type("db.example.test"); err != nil {
		t.Fatal(err)
	}
	h.clickNamed(debug.AttachPort)
	if err := h.driver.Type("5005"); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if host, port := h.app.debugAttach.host.Text(), h.app.debugAttach.port.Text(); host != "db.example.test" || port != "5005" {
		t.Fatalf("attach fields = %q, %q, want what was typed into them", host, port)
	}
}

func TestDebugRemotePromptEscapeRefusesTheAttach(t *testing.T) {
	h, p := openAttachPanel(t)
	h.app.debugAttach.host.SetText("debug.example.test")
	h.app.debugAttach.port.SetText("5005")
	h.app.startDebug(p)
	awaitStateWithin(t, h, 20*time.Second, "the confirmation", func() bool { return p.debug.remote != nil })
	h.settle()
	h.pageHit(h.app.text.Debug.RemoteAttach)
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if p.debug.remote != nil || p.debug.activeSession() != nil {
		t.Fatalf("Escape on the confirmation did not refuse the attach: remote=%v session=%v", p.debug.remote, p.debug.activeSession())
	}
	if _, ok := h.findPageHit(h.app.text.Debug.RemoteAttach); ok {
		t.Fatal("the confirmation stays on screen after it was refused")
	}
}

func TestRunConsoleDeclaresOnlyTheRowsOnScreen(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.output-links", outputLinkManifest, false)
	root := t.TempDir()
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemRun))
	var text strings.Builder
	for line := range buildOutputVisible {
		text.WriteString("line " + strconv.Itoa(line) + "\n")
	}
	h.startRunConsole(root, text.String())
	for range 6 {
		h.settle()
	}
	rows := 0
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Role == gfx.RoleOption {
			rows++
		}
	}
	if rows == 0 || rows >= buildOutputVisible/2 {
		t.Fatalf("the console declared %d rows for %d lines, want only the ones on screen", rows, buildOutputVisible)
	}
	// The console keeps the last buildOutputVisible lines of the text, which end
	// in a newline, so the oldest of ours is the first it drops.
	if !h.shows("line 1") {
		t.Fatal("the console does not show the start of its output")
	}
}
