package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/ui/textview"
)

const (
	// runOutputMaxLines and runOutputBytes bound one run's console like the build
	// console: whole lines, oldest dropped first.
	runOutputMaxLines = 4000
	runOutputBytes    = 4 << 20
	// maxRunEntries bounds the sessions the Run window keeps; the oldest finished go first.
	maxRunEntries = 8
	// runStopWait bounds the background stop of the runs of a closing project.
	runStopWait = 30 * time.Second
	// runRerunTimeout bounds asking the plugin to start a run again.
	runRerunTimeout = 90 * time.Second
)

// runOutcome is where a session's execution stands, which its status icon shows.
type runOutcome uint8

const (
	runActive runOutcome = iota
	runSucceeded
	runFailed
	runStopped
)

// runEntry is one session of the Run window: an execution the Build window, a run
// configuration or the IDE API started (operation, while it runs), a build model load (sync),
// or a run a plugin started (pluginID). It keeps the execution's console, when it started and ended, and
// how. A plugin's process belongs to the plugin service, which also owns stopping it.
type runEntry struct {
	id string
	// pluginID is the plugin that started the run, "" for an execution of the host.
	pluginID string
	// groupID aggregates non-detached sessions from the same plugin or build system into one
	// Run window tab, named by groupLabel when two or more sessions share the tab. detached is
	// set when the user drags the session out into its own top-level tab.
	groupID    string
	groupLabel string
	detached   bool
	label      string
	rerun      *pluginservice.RunRerun
	// restart starts the host's execution again; nil for a plugin's run.
	restart func(*App, *project)
	// operation is the host's execution writing the session, nil once it ended.
	operation *buildOperation
	// sync is the build model load the session shows (build_sync.go), nil for an execution.
	sync *buildSync
	// output is the console, decoded from the execution's ANSI escapes.
	output  outputBuffer
	running bool
	// processRunning says the execution's process started: before it, the execution is still
	// being prepared (planned, compiled, asked of a provider) and the Run window shows a
	// spinner; after it, a static running mark, since a service may run for hours.
	processRunning bool
	outcome        runOutcome
	// stopping is set when the user stopped a plugin's run, so its end reads as stopped.
	stopping       bool
	started, ended time.Time
	// summary is how the execution ended, shown under the console.
	summary string
	// remote says the execution runs on a remote workspace's host, which its tab shows.
	remote bool
	// console is the console's selection and scroll state; scrollToEnd requests jumping to
	// the newest line on the next paint when horizontal scrolling owns the outer scroll area.
	console     textview.View
	scrollToEnd bool
	// snapshots counts the output snapshots taken of this run, so each tab has its own URI.
	snapshots int
	// samples are the process tree's CPU and memory, oldest first, bounded; stopSampling ends the sampler.
	samples      []pluginservice.ProcessSample
	stopSampling context.CancelFunc
	// ports holds deduplicated live TCP listeners owned by this run's process tree.
	ports          []core.ListeningPort
	portsTruncated bool
	stopPorts      context.CancelFunc
}

// wirePluginRuns connects the plugin service's run host to the window: where a
// run's tool and debug session come from, and where its events go. The events
// arrive on background goroutines and are applied on the window thread.
func (a *App) wirePluginRuns() {
	if a.plugins == nil || a.plugins.Runs == nil {
		return
	}
	runs := a.plugins.Runs
	runs.Tools = a.resolveRunTool
	runs.Debug = a.attachDebugForRun
	runs.LaunchDebug = a.launchDebugForRun
	runs.StartDebugSession = a.startDebugForBackend
	runs.StopDebugSession = a.stopDebugForBackend
	decoders := &runDecoders{byID: map[string]*outputDecoder{}}
	runs.SetObserver(func(event pluginservice.RunEvent) {
		// Output is decoded here, on the goroutine that read it, so the window thread
		// only adds the decoded lines.
		switch event.Type {
		case pluginservice.RunStarted:
			policy := a.outputEncodingPolicy()
			policy.Declared = event.OutputEncoding
			decoders.start(event.RunID, newOutputDecoder(a.kernel, policy))
		case pluginservice.RunOutput:
			if decoder := decoders.get(event.RunID); decoder != nil {
				id := event.RunID
				decoder.deliver(event.Text, func(chunk outputChunk, failure error) {
					a.post(func(a *App) {
						a.reportOutputStyleFailure(failure)
						a.applyRunOutput(id, chunk)
					})
				})
				return
			}
		case pluginservice.RunExited:
			decoders.end(event.RunID)
		}
		a.post(func(a *App) { a.applyRunEvent(event) })
	})
}

