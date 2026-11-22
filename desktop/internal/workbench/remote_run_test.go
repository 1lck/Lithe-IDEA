package workbench

import (
	"context"
	"errors"
	"path/filepath"
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
// processes (remote.runProcess): a process prints remoteHostRunOutput and exits with exit, or,
// with hold, runs until it is signalled or its request ends.
type remoteHostRuns struct {
	mu sync.Mutex
	// configurations are what Core resolves, and plan is the launch plan of each.
	configurations []core.RunConfiguration
	plan           core.RunLaunchPlan
	// steps are the before-launch steps of every configuration.
	steps        []core.RunBeforeLaunchItem
	beforeLaunch func(context.Context) error
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
}

// remoteHostRunOutput is what a host process prints.
const remoteHostRunOutput = "hello from the host\n"

func (k *remoteHostKernel) remoteRunConfigurations() core.RunConfigResolution {
	r := &k.runs
	r.mu.Lock()
	defer r.mu.Unlock()
	return core.RunConfigResolution{Configurations: append([]core.RunConfiguration(nil), r.configurations...)}
}

func (k *remoteHostKernel) RunBeforeLaunch(ctx context.Context, _ string, _ string, _ *core.RunTypePlugins) (core.RunBeforeLaunch, error) {
	r := &k.runs
	r.mu.Lock()
	steps, beforeLaunch := r.steps, r.beforeLaunch
	r.mu.Unlock()
	if beforeLaunch != nil {
		if err := beforeLaunch(ctx); err != nil {
			return core.RunBeforeLaunch{}, err
		}
	}
	return core.RunBeforeLaunch{Status: "ok", Steps: steps}, nil
}

func (k *remoteHostKernel) ResolveRemoteExecutable(ctx context.Context, request core.RemoteExecutableRequest) (string, error) {
	if request.Kind == "program" && request.Value == "sh" {
		if workspace := core.RemoteWorkspaceOf(ctx); workspace != nil && workspace.CapturedConnection(ctx).IsCurrent() {
			return "/usr/bin/sh", nil
		}
	}
	return "", nil
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

func (k *remoteHostKernel) RemoteRemove(_ context.Context, _, path string, recursive bool) error {
	k.mu.Lock()
	for name := range k.files {
		if strings.HasPrefix(name, path+"/") {
			delete(k.files, name)
		}
	}
	k.mu.Unlock()
	r := &k.runs
	r.mu.Lock()
	defer r.mu.Unlock()
	if recursive {
		r.removed = append(r.removed, path)
	}
	return nil
}

func (k *remoteHostKernel) RunRemoteProcess(ctx context.Context, open core.RemoteProcessOpen, events core.RemoteProcessEvents) (core.RemoteProcessExit, error) {
	workspace := core.RemoteWorkspaceOf(ctx)
	if workspace == nil {
		return core.RemoteProcessExit{}, &core.Error{Code: core.CodeConnectionClosed, Message: "no captured workspace"}
	}
	session := workspace.CapturedConnection(ctx).SessionID()
	if session == "" {
		return core.RemoteProcessExit{}, &core.Error{Code: core.CodeConnectionClosed, Message: "no captured session"}
	}
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
	exit, hold, signalled, ended := r.exit, r.hold, r.signalled, r.ended
	r.mu.Unlock()
	if ended != nil {
		defer close(ended)
	}
	events.Started(7, 4242)
	events.Output("stdout", []byte(remoteHostRunOutput))
	if !hold {
		return exit, nil
	}
	select {
	case <-signalled:
		signal := 15
		return core.RemoteProcessExit{Signal: &signal}, nil
	case <-ctx.Done():
		return core.RemoteProcessExit{}, ctx.Err()
	}
}

func (k *remoteHostKernel) RemoteProcessKill(_ context.Context, _ string, processID uint64, force bool) error {
	r := &k.runs
	r.mu.Lock()
	defer r.mu.Unlock()
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
	h, k, _, logger := remoteWorkspaceHarness(t)
	k.set(func(k *remoteHostKernel) { k.git.trust[remoteTestFolder] = core.WorkspaceTrusted })
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
	return h, k, p, logger
}

// startRemoteRun starts a configuration in a trusted workspace and checks admission
// before the caller waits for its output.
func (h *harness) startRemoteRun(p *project, id string) {
	h.t.Helper()
	started := make(chan error, 1)
	h.app.post(func(a *App) {
		_, err := a.startRunConfiguration(p, id)
		if err == nil {
			a.showBuildConsole(p)
		}
		started <- err
	})
	h.await("the remote run to start", func() bool {
		select {
		case err := <-started:
			if err != nil {
				h.t.Fatalf("start remote run %q: %v", id, err)
			}
			return true
		default:
			return false
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
	if want := (core.RemoteScopedDirectory{Root: remoteTestFolder, Path: "src"}); strings.Join(open.Argv, " ") != "/usr/bin/sh "+script || open.ScopedCwd == nil || *open.ScopedCwd != want || open.Environment != core.RemoteProcessEnvironmentLogin {
		t.Fatalf("the process started with argv=%v, scoped directory=%+v, environment=%q", open.Argv, open.ScopedCwd, open.Environment)
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

func TestRemoteWorkspaceRefusesRunsItCannotStartOnTheHost(t *testing.T) {
	h, k, p, _ := openRemoteRunProject(t)
	lang := h.app.language()

	k.setRuns(func(r *remoteHostRuns) {
		r.steps = []core.RunBeforeLaunchItem{{
			Task: &core.RunTaskReference{RunTypeKey: core.RunTypeKey{PluginID: "dev.lithe.test.build", BuildSystemID: "example", Type: "compile"}},
			Name: "Compile",
		}}
	})
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	refused := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
	if refused.outcome == runSucceeded || !strings.Contains(refused.output.all(), h.app.text.Build.TargetMissing) {
		t.Fatalf("the missing build target was not reported: %s", refused.output.all())
	}

	k.setRuns(func(r *remoteHostRuns) {
		r.steps = nil
		r.plan.Executable = core.RunPlanExecutable{Command: "missing-program"}
	})
	h.app.post(func(a *App) { p.closeRunSession(refused.id) })
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	run := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, refused)
	message := i18n.SharedFormat(lang, "desktop.runConfig.programNotFound", map[string]string{"program": "missing-program"})
	if run.outcome == runSucceeded || !strings.Contains(run.output.all()+run.summary, message) {
		t.Fatalf("the missing host program was not reported: %q\n%s", run.summary, run.output.all())
	}

	done := make(chan error, 1)
	h.app.post(func(a *App) {
		_, err := a.startRunConfigurationWith(p, remoteTestRunConfiguration.ID, &connectionDebug{})
		done <- err
	})
	h.await("the built-in debug refusal", func() bool {
		select {
		case err := <-done:
			var refusal *buildRefusal
			if !errors.As(err, &refusal) || refusal.code != refusalNotSupported {
				t.Fatalf("debug start = %v, want not supported", err)
			}
			return true
		default:
			return false
		}
	})
	if opens, _, _, _, _ := k.hostRuns(); len(opens) != 0 {
		t.Fatalf("the host started %d processes", len(opens))
	}
}

func TestRemoteWorkspaceRunDoesNotSurviveReattachment(t *testing.T) {
	h, k, p, _ := openRemoteRunProject(t)
	planning := make(chan struct{})
	release := make(chan struct{})
	k.setRuns(func(r *remoteHostRuns) {
		r.beforeLaunch = func(ctx context.Context) error {
			close(planning)
			select {
			case <-release:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(unblock)
	h.startRemoteRun(p, remoteTestRunConfiguration.ID)
	h.await("the run to request its before-launch plan", func() bool {
		select {
		case <-planning:
			return true
		default:
			return false
		}
	})
	// A resumed session can keep its ID. A pending run still owns the old attachment.
	h.app.post(func(a *App) {
		p.remote.binding.Attach(p.remote.session)
		unblock()
	})
	run := h.awaitRemoteRun(p, remoteTestRunConfiguration.Name, nil)
	if opens, _, bases, _, _ := k.hostRuns(); run.outcome == runSucceeded || len(opens) != 0 || len(bases) != 0 {
		t.Fatalf("the stale run reached the reattached workspace: outcome=%v, opens=%d, plans=%d", run.outcome, len(opens), len(bases))
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
	if want := (core.RemoteScopedDirectory{Root: remoteTestFolder, Path: "src"}); len(bases) != 2 || len(removed) != 2 || opens[0].ScopedCwd == nil || *opens[0].ScopedCwd != want {
		t.Fatalf("%d plans, %d temporary folders removed, step scoped directory=%+v", len(bases), len(removed), opens[0].ScopedCwd)
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
	for directory, want := range map[string]string{"": "", ".": "", "src": "src", "src/../lib": "lib"} {
		if got, err := remoteRunDirectory("/srv/app", directory); err != nil || got == nil || got.Root != "/srv/app" || got.Path != want {
			t.Errorf("%q: %+v, %v; want root /srv/app and path %q", directory, got, err, want)
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
