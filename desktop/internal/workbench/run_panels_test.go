package workbench

import (
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
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
	awaitRemotePrompt(t, h, p)
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
	const lines = 200
	var text strings.Builder
	for line := range lines {
		text.WriteString("line " + strconv.Itoa(line) + "\n")
	}
	h.startRunConsole(root, text.String())
	for range 6 {
		h.settle()
	}
	rows := 0
	for _, label := range h.driver.Snapshot().Labels {
		if strings.HasPrefix(label.Value, "line ") {
			rows++
		}
	}
	if rows == 0 || rows >= lines/2 {
		t.Fatalf("the console declared %d rows for %d lines, want only the ones on screen", rows, lines)
	}
	// The console follows its output, so it opens on the newest line.
	if !h.shows("line 199") || h.shows("line 0") {
		t.Fatal("the console does not keep to the end of its output")
	}
}

func TestRunConsoleWrapSwitchBreaksLongLinesInsteadOfCuttingThem(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.output-links", outputLinkManifest, false)
	root := t.TempDir()
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemRun))
	h.startRunConsole(root, "start "+strings.Repeat("word ", 200)+"finish\nshort line\n")
	for range 6 {
		h.settle()
	}
	wrap := i18n.Shared(h.app.language(), "git.console.wrap")
	if hit := h.pageHit(wrap); hit.Role != gfx.RoleSwitch || hit.Checked {
		t.Fatalf("the wrap switch is %+v, want an unchecked switch", hit)
	}
	// Unwrapped, the long line ends in an ellipsis at the console's edge.
	if h.shows("finish") || !h.shows("…") || !h.shows("short line") {
		t.Fatal("an unwrapped long line is not cut with an ellipsis at the console's edge")
	}
	unwrapped := labelsHolding(h, "word")

	h.clickNamed(wrap)
	h.settle()
	if !h.app.runWrap || !h.pageHit(wrap).Checked {
		t.Fatal("a click on the wrap switch did not turn it on")
	}
	if !h.shows("finish") || h.shows("…") || !h.shows("short line") {
		t.Fatal("a wrapped long line does not show its end")
	}
	if wrapped := labelsHolding(h, "word"); wrapped <= unwrapped {
		t.Fatalf("the long line takes %d rows wrapped and %d unwrapped, want more wrapped", wrapped, unwrapped)
	}

	h.clickNamed(wrap)
	h.settle()
	if h.app.runWrap || h.shows("finish") || !h.shows("…") {
		t.Fatal("a second click did not cut the long line again")
	}
}

func TestRunPerformanceCollapseKeepsSummaryAndPersistsTheChoice(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.output-links", outputLinkManifest, false)
	root := t.TempDir()
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemRun))
	h.startRunConsole(root, "a running process emitted this line\n")
	p := h.app.project
	if len(p.build.runs) != 1 {
		t.Fatalf("runs = %d, want one", len(p.build.runs))
	}
	run := p.build.runs[0]
	run.addSample(pluginservice.ProcessSample{CPUPercent: 25, MemoryBytes: 96 << 20})
	h.app.invalidator.Invalidate()
	for range 6 {
		h.settle()
	}
	collapse := i18n.Shared(h.app.language(), "native.collapseSection")
	expand := i18n.Shared(h.app.language(), "native.expandSection")
	if !h.shows(h.app.text.Run.Performance.CPU("25")) || !h.shows(h.app.text.Run.Performance.Memory("96")) {
		t.Fatal("resource values are not visible while the graph is expanded")
	}
	if hit := h.pageHit(collapse); hit.Role != gfx.RoleButton {
		t.Fatalf("collapse control = %+v, want a button", hit)
	}
	h.clickNamed(collapse)
	h.settle()
	if !h.app.settings.RunPerformanceCollapsed {
		t.Fatal("the graph did not collapse")
	}
	if !h.shows(h.app.text.Run.Performance.CPU("25")) || !h.shows(h.app.text.Run.Performance.Memory("96")) || !h.shows("a running process emitted this line") {
		t.Fatal("collapsing hid the summary or output")
	}
	var saved settings
	if _, err := h.store.Load(settingsFile, &saved); err != nil || !saved.RunPerformanceCollapsed {
		t.Fatalf("collapse preference was not saved: %+v, err=%v", saved, err)
	}
	h.clickNamed(expand)
	h.settle()
	if h.app.settings.RunPerformanceCollapsed {
		t.Fatal("the graph did not expand")
	}
	if _, err := h.store.Load(settingsFile, &saved); err != nil || saved.RunPerformanceCollapsed {
		t.Fatalf("expansion preference was not saved: %+v, err=%v", saved, err)
	}
}

// labelsHolding is the number of labels on screen that hold value.
func labelsHolding(h *harness, value string) int {
	labels := 0
	for _, label := range h.driver.Snapshot().Labels {
		if strings.Contains(label.Value, value) {
			labels++
		}
	}
	return labels
}
