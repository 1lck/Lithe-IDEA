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
	"github.com/vivaui/viva/ui"
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
// configuration or the IDE API started (operation, while it runs), or a run a plugin
// started (pluginID). It keeps the execution's console, when it started and ended, and
// how. A plugin's process belongs to the plugin service, which also owns stopping it.
type runEntry struct {
	id string
	// pluginID is the plugin that started the run, "" for an execution of the host.
	pluginID string
	label    string
	rerun    *pluginservice.RunRerun
	// restart starts the host's execution again; nil for a plugin's run.
	restart func(*App, *project)
	// operation is the host's execution writing the session, nil once it ended.
	operation *buildOperation
	// output is the console, decoded from the execution's ANSI escapes.
	output  outputBuffer
	running bool
	outcome runOutcome
	// stopping is set when the user stopped a plugin's run, so its end reads as stopped.
	stopping       bool
	started, ended time.Time
	// summary is how the execution ended, shown under the console.
	summary string
	// list is the console's scroll state.
	list ui.ListState
	// snapshots counts the output snapshots taken of this run, so each tab has its own URI.
	snapshots int
	// samples are the process tree's CPU and memory, oldest first, bounded; stopSampling ends the sampler.
	samples      []pluginservice.ProcessSample
	stopSampling context.CancelFunc
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
			decoders.start(event.RunID, newOutputDecoder(a.kernel))
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
	selection := core.ToolchainSelection{Executable: input.Executable}
	if selection.Executable == "" {
		var err error
		selection, err = a.resolveToolchainSelection(ctx, workingDirectory, ".", input.Tool, input.MinimumVersion)
		if err != nil {
			return pluginbackend.ToolExecutable{}, err
		}
	}
	manifests, err := a.toolchainManifests(ctx)
	if err != nil {
		return pluginbackend.ToolExecutable{}, err
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
			started: a.now(), output: newOutputBuffer(runOutputMaxLines, runOutputBytes),
		}
		a.addRunSession(p, entry)
		if event.PID > 0 {
			a.startRunSampling(entry, event.PID)
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
// tab of what it repeats; past maxRunEntries the oldest finished sessions go.
func (a *App) addRunSession(p *project, entry *runEntry) {
	b := &p.build
	replaced := false
	for index, candidate := range b.runs {
		if !candidate.running && candidate.label == entry.label {
			b.runs[index], replaced = entry, true
			break
		}
	}
	if !replaced {
		b.runs = append(b.runs, entry)
	}
	for len(b.runs) > maxRunEntries {
		index := slices.IndexFunc(b.runs, func(candidate *runEntry) bool { return !candidate.running })
		if index < 0 {
			break
		}
		b.runs = slices.Delete(b.runs, index, index+1)
	}
	b.view = entry.id
}

// closeRunSession removes a finished session from the Run window; a session still running
// stays. The neighbour that takes its place is selected when it was the one shown.
func (p *project) closeRunSession(id string) {
	b := &p.build
	index := slices.IndexFunc(b.runs, func(candidate *runEntry) bool { return candidate.id == id })
	if index < 0 || b.runs[index].running {
		return
	}
	b.runs = slices.Delete(b.runs, index, index+1)
	if b.view == id {
		b.view = ""
		if len(b.runs) > 0 {
			b.view = b.runs[min(index, len(b.runs)-1)].id
		}
	}
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

// stopRun ends a session: the host's execution through the Build window's stop, a
// plugin's run through the plugin service, which stops and reaps the process tree on a
// background goroutine, so the window never waits for it.
func (a *App) stopRun(p *project, entry *runEntry) {
	if entry == nil || !entry.running {
		return
	}
	if entry.pluginID == "" {
		if entry.operation != nil && p.build.operation == entry.operation {
			a.stopBuildOperation(p)
		}
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
	if a.plugins == nil || p == nil {
		return
	}
	runs, root := a.plugins.Runs, p.root
	a.background(nil, runStopWait, func(context.Context) func(*App) {
		runs.StopWorkspace(root)
		return nil
	})
}