// runDecoders are the output decoders of the plugin runs that are going, by run ID. The
// plugin service's goroutines use them; the window thread never does.
type runDecoders struct {
	mu   sync.Mutex
	byID map[string]*outputDecoder
}

func (d *runDecoders) start(id string, decoder *outputDecoder) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.byID[id] = decoder
}

func (d *runDecoders) get(id string) *outputDecoder {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.byID[id]
}

func (d *runDecoders) end(id string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.byID, id)
}

// resolveRunTool resolves a tool a run needs through the same toolchain layers
// Build and Debug use: project pins, user choices, then discovery.
func (a *App) resolveRunTool(ctx context.Context, workspaceRoot, tool string) (pluginservice.RunExecutable, error) {
	selection, err := a.resolveToolchainSelection(ctx, workspaceRoot, ".", tool, "")
	if err != nil {
		return pluginservice.RunExecutable{}, err
	}
	environment := applyToolchainSelection(nil, selection)
	return pluginservice.RunExecutable{Path: selection.Executable, Environment: environment}, nil
}

// resolveBackendTool resolves the tool a plugin backend or language server launch
// names, through the same layers as a run's tool, for the workspace it serves.
func (a *App) resolveBackendTool(ctx context.Context, _, workingDirectory, tool string) (pluginbackend.ToolExecutable, error) {
	resolved, err := a.resolveRunTool(ctx, workingDirectory, tool)
	if err != nil {
		return pluginbackend.ToolExecutable{}, err
	}
	return pluginbackend.ToolExecutable{Path: resolved.Path, Environment: resolved.Environment}, nil
}

// resolveBackendToolEntry supplies native installation facts and the verified
// entry to Core. The definition, not the host, decides how a tool loads it.
func (a *App) resolveBackendToolEntry(ctx context.Context, _ string, workingDirectory string, input pluginbackend.ToolEntryLaunch) (pluginbackend.ToolExecutable, error) {
	// Share one validated manifest snapshot between the selected executable
	// and Core's launch template, including when one unrelated plugin is unreadable.
	manifests, _, err := a.usableToolchainManifests(ctx, "toolchain_run_entry_discovery")
	if err != nil {
		return pluginbackend.ToolExecutable{}, err
	}
	selection := core.ToolchainSelection{Executable: input.Executable}
	if selection.Executable == "" {
		selection, err = a.resolveToolchainSelectionFrom(ctx, workingDirectory, ".", input.Tool, input.MinimumVersion, manifests)
		if err != nil {
			return pluginbackend.ToolExecutable{}, err
		}
	}
	registry, err := toolchain.RegistryInput(manifests)
	if err != nil {
		return pluginbackend.ToolExecutable{}, err
	}
	home := ""
	if selection.Home != nil {
		home = *selection.Home
	}
	launch, err := a.kernel.InstantiateToolchainLaunch(ctx, registry, input.Tool, selection.Executable, home, input.Entry, input.RuntimeArguments, input.Arguments)
	if err != nil {
		return pluginbackend.ToolExecutable{}, err
	}
	return pluginbackend.ToolExecutable{Path: launch.Executable, Arguments: launch.Arguments, Environment: applyToolchainSelection(nil, selection)}, nil
}

