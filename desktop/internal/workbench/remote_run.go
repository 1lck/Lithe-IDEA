package workbench

import (
	"context"
	"errors"
	"maps"
	"path"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file runs the built-in process runs of a remote workspace on its host (#2231 R1). Core
// plans the run for the host through the workspace's binding, so the plan names host paths; the
// window writes a script saved as text to a fresh host temporary folder only the host account
// can open, and remote.runProcess starts the program there in the user's login environment, with
// its output in the Run window. Nothing of the run is read from or written to this computer's
// file system, and no plugin takes part.
//
// A connection lost while the program runs does not end the run when the host keeps the session
// (design §9.3): the Run window says so and waits for the workspace to connect again. A session
// that resumed the same host session receives the process again (remote.attachProcess), from the
// first event the lost connection did not receive, and the window says when some output is
// missing; any other session ends the run. A kept program a closed window left running is
// received the same way, in a Run tab of its own (remote_close.go, design §9.2, S35).
//
// Note: 远程工作区运行配置的决策见 .agents/notes/implemented/architecture/2026-11-22-remote-workspace-process-runs.md

const (
	// remoteRunScratchPrefix names the host temporary folder of a run. It is removed once the
	// process ended; one a lost connection leaves is the host's temporary directory's to clean.
	remoteRunScratchPrefix = "lithe-run-script"
	// remoteRunRequestTimeout bounds the removal of a run's temporary folder.
	remoteRunRequestTimeout = 30 * time.Second
	// remoteRunOutputLimit bounds what a host process wrote that the console has not taken yet.
	// The request's goroutine must never wait (core.RemoteProcessEvents), so beyond it the
	// oldest output is dropped and the console says so.
	remoteRunOutputLimit = 8 << 20
)

// launchRemoteProcessRun is launchProcessRun for a remote workspace: it plans the run on the
// host, starts its process there and waits for it off the window thread. The plan is bounded by
// the run preparation time; the process runs until it exits, the user stops it or the project
// closes, which ends it on the host too. A lost connection ends the run only when the host keeps
// no session for it, or the session that replaces it is another (follow).
func (a *App) launchRemoteProcessRun(p *project, op *buildOperation, id string) {
	host := a.remoteRunHostOf(p, op)
	host.label = core.NewRemoteResourceLabel("run", op.session.label)
	a.background(p, 0, func(ctx context.Context) func(*App) {
		host.failed = func(operation string, err error) { a.backgroundFailedIn(ctx, operation, remoteLogError(err)) }
		bounded, cancel := context.WithTimeout(ctx, runPreparationTimeout)
		prepare, release := op.bind(bounded)
		start, err := host.prepare(prepare, id)
		release()
		cancel()
		defer host.cleanup(ctx, start)
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		err = host.run(ctx, start, func(process *remoteProcess) {
			a.post(func(a *App) { a.attachProcess(p, op, process) })
		})
		return func(a *App) { a.finishBuildRun(p, op, err) }
	})
}

// launchRemoteAttachRun receives host process id, which a closed window kept running in the host
// session key, in op's console until it exits, off the window thread. The process is op's at
// once: stopping op ends it on the host. It follows the process across lost connections as a run
// does.
func (a *App) launchRemoteAttachRun(p *project, op *buildOperation, key string, id uint64) {
	host := a.remoteRunHostOf(p, op)
	a.streamBuildOutput(p, op, remoteRunLine(i18n.Shared(host.language, "desktop.run.remote.attachedKept")))
	a.background(p, 0, func(ctx context.Context) func(*App) {
		host.failed = func(operation string, err error) { a.backgroundFailedIn(ctx, operation, remoteLogError(err)) }
		err := host.receive(ctx, key, id, func(process *remoteProcess) {
			a.post(func(a *App) { a.attachProcess(p, op, process) })
		})
		return func(a *App) { a.finishBuildRun(p, op, err) }
	})
}

// remoteRunHostOf is what a run of p with its output in op's console takes from the window
// thread.
func (a *App) remoteRunHostOf(p *project, op *buildOperation) remoteRunHost {
	r := p.remote
	return remoteRunHost{
		kernel: a.kernel, binding: r.binding, root: p.root, language: a.language(),
		current: r.current,
		output:  func(text string) { a.streamBuildOutput(p, op, text) },
		lost:    a.remoteSessionLost(p),
		rejoin:  a.remoteRunRejoin(p),
		abandon: a.remoteRunAbandon(p),
	}
}

// runStep runs a before-launch step that starts built-in run configuration step.ConfigurationID
// on the host and waits for it, with its output in the console of the configuration that starts.
// prepare bounds the step like a local one: once it ends, through a stop or the preparation
// time, the step's processes are asked to end and killed after the stop time, as a local step's
// process tree is. The step's temporary folder is removed after ctx ended too.
func (h remoteRunHost) runStep(ctx, prepare context.Context, step core.RunBeforeLaunchItem) error {
	h.label = core.NewRemoteResourceLabel("run", step.Name)
	start, err := h.prepare(prepare, step.ConfigurationID)
	defer h.cleanup(ctx, start)
	if err != nil {
		return err
	}
	request, cancel := context.WithCancel(context.WithoutCancel(prepare))
	defer cancel()
	var attached atomic.Pointer[remoteProcess]
	defer context.AfterFunc(prepare, func() {
		if process := attached.Load(); process != nil {
			process.Stop()
			return
		}
		cancel()
	})()
	if err := h.run(request, start, func(process *remoteProcess) { attached.Store(process) }); err != nil {
		return err
	}
	// A step that exited cleanly once asked to end was still stopped or ran out of time.
	return prepare.Err()
}

// remoteRunHost is what one run of a remote workspace takes from the window thread.
type remoteRunHost struct {
	kernel   Kernel
	binding  *core.RemoteWorkspace
	root     string
	language i18n.Language
	label    *core.RemoteResourceLabel
	// current is the workspace's session now (remoteProject.current).
	current func() remoteSessionRef
	// output adds text to the run's console. Decoding it may wait for Core, so only the run's
	// output pump calls it, never the request's goroutine.
	output func(string)
	// lost tells the window the session's connection closed.
	lost func(session string)
	// rejoin waits under ctx for the workspace's session that replaces lost; false when ctx ended
	// or the workspace closed first (App.remoteRunRejoin).
	rejoin func(ctx context.Context, lost string) (remoteSessionRef, bool)
	// abandon hands the window host process id of host session key, whose run ended while the
	// connection was lost, to end once a session resumes key (App.remoteRunAbandon).
	abandon func(key string, id uint64)
	// failed logs a failure of the run's housekeeping, such as removing its temporary folder.
	failed func(operation string, err error)
}

// remoteRunStart is a planned run: the session it runs over and the host session that is
// (remoteSessionRef), its host temporary folder ("" when none was created) and how its process
// starts.
type remoteRunStart struct {
	session remoteSessionRef
	scratch string
	open    core.RemoteProcessOpen
}

// prepare plans run configuration id on the host under ctx and writes a script saved as text to
// the run's temporary folder. The start it returns names the folder whenever one was created, so
// the caller removes it even when preparing failed.
func (h remoteRunHost) prepare(ctx context.Context, id string) (remoteRunStart, error) {
	start := remoteRunStart{session: h.current()}
	if start.session.id == "" {
		return start, errors.New(i18n.Shared(h.language, "desktop.run.remote.notConnected"))
	}
	scratch, err := h.kernel.RemoteTempDirectory(ctx, start.session.id, remoteRunScratchPrefix)
	if err != nil {
		return start, h.failure(start.session.id, err)
	}
	start.scratch = scratch
	plan, err := h.kernel.CreateRunLaunchPlan(ctx, h.root, id, path.Join(scratch, "script"))
	if err != nil {
		return start, h.failure(start.session.id, err)
	}
	if start.open, err = h.processOpen(plan); err != nil {
		return start, err
	}
	if plan.InlineScript != nil {
		if err := h.writeScript(ctx, start, *plan.InlineScript); err != nil {
			return start, err
		}
	}
	return start, ctx.Err()
}

// processOpen turns a launch plan Core made for the host into the host process to start: the
// program and its arguments as planned, the working directory under the workspace's host folder,
// and the plan's variables over the user's login environment. A bare command is looked up on the
// host's PATH. A toolchain executable is resolved from this computer's toolchains, which do not
// run on the host, so such a run is refused.
func (h remoteRunHost) processOpen(plan core.RunLaunchPlan) (core.RemoteProcessOpen, error) {
	directory, err := remoteRunDirectory(h.binding.RemoteRoot(), plan.WorkingDirectory)
	if err != nil {
		return core.RemoteProcessOpen{}, err
	}
	var program string
	switch executable := plan.Executable; {
	case executable.Path != "":
		if !path.IsAbs(executable.Path) {
			return core.RemoteProcessOpen{}, errors.New("run program path is not an absolute host path")
		}
		program = executable.Path
	case executable.Command != "":
		program = executable.Command
	case executable.Toolchain != "":
		return core.RemoteProcessOpen{}, errors.New(i18n.Shared(h.language, "desktop.run.remote.toolchain"))
	default:
		return core.RemoteProcessOpen{}, errors.New("run launch plan has no executable")
	}
	environment := make(map[string]string, len(plan.Environment)+len(plan.Env))
	maps.Copy(environment, plan.Environment)
	maps.Copy(environment, plan.Env)
	return core.RemoteProcessOpen{
		Argv:        append([]string{program}, plan.Arguments...),
		Cwd:         directory,
		Environment: core.RemoteProcessEnvironmentLogin,
		Env:         environment,
		Label:       h.label,
	}, nil
}

// remoteRunDirectory is the host path of a project-relative '/' working directory below the
// workspace's host folder remoteRoot. Core keeps it inside the project; one that leaves it is
// refused here too.
func remoteRunDirectory(remoteRoot, directory string) (string, error) {
	clean := path.Clean(directory)
	if path.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", errors.New("run working directory is outside the project")
	}
	return path.Join(remoteRoot, clean), nil
}

// writeScript writes a script saved as text where Core planned it, which must be a new file
// directly in the run's temporary folder. Passing start.scratch as the write boundary refuses
// descendant symlinks inside the temporary folder. The host runs it through its interpreter, so
// it needs no execute permission.
func (h remoteRunHost) writeScript(ctx context.Context, start remoteRunStart, script core.RunInlineScript) error {
	if path.Dir(script.Path) != start.scratch {
		return errors.New("inline script is outside its temporary folder")
	}
	_, saved, err := h.kernel.RemoteWriteFile(ctx, start.session.id, script.Path, []byte(script.Content), nil, start.scratch)
	if err != nil {
		return h.failure(start.session.id, err)
	}
	if !saved {
		return errors.New("inline script file already exists")
	}
	return nil
}

// run starts the planned process under ctx and waits for its leader to exit; attach receives the
// process once the host started it. A lost connection waits for the workspace to connect again
// (follow). The output reaches the console before run returns. It returns nil for a clean exit,
// a remoteRunExit for a nonzero exit code, and why the run ended otherwise.
func (h remoteRunHost) run(ctx context.Context, start remoteRunStart, attach func(*remoteProcess)) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	process := h.newProcess(start.session.id, cancel)
	defer close(process.done)
	return h.follow(ctx, start.session.key, process, func(session string, events core.RemoteProcessEvents) (core.RemoteProcessExit, error) {
		events.Started = func(processID uint64, _ int) {
			if process.id.CompareAndSwap(0, processID) {
				attach(process)
			}
		}
		return h.kernel.RemoteRunProcess(ctx, session, start.open, events)
	})
}

