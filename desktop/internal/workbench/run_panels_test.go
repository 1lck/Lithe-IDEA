package workbench

import (
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
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
	// Unwrapped, the long line scrolls horizontally instead of being truncated with an ellipsis.
	if h.shows("…") || !h.shows("short line") {
		t.Fatal("an unwrapped long line should not be cut with an ellipsis")
	}
	unwrapped := labelsHolding(h, "word")

	// Horizontal wheel scrolling reaches the end of the long line.
	consoleHit := h.pageHit(h.app.text.Build.Output)
	pt := center(consoleHit.Bounds)
	if err := h.driver.Scroll(gfx.ScrollEvent{X: pt.X, Y: pt.Y, DeltaX: 10000, Precise: true}); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if !h.shows("finish") {
		t.Fatal("horizontal scrolling did not reveal the end of the unwrapped long line")
	}

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
	if h.app.runWrap || h.shows("…") {
		t.Fatal("a second click did not turn wrap back off cleanly")
	}
}

func TestRunPerformanceCollapseKeepsSummaryAndPersistsTheChoice(t *testing.T) {
	opts := debugPluginOptions(t, "dev.lithe.test.output-links", outputLinkManifest, false, &testKernel{Client: core.NewClient()}, "dark")
	h := newHarnessWithOptions(t, opts)
	root := t.TempDir()
	h.open(root)
	h.app.reduceChrome(core.ToggleChrome(itemRun))
	h.startRunConsole(root, "a running process emitted this line\n")
	p := h.app.project
	if len(p.build.runs) != 1 {
		t.Fatalf("runs = %d, want one", len(p.build.runs))
	}
	run := p.build.runs[0]
	run.addSample(pluginservice.ProcessSample{CPUPercent: 12, MemoryBytes: 64 << 20})
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
	expandedHit := h.pageHit(collapse)
	if expandedHit.Role != gfx.RoleButton || !expandedHit.Expandable || !expandedHit.Expanded {
		t.Fatalf("collapse control = %+v, want an expanded button", expandedHit)
	}
	h.click(center(expandedHit.Bounds))
	h.settle()
	if !h.app.settings.RunPerformanceCollapsed {
		t.Fatal("the graph did not collapse")
	}
	collapsedHit := h.pageHit(expand)
	if collapsedHit.Role != gfx.RoleButton || !collapsedHit.Expandable || collapsedHit.Expanded {
		t.Fatalf("expand control = %+v, want a collapsed button", collapsedHit)
	}
	if collapsedHit.ID != expandedHit.ID {
		t.Fatalf("toggle button ID changed on collapse: %v -> %v", expandedHit.ID, collapsedHit.ID)
	}
	if collapsedHit.Bounds.Y >= expandedHit.Bounds.Y-runChartHeight+1 {
		t.Fatalf("summary row Y stayed at %v (was %v), want chart row (%dpx) collapsed", collapsedHit.Bounds.Y, expandedHit.Bounds.Y, runChartHeight)
	}
	if !h.shows(h.app.text.Run.Performance.CPU("25")) || !h.shows(h.app.text.Run.Performance.Memory("96")) || !h.shows("a running process emitted this line") {
		t.Fatal("collapsing hid the summary or output")
	}
	var savedCollapsed settings
	if _, err := h.store.Load(settingsFile, &savedCollapsed); err != nil || !savedCollapsed.RunPerformanceCollapsed {
		t.Fatalf("collapse preference was not saved: %+v, err=%v", savedCollapsed, err)
	}

	// Grouped executions share the collapsed preference while keeping their own samples.
	h.app.applyRunEvent(pluginservice.RunEvent{Type: pluginservice.RunStarted, RunID: "run-second", PluginID: "dev.lithe.test.output-links", Label: "Second run", Workspace: root})
	h.settle()
	if len(p.build.runs) != 2 {
		t.Fatalf("runs = %d, want two", len(p.build.runs))
	}
	second := p.build.runs[1]
	second.addSample(pluginservice.ProcessSample{CPUPercent: 70, MemoryBytes: 128 << 20})
	h.app.invalidator.Invalidate()
	h.settle()
	if hit := h.pageHit(expand); hit.Expanded {
		t.Fatalf("second run did not share the collapsed preference: %+v", hit)
	}
	if !h.shows(h.app.text.Run.Performance.CPU("70")) || !h.shows(h.app.text.Run.Performance.Memory("128")) {
		t.Fatal("second run does not show its own resource summary")
	}
	firstNode := h.pageHit(run.label + ", " + h.app.runStatusText(run))
	h.click(center(firstNode.Bounds))
	h.settle()
	if p.activeRun() != run {
		t.Fatal("the execution tree did not select the first run")
	}
	if !h.shows(h.app.text.Run.Performance.CPU("25")) || !h.shows(h.app.text.Run.Performance.Memory("96")) {
		t.Fatal("switching back did not preserve the first run's samples")
	}

	// Reopening the workbench restores the collapsed preference from settings.json, and
	// expanding via keyboard preserves focus on the toggle button and writes false back.
	reopenOpts := opts
	reopenOpts.Kernel = &testKernel{Client: core.NewClient()}
	reopenOpts.PluginKernel = &testKernel{Client: core.NewClient()}
	reopenOpts.Store = store.At(h.store.Dir())
	reopened := newHarnessWithOptions(t, reopenOpts)
	if !reopened.app.settings.RunPerformanceCollapsed {
		t.Fatal("reopened workbench did not restore RunPerformanceCollapsed")
	}
	reopened.open(root)
	reopened.app.reduceChrome(core.ToggleChrome(itemRun))
	reopened.startRunConsole(root, "reopened output line\n")
	reopenedRun := reopened.app.project.build.runs[0]
	reopenedRun.addSample(pluginservice.ProcessSample{CPUPercent: 15, MemoryBytes: 48 << 20})
	reopenedRun.addSample(pluginservice.ProcessSample{CPUPercent: 30, MemoryBytes: 80 << 20})
	reopened.app.invalidator.Invalidate()
	for range 6 {
		reopened.settle()
	}
	reopenedCollapsedHit := reopened.pageHit(expand)
	if reopenedCollapsedHit.Expanded {
		t.Fatalf("reopened run chart started expanded: %+v", reopenedCollapsedHit)
	}
	reopened.click(center(reopened.pageHit(reopenedRun.label + ", " + reopened.app.runStatusText(reopenedRun)).Bounds))
	reopened.settle()
	for range 40 {
		if reopened.focusedName() == expand {
			break
		}
		if err := reopened.driver.Key(gfx.KeyTab, 0); err != nil {
			t.Fatal(err)
		}
	}
	if got := reopened.focusedName(); got != expand {
		t.Fatalf("Tab did not reach %q; focus is on %q", expand, got)
	}
	if err := reopened.driver.Key(gfx.KeySpace, 0); err != nil {
		t.Fatal(err)
	}
	reopened.settle()
	if reopened.app.settings.RunPerformanceCollapsed {
		t.Fatal("the graph did not expand on Space")
	}
	reopenedExpandedHit := reopened.pageHit(collapse)
	if !reopenedExpandedHit.Expanded || reopenedExpandedHit.Bounds.Y <= reopenedCollapsedHit.Bounds.Y+runChartHeight-1 {
		t.Fatalf("expanded control = %+v (was Y=%v), want chart restored", reopenedExpandedHit, reopenedCollapsedHit.Bounds.Y)
	}
	if got := reopened.driver.Snapshot().Focused; got != reopenedExpandedHit.ID {
		t.Fatalf("keyboard focus moved after expanding: got %v, want %v", got, reopenedExpandedHit.ID)
	}
	var savedExpanded settings
	if _, err := reopened.store.Load(settingsFile, &savedExpanded); err != nil || savedExpanded.RunPerformanceCollapsed {
		t.Fatalf("expansion preference was not saved: %+v, err=%v", savedExpanded, err)
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
