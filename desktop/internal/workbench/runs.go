package workbench

import (
	"context"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/ui"
)

const (
	// runOutputMaxLines, runOutputLineSize and runOutputBytes bound one run's
	// console like the build console: whole lines, oldest dropped first.
	runOutputMaxLines = 4000
	runOutputLineSize = 16 << 10
	runOutputBytes    = 4 << 20
	// maxRunEntries bounds the finished runs the panel keeps.
	maxRunEntries = 8
	// runStopWait bounds the background stop of the runs of a closing project.
	runStopWait = 30 * time.Second
	// runRerunTimeout bounds asking the plugin to start a run again.
	runRerunTimeout = 90 * time.Second
)

// runEntry is one plugin-started run the host presents: its console, whether it is
// still going, and how it ended. The process itself belongs to the plugin
// service, which also owns stopping it.
type runEntry struct {
	id       string
	pluginID string
	label    string
	rerun    *pluginservice.RunRerun
	// output holds whole lines, oldest first; outputBytes is their size.
	output      []string
	outputBytes int
	running     bool
	// summary is how the run ended, shown under the console.
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
	runs.SetObserver(func(event pluginservice.RunEvent) {
		a.post(func(a *App) { a.applyRunEvent(event) })
	})
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
		entry := &runEntry{id: event.RunID, pluginID: event.PluginID, label: event.Label, rerun: event.Rerun, running: true}
		p.build.runs = append(p.build.runs, entry)
		if event.PID > 0 {
			a.startRunSampling(entry, event.PID)
		}
		for len(p.build.runs) > maxRunEntries {
			dropped := false
			for index, candidate := range p.build.runs {
				if !candidate.running {
					p.build.runs = append(p.build.runs[:index], p.build.runs[index+1:]...)
					dropped = true
					break
				}
			}
			if !dropped {
				break
			}
		}
		p.build.view = entry.id
		if !a.chrome.isOpen(catalogIndex[itemRun]) {
			a.reduceChrome(core.ToggleChrome(itemRun))
		}
	case pluginservice.RunOutput:
		if entry := p.runEntry(event.RunID); entry != nil {
			entry.append(event.Text)
		}
	case pluginservice.RunExited:
		entry := p.runEntry(event.RunID)
		if entry == nil {
			return
		}
		entry.running = false
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

// activeRun is the run whose console the panel shows, or nil for the build console.
func (p *project) activeRun() *runEntry {
	if p.build.view == "" {
		return nil
	}
	return p.runEntry(p.build.view)
}

// append adds console text as whole lines, trimming the oldest when over budget.
func (r *runEntry) append(text string) {
	for len(text) > 0 {
		line := text
		if index := strings.IndexByte(line, '\n'); index >= 0 {
			line = text[:index+1]
			text = text[index+1:]
		} else {
			text = ""
		}
		if len(line) > runOutputLineSize {
			line = line[:runOutputLineSize] + "\n"
		}
		r.output = append(r.output, line)
		r.outputBytes += len(line)
	}
	for len(r.output) > runOutputMaxLines || r.outputBytes > runOutputBytes {
		if len(r.output) == 0 {
			break
		}
		r.outputBytes -= len(r.output[0])
		r.output = r.output[1:]
	}
}

// snapshotRunOutput freezes the output the console holds now into a read-only tab. The
// text is copied here, so later lines, and the ring buffer dropping old ones, leave the
// tab unchanged; the tab is virtual, so it is never saved or watched and nothing closes it
// on its own.
func (a *App) snapshotRunOutput(p *project, entry *runEntry) {
	if p == nil || entry == nil || len(entry.output) == 0 {
		return
	}
	text := strings.Join(entry.output, "")
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

// stopRun asks the plugin service to end a run. The process tree is stopped and
// reaped on a background goroutine, so the window never waits for it.
func (a *App) stopRun(p *project, entry *runEntry) {
	if a.plugins == nil || entry == nil || !entry.running {
		return
	}
	runs, id := a.plugins.Runs, entry.id
	a.background(p, runStopWait, func(context.Context) func(*App) {
		runs.Stop(id)
		return nil
	})
}

// rerunRun asks the plugin to start the run again. The plugin answers with a new
// run/start, which arrives as a new entry.
func (a *App) rerunRun(p *project, entry *runEntry) {
	if a.plugins == nil || entry == nil || entry.running || entry.rerun == nil {
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
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("run_rerun", err))
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