// receive receives host process id, which an earlier connection to host session key started,
// over the workspace's session under ctx until its leader exits; attach receives the process at
// once. It ends as run does.
func (h remoteRunHost) receive(ctx context.Context, key string, id uint64, attach func(*remoteProcess)) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	session := h.current()
	switch {
	case session.id == "":
		return errors.New(i18n.Shared(h.language, "desktop.run.remote.notConnected"))
	case session.key != key:
		return errors.New(i18n.Shared(h.language, "desktop.run.remote.sessionEnded"))
	}
	process := h.newProcess(session.id, cancel)
	defer close(process.done)
	process.id.Store(id)
	attach(process)
	return h.follow(ctx, key, process, h.attachRequest(ctx, id))
}

// remoteReceive sends the request that receives a run's process over session, with events.
type remoteReceive func(session string, events core.RemoteProcessEvents) (core.RemoteProcessExit, error)

// attachRequest is the remoteReceive of remote.attachProcess for host process id under ctx.
func (h remoteRunHost) attachRequest(ctx context.Context, id uint64) remoteReceive {
	return func(session string, events core.RemoteProcessEvents) (core.RemoteProcessExit, error) {
		return h.kernel.RemoteAttachProcess(ctx, session, id, events)
	}
}

// newProcess is a run's process over session, whose request cancel ends.
func (h remoteRunHost) newProcess(session string, cancel context.CancelFunc) *remoteProcess {
	process := &remoteProcess{kernel: h.kernel, cancel: cancel, done: make(chan struct{}), failed: h.failed}
	process.session.Store(&session)
	return process
}