// resolveLanguageTool supplies the complete installation selected by Core.
// An unavailable optional tool leaves the language server's configuration alone;
// actual I/O failures propagate to the existing server-start failure boundary.
func (a *App) resolveLanguageTool(ctx context.Context, root, tool string) (*core.ToolchainSelection, error) {
	selection, err := a.resolveToolchainSelection(ctx, root, ".", tool, "")
	var unavailable *toolchain.UnavailableError
	if errors.As(err, &unavailable) {
		// log-exempt: 预期的缺失：可选安装不存在时，不覆盖语言服务器已有配置。
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &selection, nil
}

// applyRunEvent shows one run event. Events of a workspace that is not open are
// dropped: the run keeps going, but there is nowhere to show it.
func (a *App) applyRunEvent(event pluginservice.RunEvent) {
	p := a.project
	if p == nil {
		return
	}
	switch event.Type {
	case pluginservice.RunStarted:
		if filepath.Clean(event.Workspace) != filepath.Clean(p.root) {
			return
		}
		p.links.loaded, p.links.sources = false, nil
		entry := &runEntry{
			id: event.RunID, pluginID: event.PluginID, label: event.Label, rerun: event.Rerun, running: true,
			processRunning: true, started: a.now(), output: newOutputBuffer(runOutputMaxLines, runOutputBytes),
		}
		entry.setRunGroup(event.PluginID, a.runGroupLabel(p, event.PluginID))
		a.addRunSession(p, entry)
		if event.PID > 0 {
			a.startRunSampling(entry, event.PID)
			a.startRunPortSampling(p, entry, event.PID, event.DebugPort)
		}
		a.openToolWindow(itemRun)
	case pluginservice.RunExited:
		entry := p.runEntry(event.RunID)
		if entry == nil || !entry.running {
			return
		}
		entry.output.seal()
		entry.running, entry.ended = false, a.now()
		if entry.stopSampling != nil {
			entry.stopSampling()
			entry.stopSampling = nil
		}
		stopRunPortSampling(entry)
		messages := a.text.Run
		switch {
		case event.ExitCode != nil:
			entry.summary = messages.Exited(*event.ExitCode)
		case event.Signal != "":
			entry.summary = messages.Signalled(event.Signal)
		default:
			entry.summary = messages.Ended
		}
		switch {
		case entry.stopping:
			entry.outcome = runStopped
		case event.ExitCode != nil && *event.ExitCode != 0 || event.Signal != "":
			entry.outcome = runFailed
		default:
			entry.outcome = runSucceeded
		}
	}
}

// applyRunOutput adds decoded output to the console of a plugin's run. Output of a run
// the window does not show is dropped.
func (a *App) applyRunOutput(id string, chunk outputChunk) {
	if p := a.project; p != nil {
		if entry := p.runEntry(id); entry != nil && entry.running {
			entry.output.apply(chunk)
		}
	}
}

// addRunSession shows a new session in the Run window and selects it. A finished session
// with the same label gives its tab to the new one, as running something again replaces the
// tab of what it repeats; past maxRunEntries the oldest finished sessions go, those of model
// loads first, so the loads of many modules never push out what the user ran.
func (a *App) addRunSession(p *project, entry *runEntry) {
	b := &p.build
	replaced := false
	for index, candidate := range b.runs {
		if !candidate.running && candidate.label == entry.label {
			entry.detached = candidate.detached
			if entry.groupID == "" && candidate.groupID != "" {
				entry.groupID, entry.groupLabel = candidate.groupID, candidate.groupLabel
			}
			delete(p.panels.runExpanded, candidate.id)
			b.runs[index], replaced = entry, true
			break
		}
	}
	if !replaced {
		b.runs = append(b.runs, entry)
	}
	for len(b.runs) > maxRunEntries {
		index := slices.IndexFunc(b.runs, func(candidate *runEntry) bool { return !candidate.running && candidate.sync != nil })
		if index < 0 {
			index = slices.IndexFunc(b.runs, func(candidate *runEntry) bool { return !candidate.running })
		}
		if index < 0 {
			break
		}
		delete(p.panels.runExpanded, b.runs[index].id)
		b.runs = slices.Delete(b.runs, index, index+1)
	}
	p.selectRun(entry.id)
}

// closeRunSession removes a finished session from the Run window; a session still running
// stays. When the closed session was shown, a remaining sibling in the same group tab is
// selected first, else the neighbour that takes its place.
func (p *project) closeRunSession(id string) {
	b := &p.build
	index := slices.IndexFunc(b.runs, func(candidate *runEntry) bool { return candidate.id == id })
	if index < 0 || b.runs[index].running {
		return
	}
	closed := b.runs[index]
	delete(p.panels.runExpanded, id)
	b.runs = slices.Delete(b.runs, index, index+1)
	if b.view == id {
		b.view = ""
		if closed.groupID != "" && !closed.detached {
			for i := len(b.runs) - 1; i >= 0; i-- {
				if b.runs[i].groupID == closed.groupID && !b.runs[i].detached {
					p.selectRun(b.runs[i].id)
					return
				}
			}
		}
		if len(b.runs) > 0 {
			p.selectRun(b.runs[min(index, len(b.runs)-1)].id)
		}
	}
}

// setRunGroup assigns the plugin/build-system aggregation identity for a session.
func (e *runEntry) setRunGroup(groupID, groupLabel string) {
	if e == nil || groupID == "" {
		return
	}
	e.groupID = groupID
	if groupLabel != "" {
		e.groupLabel = groupLabel
	} else {
		e.groupLabel = groupID
	}
}

// setRunGroupFromInstance assigns a session's aggregation group from its build instance.
func setRunGroupFromInstance(p *project, e *runEntry, instance *buildInstance) {
	if e == nil || instance == nil {
		return
	}
	groupID := instance.PluginID
	if groupID == "" && instance.BuildSystemID != "" {
		groupID = "build:" + instance.BuildSystemID
	}
	e.setRunGroup(groupID, buildSystemName(instance))
	if p != nil && p.build.view == e.id && e.groupID != "" && !e.detached {
		if p.panels.runGroupLast == nil {
			p.panels.runGroupLast = map[string]string{}
		}
		p.panels.runGroupLast[e.groupID] = e.id
	}
}

// runGroupLabel resolves the human-readable group tab title for a plugin ID.
func (a *App) runGroupLabel(p *project, pluginID string) string {
	if pluginID == "" {
		return ""
	}
	if p != nil {
		for i := range p.build.instances {
			if p.build.instances[i].PluginID == pluginID {
				return buildSystemName(&p.build.instances[i])
			}
		}
	}
	return pluginID
}

// runTab is one tab in the Run window header: either an aggregated group of non-detached
// sessions sharing groupID, or a single standalone/detached session.
type runTab struct {
	key      string
	groupID  string
	label    string
	detached bool
	entries  []*runEntry
}

func (t runTab) contains(id string) bool {
	for _, entry := range t.entries {
		if entry.id == id {
			return true
		}
	}
	return false
}

func (t runTab) anyRunning() bool {
	for _, entry := range t.entries {
		if entry.running {
			return true
		}
	}
	return false
}

func (t runTab) anyRemote() bool {
	for _, entry := range t.entries {
		if entry.remote {
			return true
		}
	}
	return false
}

func (t runTab) firstRunningWithPorts() *runEntry {
	for _, entry := range t.entries {
		if entry.running && len(entry.ports) > 0 {
			return entry
		}
	}
	return nil
}

func (t runTab) aggregateStatus() (running, processRunning bool, outcome runOutcome) {
	outcome = runSucceeded
	hasStopped := false
	for _, entry := range t.entries {
		if entry.running {
			running = true
			if entry.processRunning {
				processRunning = true
			}
			continue
		}
		switch entry.outcome {
		case runFailed:
			outcome = runFailed
		case runStopped:
			hasStopped = true
		}
	}
	if running {
		return true, processRunning, runActive
	}
	if outcome != runFailed && hasStopped {
		outcome = runStopped
	}
	return false, false, outcome
}

// runTabs projects p.build.runs into header tabs, preserving first-seen order. Non-detached
// sessions with the same non-empty groupID share one tab; detached or ungrouped sessions get
// their own tab. When a group tab aggregates two or more sessions, its title is groupLabel.
func (p *project) runTabs() []runTab {
	if p == nil || len(p.build.runs) == 0 {
		return nil
	}
	tabs := make([]runTab, 0, len(p.build.runs))
	groupIndex := map[string]int{}
	for _, entry := range p.build.runs {
		if entry.groupID != "" && !entry.detached {
			if idx, ok := groupIndex[entry.groupID]; ok {
				tabs[idx].entries = append(tabs[idx].entries, entry)
				continue
			}
			groupIndex[entry.groupID] = len(tabs)
			tabs = append(tabs, runTab{
				key:     "group:" + entry.groupID,
				groupID: entry.groupID,
				label:   entry.label,
				entries: []*runEntry{entry},
			})
			continue
		}
		tabs = append(tabs, runTab{
			key:      "run:" + entry.id,
			groupID:  entry.groupID,
			label:    entry.label,
			detached: entry.detached,
			entries:  []*runEntry{entry},
		})
	}
	for i := range tabs {
		if !tabs[i].detached && tabs[i].groupID != "" && len(tabs[i].entries) > 1 {
			label := tabs[i].groupID
			for _, entry := range tabs[i].entries {
				if entry.groupLabel != "" {
					label = entry.groupLabel
					break
				}
			}
			tabs[i].label = label
		}
	}
	return tabs
}

// activeRunTab returns the header tab containing the active run session, along with that session.
func (p *project) activeRunTab() (runTab, *runEntry, bool) {
	shown := p.activeRun()
	if shown == nil {
		return runTab{}, nil, false
	}
	for _, tab := range p.runTabs() {
		if tab.contains(shown.id) {
			return tab, shown, true
		}
	}
	return runTab{key: "run:" + shown.id, groupID: shown.groupID, label: shown.label, detached: shown.detached, entries: []*runEntry{shown}}, shown, true
}

// selectRun selects the given session and remembers it as the active member of its group.
func (p *project) selectRun(id string) {
	if p == nil {
		return
	}
	p.build.view = id
	entry := p.runEntry(id)
	if entry != nil && entry.groupID != "" && !entry.detached {
		if p.panels.runGroupLast == nil {
			p.panels.runGroupLast = map[string]string{}
		}
		p.panels.runGroupLast[entry.groupID] = id
	}
}

// selectRunTab selects a header tab, restoring the last viewed session in a group tab when
// still present or falling back to its newest session.
func (p *project) selectRunTab(tab runTab) {
	if p == nil || len(tab.entries) == 0 {
		return
	}
	if !tab.detached && tab.groupID != "" {
		if last := p.panels.runGroupLast[tab.groupID]; last != "" && tab.contains(last) {
			p.selectRun(last)
			return
		}
	}
	p.selectRun(tab.entries[len(tab.entries)-1].id)
}

// closeRunTab closes all finished sessions belonging to tab; does nothing if any is running.
func (p *project) closeRunTab(tab runTab) {
	if p == nil || tab.anyRunning() || len(tab.entries) == 0 {
		return
	}
	removing := make(map[string]bool, len(tab.entries))
	for _, entry := range tab.entries {
		removing[entry.id] = true
		delete(p.panels.runExpanded, entry.id)
	}
	firstRemoved := -1
	kept := p.build.runs[:0]
	for i, entry := range p.build.runs {
		if removing[entry.id] {
			if firstRemoved < 0 {
				firstRemoved = i
			}
			continue
		}
		kept = append(kept, entry)
	}
	p.build.runs = kept
	if removing[p.build.view] {
		p.build.view = ""
		if len(p.build.runs) > 0 {
			p.selectRun(p.build.runs[min(max(firstRemoved, 0), len(p.build.runs)-1)].id)
		}
	}
}

// runNodeExpanded reports whether a session node's child details are expanded in the Run tree.
func (p *project) runNodeExpanded(run *runEntry) bool {
	if p != nil && p.panels.runExpanded != nil {
		if open, ok := p.panels.runExpanded[run.id]; ok {
			return open
		}
	}
	return run != nil && run.running && len(run.ports) > 0
}

// toggleRunNodeExpanded flips a session node's expanded state in the Run tree.
func (p *project) toggleRunNodeExpanded(run *runEntry) {
	if p == nil || run == nil {
		return
	}
	if p.panels.runExpanded == nil {
		p.panels.runExpanded = map[string]bool{}
	}
	p.panels.runExpanded[run.id] = !p.runNodeExpanded(run)
}

// detachRunSession moves a grouped session out into its own top-level tab, optionally placing
// it before the tab at beforeTabIndex (-1 appends at the end).
func (p *project) detachRunSession(id string, beforeTabIndex int) {
	if p == nil {
		return
	}
	entry := p.runEntry(id)
	if entry == nil {
		return
	}
	entry.detached = true
	if beforeTabIndex >= 0 {
		p.reorderRunTab("run:"+entry.id, beforeTabIndex)
	}
	p.selectRun(entry.id)
}

// mergeRunSessions merges detached sessions back into their plugin group tab.
func (p *project) mergeRunSessions(ids ...string) {
	if p == nil {
		return
	}
	var last string
	for _, id := range ids {
		entry := p.runEntry(id)
		if entry == nil || entry.groupID == "" {
			continue
		}
		entry.detached = false
		last = entry.id
	}
	if last != "" {
		p.selectRun(last)
	}
}

// reorderRunTab moves all entries of the tab named tabKey to appear before beforeTabIndex
// in the tab bar order.
func (p *project) reorderRunTab(tabKey string, beforeTabIndex int) {
	if p == nil {
		return
	}
	tabs := p.runTabs()
	srcIdx := slices.IndexFunc(tabs, func(t runTab) bool { return t.key == tabKey })
	if srcIdx < 0 {
		return
	}
	if beforeTabIndex < 0 || beforeTabIndex > len(tabs) {
		beforeTabIndex = len(tabs)
	}
	if beforeTabIndex == srcIdx || beforeTabIndex == srcIdx+1 {
		return
	}
	moving := tabs[srcIdx]
	without := append(append([]runTab(nil), tabs[:srcIdx]...), tabs[srcIdx+1:]...)
	if beforeTabIndex > srcIdx {
		beforeTabIndex--
	}
	ordered := make([]runTab, 0, len(tabs))
	ordered = append(ordered, without[:beforeTabIndex]...)
	ordered = append(ordered, moving)
	ordered = append(ordered, without[beforeTabIndex:]...)
	rebuilt := make([]*runEntry, 0, len(p.build.runs))
	for _, tab := range ordered {
		rebuilt = append(rebuilt, tab.entries...)
	}
	p.build.runs = rebuilt
}

func (p *project) runEntry(id string) *runEntry {
	for _, entry := range p.build.runs {
		if entry.id == id {
			return entry
		}
	}
	return nil
}

// activeRun is the session the Run window shows: the selected one, else the newest, or
// nil when it has none.
func (p *project) activeRun() *runEntry {
	if entry := p.runEntry(p.build.view); entry != nil {
		return entry
	}
	if len(p.build.runs) > 0 {
		return p.build.runs[len(p.build.runs)-1]
	}
	return nil
}

// snapshotRunOutput freezes the output the console holds now into a read-only tab. The
// text is copied here, so later lines, and the ring buffer dropping old ones, leave the
// tab unchanged; the tab is virtual, so it is never saved or watched and nothing closes it
// on its own.
func (a *App) snapshotRunOutput(p *project, entry *runEntry) {
	if p == nil || entry == nil || entry.output.empty() {
		return
	}
	text := entry.output.all()
	entry.snapshots++
	uri := "lithe-run-snapshot:" + entry.id + "/" + strconv.Itoa(entry.snapshots)
	content := editorview.Prepare([]byte(text))
	grammar := a.syntaxRegistry().Syntax("")
	a.placeDocumentAs(p, uri, a.text.Run.Snapshot.Tab(entry.label), content, grammar, "", true)
	// Pinned at creation: the tab limit never closes a snapshot.
	if d := p.docs.byPath(uri); d != nil {
		a.reduceTerminals(p, p.terms.bench, core.PinEditorEverywhere(documentMember(d.id), true))
	}
}

// stopRun ends a session: the host's execution through the Build window's stop, a model
// load by ending its load, a plugin's run through the plugin service, which stops and reaps
// the process tree on a background goroutine, so the window never waits for it.
func (a *App) stopRun(p *project, entry *runEntry) {
	if entry == nil || !entry.running {
		return
	}
	if entry.sync != nil {
		a.stopBuildSync(entry)
		return
	}
	if entry.pluginID == "" {
		a.stopOperation(p, entry.operation)
		return
	}
	if a.plugins == nil {
		return
	}
	entry.stopping = true
	runs, id := a.plugins.Runs, entry.id
	a.background(p, runStopWait, func(context.Context) func(*App) {
		runs.Stop(id)
		return nil
	})
}

// rerunRun starts a finished session again: the host's execution through what started it,
// a plugin's run by asking the plugin, which answers with a new run/start that arrives as
// a new session in the old one's tab.
func (a *App) rerunRun(p *project, entry *runEntry) {
	if entry == nil || entry.running {
		return
	}
	if entry.restart != nil {
		entry.restart(a, p)
		return
	}
	if a.plugins == nil || entry.rerun == nil {
		return
	}
	runs, rerun := a.plugins.Runs, *entry.rerun
	// The rerun starts a process on the files on disk, so save first.
	a.saveProjectDocuments(p, func(ok bool) {
		if !ok {
			return
		}
		a.background(p, runRerunTimeout, func(ctx context.Context) func(*App) {
			if err := runs.Rerun(ctx, rerun); err != nil {
				return func(a *App) {
					a.operationFailed("run_rerun", err)
				}
			}
			return nil
		})
	})
}

// stopRunsForProject ends every run of a closing project. The wait is bounded and
// off the window thread; the shutdown path waits for background tasks.
func (a *App) stopRunsForProject(p *project) {
	if p == nil {
		return
	}
	for _, entry := range p.build.runs {
		if entry.stopSampling != nil {
			entry.stopSampling()
			entry.stopSampling = nil
		}
		stopRunPortSampling(entry)
	}
	if a.plugins == nil {
		return
	}
	runs, root := a.plugins.Runs, p.root
	a.background(nil, runStopWait, func(context.Context) func(*App) {
		runs.StopWorkspace(root)
		return nil
	})
}
