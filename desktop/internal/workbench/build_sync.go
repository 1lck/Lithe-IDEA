package workbench

import (
	"context"
	"errors"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// A build model load shows in the Run window as one session, as IDEA's Build window shows a
// project sync: the log of the build tool while it downloads and resolves what the project needs,
// when the load started, how long it took and how it ended, with stop and rerun. The Build tree's
// line that the model loads shows the last line the load printed and opens its session.

// buildSync is the model load a Run window session shows. Its fields belong to the window thread;
// the load's goroutine reads only stopped, through its feed.
type buildSync struct {
	// instance is the ID of the build instance whose model loads.
	instance string
	// stopped is closed when the user stops the load, and cancelled says it was.
	stopped   chan struct{}
	cancelled bool
	// latest is the last line the load printed or the provider reported, shown while it runs.
	latest string
}

// errBuildModelStopped ends a model load the user stopped.
var errBuildModelStopped = errors.New("the build model load was stopped")

// buildSyncFeed carries what a model load reports to its session, from the goroutines that read
// it to the window thread. A nil feed is a load no session shows, such as the settings' source
// editor reading a model; it drops what it is given.
type buildSyncFeed struct {
	app     *App
	project *project
	session *runEntry
	stopped <-chan struct{}
	decoder *outputDecoder
}

// beginBuildSync opens the Run window session of a model load of instance and returns its feed.
// The session is shown unless the window shows a session that runs, so a load a file change
// started never hides the run the user watches; the Run window is not brought forward.
func (a *App) beginBuildSync(p *project, instance *buildInstance) *buildSyncFeed {
	sync := &buildSync{instance: instance.ID, stopped: make(chan struct{})}
	p.build.sessions++
	session := &runEntry{
		id: "sync-" + strconv.Itoa(p.build.sessions), label: a.buildSyncLabel(instance),
		restart: reloadBuildInstance(instance.ID), sync: sync,
		running: true, started: a.now(), output: newOutputBuffer(buildOutputMaxLines, buildOutputBytes),
	}
	setRunGroupFromInstance(p, session, instance)
	shown := p.activeRun()
	a.addRunSession(p, session)
	if shown != nil && shown.running && p.runEntry(shown.id) == shown {
		p.build.view = shown.id
	}
	return &buildSyncFeed{app: a, project: p, session: session, stopped: sync.stopped, decoder: newOutputDecoder(a.kernel, a.outputEncodingPolicy())}
}

// buildSyncLabel names the session of a model load of instance: its build system, and its root
// when that is not the workspace's, so the loads of two modules have tabs of their own.
func (a *App) buildSyncLabel(instance *buildInstance) string {
	if root := buildRootDetail(instance); root != "" {
		return i18n.SharedFormat(a.language(), "desktop.build.syncSessionAt", map[string]string{"name": buildSystemName(instance), "root": root})
	}
	return i18n.SharedFormat(a.language(), "desktop.build.syncSession", map[string]string{"name": buildSystemName(instance)})
}

// reloadBuildInstance is a sync session's rerun: it loads the model of the instance again, by ID.
// An instance that is gone starts nothing, and one whose model loads already is left to it.
func reloadBuildInstance(instanceID string) func(*App, *project) {
	return func(a *App, p *project) {
		index := slices.IndexFunc(p.build.instances, func(instance buildInstance) bool { return instance.ID == instanceID })
		if index < 0 {
			a.notifyError(a.text.Build.TargetMissing)
			return
		}
		if p.build.instances[index].modelLoading {
			return
		}
		a.reloadBuildModel(p, index)
	}
}

// bind returns ctx ending also when the user stops the load, which ends the command's process
// tree or the wait for the provider. The load's goroutine calls cancel when it is done.
func (f *buildSyncFeed) bind(ctx context.Context) (context.Context, context.CancelFunc) {
	if f == nil {
		return context.WithCancel(ctx)
	}
	return bindStopped(ctx, f.stopped)
}

// stopRequested reports whether the user stopped the load.
func (f *buildSyncFeed) stopRequested() bool {
	if f == nil {
		return false
	}
	select {
	case <-f.stopped:
		return true
	default:
		return false
	}
}

// logger is output as captureBuildProcess takes it, nil for a feed that shows nothing.
func (f *buildSyncFeed) logger() func(string) {
	if f == nil {
		return nil
	}
	return f.output
}

// output adds text the load printed to its session's console, on the goroutine that read it.
func (f *buildSyncFeed) output(text string) {
	if f == nil || text == "" {
		return
	}
	f.decoder.deliver(text, func(chunk outputChunk, failure error) {
		f.app.post(func(a *App) {
			a.reportOutputStyleFailure(failure)
			a.applyBuildSyncOutput(f.project, f.session, chunk)
		})
	})
}

// status shows what the provider says the load does now as the session's latest line.
func (f *buildSyncFeed) status(message string) {
	if f == nil || message == "" {
		return
	}
	f.app.post(func(a *App) {
		if a.project == f.project && f.session.running && !f.session.sync.cancelled {
			f.session.sync.latest = message
		}
	})
}

// applyBuildSyncOutput adds decoded output to a sync session that still runs, and keeps its last
// line with text as what the load does now.
func (a *App) applyBuildSyncOutput(p *project, session *runEntry, chunk outputChunk) {
	if a.project != p || !session.running {
		return
	}
	session.output.apply(chunk)
	if line := lastOutputLine(chunk); line != "" && !session.sync.cancelled {
		session.sync.latest = line
	}
}

// lastOutputLine is the last line of chunk with text: the line still being written, else the
// last finished one; empty when it has none.
func lastOutputLine(chunk outputChunk) string {
	if text := strings.TrimSpace(chunk.open.text); text != "" {
		return text
	}
	for index := len(chunk.lines) - 1; index >= 0; index-- {
		if text := strings.TrimSpace(chunk.lines[index].text); text != "" {
			return text
		}
	}
	return ""
}

// endBuildSync records in the session how its load ended: stopped when the user stopped it,
// failed with the first line of why, or succeeded.
func (a *App) endBuildSync(session *runEntry, err error) {
	if !session.running {
		return
	}
	session.output.seal()
	session.running, session.ended, session.sync.latest = false, a.now(), ""
	switch {
	case errors.Is(err, errBuildModelStopped):
		session.outcome, session.summary = runStopped, i18n.Shared(a.language(), "desktop.build.modelStopped")
	case err != nil:
		session.outcome = runFailed
		session.summary, _, _ = strings.Cut(a.launchFailureText(err), "\n")
	default:
		session.outcome = runSucceeded
	}
}

// stopBuildSync stops the load a sync session shows; the load then ends as stopped, unless it
// already ended.
func (a *App) stopBuildSync(session *runEntry) {
	sync := session.sync
	if sync.cancelled {
		return
	}
	sync.cancelled = true
	close(sync.stopped)
	sync.latest = a.text.Build.Stopping
}

// buildSyncSession is the newest Run window session of a model load of the instance, nil when
// the window holds none.
func (p *project) buildSyncSession(instanceID string) *runEntry {
	for index := len(p.build.runs) - 1; index >= 0; index-- {
		if entry := p.build.runs[index]; entry.sync != nil && entry.sync.instance == instanceID {
			return entry
		}
	}
	return nil
}

// showBuildSync shows a sync session in the Run window and brings the window forward.
func (a *App) showBuildSync(p *project, id string) {
	if p.runEntry(id) == nil {
		return
	}
	p.build.view = id
	a.openToolWindow(itemRun)
}