// follow receives process over first, then, while the host keeps host session key, again over
// each session that resumes key after a lost connection, until its leader exits; it returns why
// the run ended as run does. A request the lost connection ended waits for the workspace's next
// session, with the wait in the console, once the host started the process: a process the
// connection lost before Core named it cannot be received again. A run that ends meanwhile
// leaves its process to the window, which ends it once a session resumes key. key "" is a
// connection whose host keeps no session, which a lost connection ends.
func (h remoteRunHost) follow(ctx context.Context, key string, process *remoteProcess, first remoteReceive) error {
	receive, resumed := first, false
	for {
		session := process.over()
		output := newRemoteRunOutput(h.output, remoteRunNotice(i18n.Shared(h.language, "desktop.run.remote.outputDropped")))
		exit, err := receive(session, core.RemoteProcessEvents{
			// Core calls it before the request's first output.
			Attached: func(truncated bool) {
				if resumed {
					output.lead(remoteRunLine(i18n.Shared(h.language, "desktop.run.remote.resumed")))
				}
				if truncated {
					output.lead(remoteRunLine(i18n.Shared(h.language, "desktop.run.remote.outputLost")))
				}
			},
			Output: func(_ string, data []byte) { output.add(data) },
		})
		output.close()
		id := process.id.Load()
		if err == nil || !remoteConnectionClosed(err) || id == 0 || key == "" {
			return h.endError(ctx, session, exit, err)
		}
		if ctx.Err() != nil {
			// The run was stopped as the connection broke: the host never heard of it.
			h.abandon(key, id)
			return ctx.Err()
		}
		h.lost(session)
		h.output(remoteRunNotice(i18n.Shared(h.language, "desktop.run.remote.waiting")))
		next, ok := h.rejoin(ctx, session)
		switch {
		case ctx.Err() != nil:
			h.abandon(key, id)
			return ctx.Err()
		case !ok:
			// The workspace closed, which decided what happens to the host's programs.
			return errors.New(i18n.Shared(h.language, "desktop.run.remote.connectionLost"))
		case next.key != key:
			return errors.New(i18n.Shared(h.language, "desktop.run.remote.sessionEnded"))
		}
		process.move(next.id)
		receive, resumed = h.attachRequest(ctx, id), true
	}
}

