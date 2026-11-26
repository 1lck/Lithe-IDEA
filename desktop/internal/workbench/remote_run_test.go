package workbench

import (
	"cmp"
	"context"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

// remoteTestRunScratch is the temporary folder the host makes for a run's script.
const remoteTestRunScratch = "/tmp/lithe-run-script-1"

// remoteHostRuns stands in for Core's run configurations of the workspace and the host's
// processes (remote.runProcess, remote.attachProcess): a process prints remoteHostRunOutput and
// exits with exit, or, with hold, runs until it is signalled, the connection of its session breaks
// or its request ends. Receiving it again prints remoteHostAttachOutput and ends the same way.
type remoteHostRuns struct {
	mu sync.Mutex
	// configurations are what Core resolves, and plan is the launch plan of each.
	configurations []core.RunConfiguration
	plan           core.RunLaunchPlan
	// steps are the before-launch steps of every configuration.
	steps []core.RunBeforeLaunchItem
	// exit is how a process that is not held ends; hold keeps it running.
	exit core.RemoteProcessExit
	hold bool
	// bases are the inline script bases the plans were asked with; opens the processes the host
	// started and sessions their sessions; removed the paths removed; kills the signals sent,
	// as "term" or "kill".
	bases, sessions, removed, kills []string
	opens                           []core.RemoteProcessOpen
	// scripts are what the script a process ran held when the process started.
	scripts []string
	// signalled ends a held process.
	signalled chan struct{}
	// ended is closed once a process's request returned.
	ended chan struct{}
	// drops are closed once the connection of their session broke (breakConnection).
	drops map[string]chan struct{}
	// attaches are the sessions remote.attachProcess went over; attachTruncated says output was
	// lost before the request; attachErr refuses it; attachOutput, when set, is what the process
	// prints once received instead of remoteHostAttachOutput.
	attaches        []string
	attachTruncated bool
	attachErr       error
	attachOutput    string
}

// remoteHostAttachOutput is what a host process prints once it is received again.
const remoteHostAttachOutput = "after the reconnection\n"

// remoteTestConnectionClosed is how a request over a broken connection ends.
var remoteTestConnectionClosed = &core.Error{Command: "remote.runProcess", Code: core.CodeConnectionClosed, Message: "closed"}

// dropped is closed once the connection of session broke. It runs under r.mu.
func (r *remoteHostRuns) dropped(session string) chan struct{} {
	if r.drops == nil {
		r.drops = map[string]chan struct{}{}
	}
	if r.drops[session] == nil {
		r.drops[session] = make(chan struct{})
	}
	return r.drops[session]
}

// broken reports whether the connection of session broke. It runs under r.mu.
func (r *remoteHostRuns) broken(session string) bool {
	select {
	case <-r.dropped(session):
		return true
	default:
		return false
	}
}

// breakConnection breaks the SSH connection of session under the host's processes: the requests
// over it end with a closed connection, as Core's do, and so does every later one.
func (k *remoteHostKernel) breakConnection(session string) {
	r := &k.runs
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.broken(session) {
		close(r.dropped(session))
	}
}

// heldProcess waits for a held process to end: SIGTERM through signalled, a broken connection
// through drop, or its request through ctx.
func heldProcess(ctx context.Context, signalled, drop <-chan struct{}) (core.RemoteProcessExit, error) {
	select {
	case <-signalled:
		signal := 15
		return core.RemoteProcessExit{Signal: &signal}, nil
	case <-drop:
		return core.RemoteProcessExit{}, remoteTestConnectionClosed
	case <-ctx.Done():
		return core.RemoteProcessExit{}, ctx.Err()
	}
}

// remoteHostRunOutput is what a host process prints.
const remoteHostRunOutput = "hello from the host\n"

func (k *remoteHostKernel) ResolveRunConfigurations(context.Context, string, []core.RunInstalledPlugin) (core.RunConfigResolution, error) {
	r := &k.runs
	r.mu.Lock()
	defer r.mu.Unlock()
	return core.RunConfigResolution{Configurations: append([]core.RunConfiguration(nil), r.configurations...)}, nil
}

func (k *remoteHostKernel) RunConfigurationTypes(context.Context, *core.RunTypePlugins) ([]core.RunConfigurationType, []core.RunTypeLocalization, error) {
	return []core.RunConfigurationType{}, nil, nil
}

func (k *remoteHostKernel) RunBeforeLaunch(context.Context, string, string, *core.RunTypePlugins) (core.RunBeforeLaunch, error) {
	r := &k.runs
	r.mu.Lock()
	defer r.mu.Unlock()
	return core.RunBeforeLaunch{Status: "ok", Steps: r.steps}, nil
}

func (k *remoteHostKernel) CreateRunLaunchPlan(_ context.Context, _, _, base string) (core.RunLaunchPlan, error) {
	r := &k.runs
	r.mu.Lock()
	defer r.mu.Unlock()
	r.bases = append(r.bases, base)
	plan := r.plan
	if plan.InlineScript != nil {
		script := *plan.InlineScript
		script.Path = base + ".sh"
		plan.InlineScript = &script
		plan.Arguments = []string{script.Path}
	}
	return plan, nil
}

func (k *remoteHostKernel) RemoteTempDirectory(_ context.Context, _, prefix string) (string, error) {
	if prefix != remoteRunScratchPrefix {
		return "", &core.Error{Command: "remote.hostRequest", Code: core.CodeInvalidRequest, Message: "unexpected prefix"}
	}
	return remoteTestRunScratch, nil
}

func (k *remoteHostKernel) RemoteRemove(_ context.Context, session, path string, recursive bool) error {
	k.mu.Lock()
	if err := k.takeFileError(session); err != nil {
		k.mu.Unlock()
		return err
	}
	delete(k.files, path)
	delete(k.fsOps.dirs, path)
	for name := range k.files {
		if strings.HasPrefix(name, path+"/") {
			delete(k.files, name)
		}
	}
	for dir := range k.fsOps.dirs {
		if strings.HasPrefix(dir, path+"/") {
			delete(k.fsOps.dirs, dir)
		}
	}
	k.fsOps.removed = append(k.fsOps.removed, path)
	k.syncRemoteTreeLocked()
	k.mu.Unlock()
	r := &k.runs
	r.mu.Lock()
	defer r.mu.Unlock()
	if recursive {
		r.removed = append(r.removed, path)
	}
	return nil
}

func (k *remoteHostKernel) RemoteRunProcess(ctx context.Context, session string, open core.RemoteProcessOpen, events core.RemoteProcessEvents) (core.RemoteProcessExit, error) {
	script, written := "", false
	if len(open.Argv) > 1 {
		script, written = k.file(open.Argv[1])
	}
	r := &k.runs
	r.mu.Lock()
	r.opens, r.sessions = append(r.opens, open), append(r.sessions, session)
	if written {
		r.scripts = append(r.scripts, script)
	}
	exit, hold, signalled, ended, drop := r.exit, r.hold, r.signalled, r.ended, r.dropped(session)
	r.mu.Unlock()
	if ended != nil {
		defer close(ended)
	}
	events.Started(7, 4242)
	events.Output("stdout", []byte(remoteHostRunOutput))
	if !hold {
		return exit, nil
	}
	return heldProcess(ctx, signalled, drop)
}

func (k *remoteHostKernel) RemoteAttachProcess(ctx context.Context, session string, processID uint64, events core.RemoteProcessEvents) (core.RemoteProcessExit, error) {
	r := &k.runs
	r.mu.Lock()
	r.attaches = append(r.attaches, session)
	exit, hold, signalled, drop, truncated, err := r.exit, r.hold, r.signalled, r.dropped(session), r.attachTruncated, r.attachErr
	output := cmp.Or(r.attachOutput, remoteHostAttachOutput)
	broken := r.broken(session)
	r.mu.Unlock()
	switch {
	case broken:
		return core.RemoteProcessExit{}, remoteTestConnectionClosed
	case err != nil:
		return core.RemoteProcessExit{}, err
	case processID != 7:
		return core.RemoteProcessExit{}, &core.Error{Command: "remote.attachProcess", Code: core.CodeRemoteProcessGone, Message: "gone"}
	}
	events.Attached(truncated)
	events.Output("stdout", []byte(output))
	if !hold {
		return exit, nil
	}
	return heldProcess(ctx, signalled, drop)
}

func (k *remoteHostKernel) RemoteProcessKill(_ context.Context, session string, processID uint64, force bool) error {
	r := &k.runs
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.broken(session) {
		return remoteTestConnectionClosed
	}
	if processID != 7 {
		return nil
	}
	if force {
		r.kills = append(r.kills, "kill")
	} else {
		r.kills = append(r.kills, "term")
	}
	if r.signalled != nil {
		close(r.signalled)
		r.signalled = nil
	}
	return nil
}

// setRuns changes the host's runs under their lock.
func (k *remoteHostKernel) setRuns(change func(r *remoteHostRuns)) {
	k.runs.mu.Lock()
	defer k.runs.mu.Unlock()
	change(&k.runs)
}

// hostRuns is a copy of what the host's runs were asked.
func (k *remoteHostKernel) hostRuns() (opens []core.RemoteProcessOpen, sessions, bases, removed, kills []string) {
	k.runs.mu.Lock()
	defer k.runs.mu.Unlock()
	r := &k.runs
	return append(opens, r.opens...), append(sessions, r.sessions...), append(bases, r.bases...), append(removed, r.removed...), append(kills, r.kills...)
}

// remoteTestRunConfiguration is the built-in shell run the workspace keeps.
var remoteTestRunConfiguration = core.RunConfiguration{ID: "greet", Name: "Greet", Provider: runProviderShell}

// openRemoteRunProject opens the remote workspace with one shell run saved as text, whose plan
// runs its script in src, and waits until the configurations are listed.
func openRemoteRunProject(t *testing.T) (*harness, *remoteHostKernel, *project, *treeRecordingLog) {
	t.Helper()
	h, k, _, p, logger := openRemoteRunProjectTimed(t)
	return h, k, p, logger
}

// openRemoteRunProjectTimed is openRemoteRunProject that also gives the workspace's timers.
func openRemoteRunProjectTimed(t *testing.T) (*harness, *remoteHostKernel, *remoteTimers, *project, *treeRecordingLog) {
	t.Helper()
	h, k, timers, logger := remoteWorkspaceHarness(t)
	k.setRuns(func(r *remoteHostRuns) {
		r.configurations = []core.RunConfiguration{remoteTestRunConfiguration}
		zero := 0
		r.exit = core.RemoteProcessExit{ExitCode: &zero}
		r.plan = core.RunLaunchPlan{
			Executable:       core.RunPlanExecutable{Command: "sh"},
			WorkingDirectory: "src",
			Environment:      map[string]string{"FROM_PLAN": "1"},
			Env:              map[string]string{"FROM_CONFIG": "2"},
			InlineScript:     &core.RunInlineScript{Content: "echo hi\n"},
		}
	})
	p := h.openRemoteTestProject(t)
	h.app.post(func(a *App) { a.loadBuildSystems(p) })
	h.await("the remote workspace's run configurations", func() bool {
		return p.runConfigs.generation > 0 && !p.runConfigs.loading && len(p.runConfigs.list) == 1
	})
	return h, k, timers, p, logger
}

// startHeldRemoteRun starts the configuration with a process that runs until it is signalled and
// waits until the run has it.
func (h *harness) startHeldRemoteRun(k *remoteHostKernel, p *project) *buildOperation {
	h.t.Helper()
	k.setRuns(func(r *remoteHostRuns) { r.hold, r.signalled = true, make(chan struct{}) })
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	var op *buildOperation
	h.await("the held run to start", func() bool {
		op = p.build.runOf(configurationRunKey(remoteTestRunConfiguration.ID))
		return op != nil && op.process != nil
	})
	return op
}

// breakRunConnection breaks the connection of the workspace's session under op's process and
// waits until op's console says it waits for the workspace to connect again.
func (h *harness) breakRunConnection(k *remoteHostKernel, p *project, op *buildOperation) {
	h.t.Helper()
	waiting := i18n.Shared(h.app.language(), "desktop.run.remote.waiting")
	k.breakConnection(p.remote.session)
	h.await("the run to wait for the connection", func() bool { return strings.Contains(op.session.output.all(), waiting) })
}

// reconnectWhileRunning runs the pause before the first attempt to connect again, as
// fireReconnect does, and waits for the new session without waiting for every background task:
// a run that waits for the connection is one until the session comes.
func (h *harness) reconnectWhileRunning(t *testing.T, timers *remoteTimers, r *remoteProject) {
	t.Helper()
	h.await("the pause before connecting again", func() bool {
		return r.session == "" && len(r.delays) > 0 && r.attempt == 0 && timers.live() == 1
	})
	timer := timers.take(t)
	if timer.after != time.Second {
		t.Fatalf("paused %v before connecting again, want Core's first pause of 1s", timer.after)
	}
	timer.run()
	h.await("the new session", func() bool { return r.session != "" })
}

// remoteAttaches are the sessions remote.attachProcess went over.
func (k *remoteHostKernel) remoteAttaches() []string {
	k.runs.mu.Lock()
	defer k.runs.mu.Unlock()
	return slices.Clone(k.runs.attaches)
}

// startRemoteRun starts the configuration as the title bar's Run does, without the trust
// question the folder's safe mode asks first.
func (h *harness) startRemoteRun(p *project, id string) {
	h.app.post(func(a *App) {
		if _, err := a.startRunConfiguration(p, id); err == nil {
			a.showBuildConsole(p)
		}
	})
}

// awaitRemoteRun waits until a run labelled label other than previous ended and returns it.
func (h *harness) awaitRemoteRun(p *project, label string, previous *runEntry) *runEntry {
	h.t.Helper()
	var found *runEntry
	h.await("the remote run of "+label, func() bool {
		for _, entry := range p.build.runs {
			if entry != previous && entry.label == label && !entry.running && !p.build.active() {
				found = entry
				return true
			}
		}
		return false
	})
	return found
}

// A remote workspace's built-in run starts on the host over the workspace's session: Core plans
// it with a host script base, the script is written below the host's temporary folder, the
// process starts in the host folder's working directory with the plan's environment over the
// login one, and its output reaches the Run window, whose tab says it runs on the host. The
// temporary folder is removed once the run ended. The Run window is not the local-only notice.
// Neither the host nor its paths are logged.
func TestRemoteWorkspaceRunsBuiltInConfigurationsOnTheHost(t *testing.T) {
	h, k, p, logger := openRemoteRunProject(t)
	lang := h.app.language()
	if p.build.failed != i18n.Shared(lang, "desktop.run.remote.buildTools") {
		t.Fatal("the run configuration menu does not say build tools do not work here")
	}

	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	run := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
	if run.outcome != runSucceeded || !strings.Contains(run.output.all(), "hello from the host") {
		t.Fatalf("the run ended %v: %s; console:\n%s", run.outcome, run.summary, run.output.all())
	}
	if !run.remote {
		t.Fatal("the Run window's tab does not say the program runs on the host")
	}
	opens, sessions, bases, removed, _ := k.hostRuns()
	if len(opens) != 1 || sessions[0] != p.remote.session {
		t.Fatalf("the host started %d processes over the workspace's session %v", len(opens), len(sessions) == 1 && sessions[0] == p.remote.session)
	}
	open := opens[0]
	script := remoteTestRunScratch + "/script.sh"
	if len(bases) != 1 || bases[0] != remoteTestRunScratch+"/script" {
		t.Fatal("Core did not plan the script below the host's temporary folder")
	}
	if strings.Join(open.Argv, " ") != "sh "+script || open.Cwd != remoteTestFolder+"/src" || open.Environment != core.RemoteProcessEnvironmentLogin {
		t.Fatalf("the process started with %d arguments, cwd matched %v, environment %q", len(open.Argv), open.Cwd == remoteTestFolder+"/src", open.Environment)
	}
	if open.Env["FROM_PLAN"] != "1" || open.Env["FROM_CONFIG"] != "2" || open.Label == nil || open.Label.Kind != "run" || open.Label.Name != "Greet" {
		t.Fatalf("the process started with %d variables and label %v", len(open.Env), open.Label != nil)
	}
	var written []string
	k.setRuns(func(r *remoteHostRuns) { written = r.scripts })
	if len(written) != 1 || written[0] != "echo hi\n" {
		t.Fatal("the script was not written on the host")
	}
	if _, kept := k.file(script); kept {
		t.Fatal("the script was left on the host")
	}
	if len(removed) != 1 || removed[0] != remoteTestRunScratch {
		t.Fatalf("the host's temporary folder was removed %d times", len(removed))
	}

	h.app.openToolWindow(itemRun)
	h.redraw()
	if h.showsWrapped(i18n.Shared(lang, "desktop.remote.workspace.localOnly")) {
		t.Fatal("the Run window says it does not work in a remote workspace")
	}
	if !h.shows(i18n.Shared(lang, "desktop.run.remote.badge")) {
		t.Fatal("the Run window's tab shows no host badge")
	}
	sessionKept(t, logger, p, p.remote.session)
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A run that exits with a code fails with it, and one a signal ended says which. Stopping a run
// sends the host process SIGTERM first; the run ends once the host reports the process gone.
func TestRemoteWorkspaceRunEndsAsTheHostProcessEnds(t *testing.T) {
	previous := buildprocess.StopGrace()
	t.Cleanup(func() { buildprocess.SetStopGrace(previous) })
	// The window sets the stop time from the setting when it opens; the harness never opens one.
	buildprocess.SetStopGrace(8 * time.Second)
	h, k, p, logger := openRemoteRunProject(t)
	three := 3
	k.setRuns(func(r *remoteHostRuns) { r.exit = core.RemoteProcessExit{ExitCode: &three} })
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	failed := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
	if failed.outcome != runFailed || failed.summary != h.app.text.Run.Exited(3) {
		t.Fatalf("an exit code of 3 ended the run %v: %q", failed.outcome, failed.summary)
	}

	ended := make(chan struct{})
	k.setRuns(func(r *remoteHostRuns) { r.hold, r.signalled, r.ended = true, make(chan struct{}), ended })
	h.app.post(func(a *App) { p.closeRunSession(failed.id) })
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	h.await("the held run to start", func() bool {
		run := p.build.runOf(configurationRunKey(remoteTestRunConfiguration.ID))
		return run != nil && run.process != nil
	})
	h.app.post(func(a *App) { a.stopOperation(p, p.build.runOf(configurationRunKey(remoteTestRunConfiguration.ID))) })
	h.await("stopping the run to end the host process", func() bool {
		select {
		case <-ended:
			return true
		default:
			return false
		}
	})
	stopped := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, failed)
	if _, _, _, _, kills := k.hostRuns(); len(kills) == 0 || kills[0] != "term" {
		t.Fatalf("the stop sent %v, want SIGTERM first", kills)
	}
	if stopped.outcome == runSucceeded {
		t.Fatal("a stopped run ended as succeeded")
	}
	sessionKept(t, logger, p, p.remote.session)
}

// A run whose connection breaks waits in its console for the workspace to connect again. When the
// workspace resumes the host session, the run receives its process again over the new session,
// says so, says the output the host could not keep is lost, and goes on until the process exits;
// the host's temporary folder is then removed over the new session. Neither the host nor its paths
// are logged.
func TestRemoteWorkspaceRunFollowsItsProcessAcrossAReconnection(t *testing.T) {
	h, k, timers, p, logger := openRemoteRunProjectTimed(t)
	lang := h.app.language()
	k.set(func(k *remoteHostKernel) { k.close.resumable = true })
	op := h.startHeldRemoteRun(k, p)
	k.setRuns(func(r *remoteHostRuns) { r.hold, r.attachTruncated = false, true })
	h.breakRunConnection(k, p, op)
	if op.cancelled || p.build.runOf(configurationRunKey(remoteTestRunConfiguration.ID)) != op {
		t.Fatal("the broken connection ended the run")
	}
	h.reconnectWhileRunning(t, timers, p.remote)
	run := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
	console := run.output.all()
	if run.outcome != runSucceeded {
		t.Fatalf("the run ended %v: %s; console:\n%s", run.outcome, run.summary, console)
	}
	at := -1
	for _, want := range []string{
		remoteHostRunOutput,
		i18n.Shared(lang, "desktop.run.remote.waiting"),
		i18n.Shared(lang, "desktop.run.remote.resumed"),
		i18n.Shared(lang, "desktop.run.remote.outputLost"),
		remoteHostAttachOutput,
	} {
		next := strings.Index(console, want)
		if next <= at {
			t.Fatalf("the console does not continue with %q:\n%s", want, console)
		}
		at = next
	}
	if got := k.remoteAttaches(); !slices.Equal(got, []string{"session-2"}) || p.remote.session != "session-2" {
		t.Fatalf("received the process again %d times, over the new session %v", len(got), slices.Equal(got, []string{"session-2"}))
	}
	if _, _, _, removed, _ := k.hostRuns(); len(removed) != 1 || removed[0] != remoteTestRunScratch {
		t.Fatalf("the host's temporary folder was removed %d times", len(removed))
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A run whose process cannot be received after the connection broke fails with why: the
// workspace connected to a new host session, the host no longer has the process, or another
// window receives it.
func TestRemoteWorkspaceRunEndsWhenItsProcessCannotBeReceivedAgain(t *testing.T) {
	for _, c := range []struct {
		name      string
		resumable bool
		refusal   core.ErrorCode
		want      string
	}{
		{name: "new session", want: "desktop.run.remote.sessionEnded"},
		{name: "process gone", resumable: true, refusal: core.CodeRemoteProcessGone, want: "desktop.run.remote.processGone"},
		{name: "received elsewhere", resumable: true, refusal: core.CodeRemoteProcessAttached, want: "desktop.run.remote.attachedElsewhere"},
	} {
		t.Run(c.name, func(t *testing.T) {
			h, k, timers, p, _ := openRemoteRunProjectTimed(t)
			k.set(func(k *remoteHostKernel) { k.close.resumable = c.resumable })
			if c.refusal != "" {
				k.setRuns(func(r *remoteHostRuns) {
					r.attachErr = &core.Error{Command: "remote.attachProcess", Code: c.refusal, Message: "refused"}
				})
			}
			op := h.startHeldRemoteRun(k, p)
			h.breakRunConnection(k, p, op)
			h.reconnectWhileRunning(t, timers, p.remote)
			run := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
			if want := h.app.text.Build.ProcessFailed(i18n.Shared(h.app.language(), c.want)); run.outcome != runFailed || run.summary != want {
				t.Fatalf("the run ended %v: %q, want %q", run.outcome, run.summary, want)
			}
			if attaches := k.remoteAttaches(); (len(attaches) == 1) != c.resumable {
				t.Fatalf("asked the host for the process %d times", len(attaches))
			}
		})
	}
}

// Stopping a run while its connection is broken ends the run at once; the host, which could not
// be asked, kills the process once the workspace resumes the host session. The stop the broken
// connection refused is not logged as a failure.
func TestRemoteWorkspaceRunStoppedWhileDisconnectedEndsOnceReconnected(t *testing.T) {
	previous := buildprocess.StopGrace()
	t.Cleanup(func() { buildprocess.SetStopGrace(previous) })
	buildprocess.SetStopGrace(8 * time.Second)
	h, k, timers, p, logger := openRemoteRunProjectTimed(t)
	k.set(func(k *remoteHostKernel) { k.close.resumable = true })
	op := h.startHeldRemoteRun(k, p)
	h.breakRunConnection(k, p, op)
	h.app.post(func(a *App) { a.stopOperation(p, op) })
	stopped := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
	if stopped.outcome == runSucceeded {
		t.Fatal("a stopped run ended as succeeded")
	}
	if _, _, _, _, kills := k.hostRuns(); len(kills) != 0 {
		t.Fatalf("sent %d signals over the broken connection", len(kills))
	}
	h.reconnectWhileRunning(t, timers, p.remote)
	h.await("the stopped run's process to be killed", func() bool {
		_, _, _, _, kills := k.hostRuns()
		return slices.Equal(kills, []string{"kill"})
	})
	if n := countFailures(logger, "run_stop") + countFailures(logger, "run_stop_after_reconnect"); n != 0 || len(k.remoteAttaches()) != 0 {
		t.Fatalf("logged %d stop failures, received the process again %d times", n, len(k.remoteAttaches()))
	}
}

// A remote workspace refuses, with its reason, what it cannot run on the host yet: a
// configuration whose before-launch list names a plugin's task, a debug session and a program
// chosen through a toolchain. None of them starts a host process.
func TestRemoteWorkspaceRefusesRunsItCannotStartOnTheHost(t *testing.T) {
	h, k, p, _ := openRemoteRunProject(t)
	lang := h.app.language()

	k.setRuns(func(r *remoteHostRuns) {
		r.steps = []core.RunBeforeLaunchItem{
			{ConfigurationID: remoteTestRunConfiguration.ID, Name: "Prepare"},
			{Task: &core.RunTaskReference{RunTypeKey: core.RunTypeKey{PluginID: "dev.example.build", BuildSystemID: "example", Type: "compile"}}, Name: "Compile"},
		}
	})
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	refused := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
	if !h.notified(i18n.Shared(lang, "desktop.run.remote.beforeLaunch")) {
		t.Fatal("the before-launch steps were not refused with their reason")
	}

	k.setRuns(func(r *remoteHostRuns) {
		r.steps = nil
		r.plan.Executable = core.RunPlanExecutable{Toolchain: "python"}
	})
	h.app.post(func(a *App) { p.closeRunSession(refused.id) })
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	run := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, refused)
	if !strings.Contains(run.output.all(), i18n.Shared(lang, "desktop.run.remote.toolchain")) && !strings.Contains(run.summary, i18n.Shared(lang, "desktop.run.remote.toolchain")) {
		t.Fatalf("a toolchain program was not refused with its reason: %q\n%s", run.summary, run.output.all())
	}

	done := make(chan error, 1)
	h.app.post(func(a *App) {
		_, err := a.startRunConfigurationWith(p, remoteTestRunConfiguration.ID, &connectionDebug{})
		done <- err
	})
	h.settle()
	if err := <-done; err == nil || !h.notified(i18n.Shared(lang, "desktop.run.remote.unsupported")) {
		t.Fatalf("a debug session was not refused: %v", err)
	}
	if opens, _, _, _, _ := k.hostRuns(); len(opens) != 0 {
		t.Fatalf("the host started %d processes", len(opens))
	}
}

// A remote workspace runs the before-launch steps that start another built-in run on its host,
// in order and over the workspace's session, with their output and headers in the console of the
// configuration that starts, which starts once every step exited with 0. Each step's temporary
// folder is removed before the next starts. A step that exits with a code ends the start with
// it, and stopping the start while a step runs asks the step's host process to end first.
func TestRemoteWorkspaceRunsBeforeLaunchStepsOnTheHost(t *testing.T) {
	previous := buildprocess.StopGrace()
	t.Cleanup(func() { buildprocess.SetStopGrace(previous) })
	// The window sets the stop time from the setting when it opens; the harness never opens one.
	buildprocess.SetStopGrace(8 * time.Second)
	h, k, p, logger := openRemoteRunProject(t)
	lang := h.app.language()
	k.setRuns(func(r *remoteHostRuns) {
		r.steps = []core.RunBeforeLaunchItem{{ConfigurationID: remoteTestRunConfiguration.ID, Name: "Prepare"}}
	})
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	run := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
	header := i18n.SharedFormat(lang, "desktop.runConfig.beforeLaunch.stepHeader", map[string]string{"index": "1", "count": "1", "name": "Prepare"})
	console := run.output.all()
	if run.outcome != runSucceeded || !strings.Contains(console, header) || strings.Count(console, "hello from the host") != 2 {
		t.Fatalf("the run ended %v: %s; console:\n%s", run.outcome, run.summary, console)
	}
	opens, sessions, bases, removed, _ := k.hostRuns()
	if len(opens) != 2 || opens[0].Label == nil || opens[0].Label.Name != "Prepare" || opens[1].Label == nil || opens[1].Label.Name != remoteTestRunConfiguration.Name {
		t.Fatalf("the host started %d processes, want the step's and then the configuration's", len(opens))
	}
	for _, session := range sessions {
		if session != p.remote.session {
			t.Fatal("a process started over another session")
		}
	}
	if len(bases) != 2 || len(removed) != 2 || opens[0].Cwd != remoteTestFolder+"/src" {
		t.Fatalf("%d plans, %d temporary folders removed, step cwd matched %v", len(bases), len(removed), opens[0].Cwd == remoteTestFolder+"/src")
	}

	three := 3
	k.setRuns(func(r *remoteHostRuns) { r.exit = core.RemoteProcessExit{ExitCode: &three} })
	h.app.post(func(a *App) { p.closeRunSession(run.id) })
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	failed := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, run)
	exited := i18n.SharedFormat(lang, "desktop.runConfig.beforeLaunch.exited", map[string]string{"name": "Prepare", "code": "3"})
	if failed.outcome == runSucceeded || !strings.Contains(failed.output.all(), exited) {
		t.Fatalf("a step that exited with 3 ended the start %v; console:\n%s", failed.outcome, failed.output.all())
	}
	if opens, _, _, _, _ := k.hostRuns(); len(opens) != 3 {
		t.Fatalf("the configuration started after its step failed: %d processes", len(opens))
	}

	ended := make(chan struct{})
	k.setRuns(func(r *remoteHostRuns) { r.hold, r.signalled, r.ended = true, make(chan struct{}), ended })
	h.app.post(func(a *App) { p.closeRunSession(failed.id) })
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	h.await("the held step to start", func() bool {
		opens, _, _, _, _ := k.hostRuns()
		return len(opens) == 4
	})
	h.app.post(func(a *App) { a.stopOperation(p, p.build.runOf(configurationRunKey(remoteTestRunConfiguration.ID))) })
	h.await("stopping the start to end the step's host process", func() bool {
		select {
		case <-ended:
			return true
		default:
			return false
		}
	})
	stopped := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, failed)
	opens, _, _, removed, kills := k.hostRuns()
	if len(kills) == 0 || kills[0] != "term" || len(opens) != 4 || len(removed) != 4 {
		t.Fatalf("the stop sent %v; %d processes started, %d temporary folders removed", kills, len(opens), len(removed))
	}
	if stopped.outcome == runSucceeded {
		t.Fatal("a stopped start ended as succeeded")
	}
	sessionKept(t, logger, p, p.remote.session)
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// remoteRunDirectory keeps a plan's working directory inside the host folder.
func TestRemoteRunDirectoryStaysInTheHostFolder(t *testing.T) {
	for directory, want := range map[string]string{"": "/srv/app", ".": "/srv/app", "src": "/srv/app/src", "src/../lib": "/srv/app/lib"} {
		if got, err := remoteRunDirectory("/srv/app", directory); err != nil || got != want {
			t.Errorf("%q: %q, %v; want %q", directory, got, err, want)
		}
	}
	for _, directory := range []string{"..", "../other", "/etc", "src/../../other"} {
		if _, err := remoteRunDirectory("/srv/app", directory); err == nil {
			t.Errorf("%q left the host folder", directory)
		}
	}
}

// remoteRunOutput delivers output in order off the request's goroutine and, past its limit,
// keeps the newest output and says some was left out.
func TestRemoteRunOutputDropsTheOldestPastItsLimit(t *testing.T) {
	release := make(chan struct{})
	var mu sync.Mutex
	var delivered strings.Builder
	output := newRemoteRunOutput(func(text string) {
		<-release
		mu.Lock()
		delivered.WriteString(text)
		mu.Unlock()
	}, "[dropped]")
	output.add([]byte("first "))
	output.add([]byte(strings.Repeat("x", remoteRunOutputLimit)))
	output.add([]byte("last"))
	close(release)
	output.close()
	mu.Lock()
	defer mu.Unlock()
	got := delivered.String()
	if !strings.Contains(got, "[dropped]") || !strings.HasSuffix(got, "last") || len(got) > 2*remoteRunOutputLimit+64 {
		t.Fatalf("delivered %d bytes, notice %v, newest kept %v", len(got), strings.Contains(got, "[dropped]"), strings.HasSuffix(got, "last"))
	}
}

// An output link in a remote workspace names host paths: the first that is a file on the host
// opens through the workspace's placeholder, below the folder or, outside it, below the host's
// sibling (the Zed way). A relative path, a folder and a missing file open nothing.
func TestRemoteOutputLinksFindHostFiles(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	k.put(remoteTestFolder+"/src/main.go", "package main\n")
	k.put("/usr/include/stdio.h", "")
	k.set(func(k *remoteHostKernel) {
		if k.kinds == nil {
			k.kinds = map[string]core.RemoteFileKind{}
		}
		k.kinds[remoteTestFolder+"/src"] = core.RemoteFileKindDirectory
	})
	find := p.remoteFileFinder(h.app.kernel)
	ctx := context.Background()
	candidates := []string{"src/main.go", remoteTestFolder + "/src", remoteTestFolder + "/gone.go", remoteTestFolder + "/src/main.go"}
	if got := find(ctx, candidates); got != filepath.Join(p.root, "src", "main.go") {
		t.Fatalf("a file in the folder opened %v", got != "")
	}
	if got := find(ctx, []string{"/usr/include/stdio.h"}); got != filepath.Join(p.root+remoteplaceholder.HostSuffix, "usr", "include", "stdio.h") {
		t.Fatalf("a host file outside the folder opened %v", got != "")
	}
	if got := find(ctx, []string{remoteTestFolder + "/gone.go", remoteTestFolder + "/src"}); got != "" {
		t.Fatal("a missing host file or a folder opened")
	}
}