// remoteRunNotice is the window's own console text on a line of its own, after output that may
// not end its line.
func remoteRunNotice(text string) string {
	return "\n" + remoteRunLine(text)
}

// remoteRunLine is the window's own console text as a line, at the start of one.
func remoteRunLine(text string) string {
	return "\x1b[2m" + text + "\x1b[0m\n"
}

// endError is why a run's request ended as the console reads it. A request ctx ended was
// stopped or closed with its project; a lost connection is told to the window, which connects
// again.
func (h remoteRunHost) endError(ctx context.Context, session string, exit core.RemoteProcessExit, err error) error {
	switch {
	case err != nil && ctx.Err() != nil:
		return ctx.Err()
	case err != nil:
		return h.failure(session, err)
	case exit.ExitCode != nil && *exit.ExitCode != 0:
		return remoteRunExit(*exit.ExitCode)
	case exit.Signal != nil:
		return errors.New(i18n.SharedFormat(h.language, "desktop.run.remote.signal", map[string]string{"signal": strconv.Itoa(*exit.Signal)}))
	}
	return nil
}

// failure is err of a request over session as the console shows it: a closed connection is told
// to the window and reads as a lost connection, and the refusals of remote.attachProcess say why
// the process cannot be received.
func (h remoteRunHost) failure(session string, err error) error {
	var coreErr *core.Error
	switch {
	case remoteConnectionClosed(err):
		h.lost(session)
		return errors.New(i18n.Shared(h.language, "desktop.run.remote.connectionLost"))
	case errors.As(err, &coreErr) && coreErr.Code == core.CodeRemoteProcessGone:
		return errors.New(i18n.Shared(h.language, "desktop.run.remote.processGone"))
	case errors.As(err, &coreErr) && coreErr.Code == core.CodeRemoteProcessAttached:
		return errors.New(i18n.Shared(h.language, "desktop.run.remote.attachedElsewhere"))
	}
	return err
}

// cleanup removes the run's host temporary folder, after ctx ended too, so a stopped run leaves
// none. It goes over the workspace's session now, which the run may have followed to a later
// one; a folder the workspace is disconnected from is left to the host.
func (h remoteRunHost) cleanup(ctx context.Context, start remoteRunStart) {
	session := h.current().id
	if start.scratch == "" || session == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), remoteRunRequestTimeout)
	defer cancel()
	if err := h.kernel.RemoteRemove(ctx, session, start.scratch, true); err != nil && !remoteConnectionClosed(err) {
		h.failed("run_inline_script_cleanup", err)
	}
}

// remoteRunExit is a host process's nonzero exit code, which finishBuildRun reads as an exit.
type remoteRunExit int

func (e remoteRunExit) Error() string { return "remote run: exit status " + strconv.Itoa(int(e)) }

// ExitCode is the code the process exited with.
func (e remoteRunExit) ExitCode() int { return int(e) }

// remoteProcess is a run's process on the host as the Run window stops it (runProcess).
type remoteProcess struct {
	kernel Kernel
	// session is the session the process is received over: the one it started in, then each one
	// that resumed its host session after a lost connection.
	session atomic.Pointer[string]
	// cancel ends the run's request, and with it every process of the run: Core kills them.
	cancel context.CancelFunc
	// id is the process's id for process.kill, set before the process is attached.
	id atomic.Uint64
	// done is closed once the request returned.
	done     chan struct{}
	stopping sync.Once
	failed   func(operation string, err error)
}

// Pid is 0: the host's process ids are not this computer's, whose ports the Run window samples.
func (r *remoteProcess) Pid() int { return 0 }

// over is the session the process is received over now.
func (r *remoteProcess) over() string { return *r.session.Load() }

// move makes session, which resumed the process's host session, the one it is received over.
func (r *remoteProcess) move(session string) { r.session.Store(&session) }

// Stop asks every process of the run to end, SIGTERM to its process group, and kills them once
// the stop time passed. A stop the host could not be asked for kills them at once; while the
// connection is lost, that is once a session resumes the host session (follow).
func (r *remoteProcess) Stop() {
	r.stopping.Do(func() {
		grace := buildprocess.StopGrace()
		if grace <= 0 || r.id.Load() == 0 {
			r.cancel()
			return
		}
		go func() {
			timer := time.NewTimer(grace)
			defer timer.Stop()
			ctx, cancel := context.WithTimeout(context.Background(), grace)
			err := r.kernel.RemoteProcessKill(ctx, r.over(), r.id.Load(), false)
			cancel()
			if err != nil {
				if ctx.Err() == nil && !remoteConnectionClosed(err) {
					r.failed("run_stop", err)
				}
				r.cancel()
				return
			}
			select {
			case <-r.done:
			case <-timer.C:
				r.cancel()
			}
		}()
	})
}

// Kill ends every process of the run at once.
func (r *remoteProcess) Kill() { r.cancel() }

// remoteRunOutput carries a host process's output from the request's goroutine, which must return
// at once, to the console, whose decoder may wait for Core. Its pump delivers in order.
type remoteRunOutput struct {
	deliver func(string)
	// notice marks where output was dropped.
	notice string
	wake   chan struct{}
	done   chan struct{}

	mu sync.Mutex
	// leading is the window's own text, delivered before pending.
	leading []string
	pending []byte
	dropped bool
	closed  bool
}

func newRemoteRunOutput(deliver func(string), notice string) *remoteRunOutput {
	o := &remoteRunOutput{deliver: deliver, notice: notice, wake: make(chan struct{}, 1), done: make(chan struct{})}
	go o.pump()
	return o
}

// add keeps data for the console and never waits. Output beyond remoteRunOutputLimit drops what
// the console has not taken yet, which the console then says.
func (o *remoteRunOutput) add(data []byte) {
	o.mu.Lock()
	if len(o.pending)+len(data) > remoteRunOutputLimit {
		o.pending, o.dropped = o.pending[:0], true
		data = data[max(0, len(data)-remoteRunOutputLimit):]
	}
	o.pending = append(o.pending, data...)
	o.mu.Unlock()
	o.signal()
}

// lead adds text of the window's own before the output, which nothing was added of yet, and
// never waits.
func (o *remoteRunOutput) lead(text string) {
	o.mu.Lock()
	o.leading = append(o.leading, text)
	o.mu.Unlock()
	o.signal()
}

// close delivers what is left and waits for the pump to finish.
func (o *remoteRunOutput) close() {
	o.mu.Lock()
	o.closed = true
	o.mu.Unlock()
	o.signal()
	<-o.done
}

func (o *remoteRunOutput) signal() {
	select {
	case o.wake <- struct{}{}:
	default:
	}
}

func (o *remoteRunOutput) pump() {
	defer close(o.done)
	for range o.wake {
		o.mu.Lock()
		leading, data, dropped, closed := o.leading, o.pending, o.dropped, o.closed
		o.leading, o.pending, o.dropped = nil, nil, false
		o.mu.Unlock()
		for _, text := range leading {
			o.deliver(text)
		}
		if dropped {
			o.deliver(o.notice)
		}
		if len(data) > 0 {
			o.deliver(string(data))
		}
		if closed {
			return
		}
	}
}

// remoteSessionRef is a session of a remote workspace with the host session it is attached to
// (core.RemoteSession.SessionKey), "" for a host that keeps no session for the connection. Two
// sessions of one key reach the same host processes, whose ids are per host session.
type remoteSessionRef struct {
	id, key string
}

// remoteAbandoned is a host process of host session key whose run ended while the connection was
// lost: nothing could tell the host to end it.
type remoteAbandoned struct {
	key string
	id  uint64
}

// remoteRunRejoin is how a run of p waits, off the window thread, for the session that replaces
// the lost one (remoteRunHost.rejoin).
func (a *App) remoteRunRejoin(p *project) func(context.Context, string) (remoteSessionRef, bool) {
	return func(ctx context.Context, lost string) (remoteSessionRef, bool) {
		// Buffered, so the window thread hands the session over without waiting for the run.
		wait := make(chan remoteSessionRef, 1)
		a.post(func(a *App) { a.awaitRemoteSession(p, lost, wait) })
		select {
		case next, ok := <-wait:
			return next, ok
		case <-ctx.Done():
			return remoteSessionRef{}, false
		}
	}
}

// awaitRemoteSession hands wait the workspace's session once there is one other than lost, and
// closes it when the workspace closed.
func (a *App) awaitRemoteSession(p *project, lost string, wait chan<- remoteSessionRef) {
	r := p.remote
	switch session := r.current(); {
	case a.project != p || r.closed:
		close(wait)
	case session.id != "" && session.id != lost:
		wait <- session
	default:
		r.rejoins = append(r.rejoins, wait)
	}
}

// remoteRunAbandon is how a run of p that ended while its connection was lost hands its host
// process to the window, off the window thread (remoteRunHost.abandon).
func (a *App) remoteRunAbandon(p *project) func(key string, id uint64) {
	return func(key string, id uint64) {
		a.post(func(a *App) {
			r := p.remote
			if a.project != p || r.closed {
				// log-exempt: 用户取消：工作区已关闭，关闭时已决定主机上的程序是结束还是保留。
				return
			}
			r.abandoned = append(r.abandoned, remoteAbandoned{key: key, id: id})
			if r.session != "" {
				a.endAbandonedRuns(p)
			}
		})
	}
}

// rejoinRemoteRuns hands the workspace's new session to the runs waiting for one and ends the
// host processes of the runs that ended meanwhile once it resumed their host session; with any
// other, they ended with their own.
func (a *App) rejoinRemoteRuns(p *project) {
	r := p.remote
	session := r.current()
	for _, wait := range r.rejoins {
		wait <- session
	}
	r.rejoins = nil
	a.endAbandonedRuns(p)
}

// endAbandonedRuns ends, at once and over the workspace's session, the abandoned host processes
// of its host session, and forgets the others: their host session ended.
func (a *App) endAbandonedRuns(p *project) {
	r := p.remote
	session := r.current()
	var ids []uint64
	for _, process := range r.abandoned {
		if session.key != "" && process.key == session.key {
			ids = append(ids, process.id)
		}
	}
	r.abandoned = nil
	if len(ids) == 0 {
		return
	}
	kernel := a.kernel
	a.background(p, remoteRunRequestTimeout, func(ctx context.Context) func(*App) {
		var failed error
		for _, id := range ids {
			if err := kernel.RemoteProcessKill(ctx, session.id, id, true); err != nil && !remoteConnectionClosed(err) {
				failed = err
			}
		}
		if failed == nil {
			return nil
		}
		return func(a *App) { a.backgroundFailed("run_stop_after_reconnect", remoteLogError(failed)) }
	})
}

// closeRemoteRuns closes the waits of the runs of a closing workspace and forgets its abandoned
// host processes: closing it decides what happens to the host's programs.
func (r *remoteProject) closeRemoteRuns() {
	for _, wait := range r.rejoins {
		close(wait)
	}
	r.rejoins, r.abandoned = nil, nil
}
