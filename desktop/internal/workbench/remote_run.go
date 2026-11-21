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
// the run preparation time; the process runs until it exits, the user stops it, the project
// closes or the connection is lost, which ends it on the host too.
func (a *App) launchRemoteProcessRun(p *project, op *buildOperation, id string) {
	host := remoteRunHost{
		kernel: a.kernel, binding: p.remote.binding, root: p.root, language: a.language(),
		label:  core.NewRemoteResourceLabel("run", op.session.label),
		output: func(text string) { a.streamBuildOutput(p, op, text) },
		lost:   a.remoteSessionLost(p),
	}
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

// remoteRunHost is what one run of a remote workspace takes from the window thread.
type remoteRunHost struct {
	kernel   Kernel
	binding  *core.RemoteWorkspace
	root     string
	language i18n.Language
	label    *core.RemoteResourceLabel
	// output adds text to the run's console. Decoding it may wait for Core, so only the run's
	// output pump calls it, never the request's goroutine.
	output func(string)
	// lost tells the window the session's connection closed.
	lost func(session string)
	// failed logs a failure of the run's housekeeping, such as removing its temporary folder.
	failed func(operation string, err error)
}

// remoteRunStart is a planned run: the session it runs over, its host temporary folder ("" when
// none was created) and how its process starts.
type remoteRunStart struct {
	session, scratch string
	open             core.RemoteProcessOpen
}

// prepare plans run configuration id on the host under ctx and writes a script saved as text to
// the run's temporary folder. The start it returns names the folder whenever one was created, so
// the caller removes it even when preparing failed.
func (h remoteRunHost) prepare(ctx context.Context, id string) (remoteRunStart, error) {
	start := remoteRunStart{session: h.binding.SessionID()}
	if start.session == "" {
		return start, errors.New(i18n.Shared(h.language, "desktop.run.remote.notConnected"))
	}
	scratch, err := h.kernel.RemoteTempDirectory(ctx, start.session, remoteRunScratchPrefix)
	if err != nil {
		return start, h.failure(start.session, err)
	}
	start.scratch = scratch
	plan, err := h.kernel.CreateRunLaunchPlan(ctx, h.root, id, path.Join(scratch, "script"))
	if err != nil {
		return start, h.failure(start.session, err)
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
// directly in the run's temporary folder. The host runs it through its interpreter, so it needs
// no execute permission.
func (h remoteRunHost) writeScript(ctx context.Context, start remoteRunStart, script core.RunInlineScript) error {
	if path.Dir(script.Path) != start.scratch {
		return errors.New("inline script is outside its temporary folder")
	}
	_, saved, err := h.kernel.RemoteWriteFile(ctx, start.session, script.Path, []byte(script.Content), nil)
	if err != nil {
		return h.failure(start.session, err)
	}
	if !saved {
		return errors.New("inline script file already exists")
	}
	return nil
}

// run starts the planned process under ctx and waits for its leader to exit; attach receives the
// process once the host started it. The output reaches the console before run returns. It
// returns nil for a clean exit, a remoteRunExit for a nonzero exit code, and why the run ended
// otherwise.
func (h remoteRunHost) run(ctx context.Context, start remoteRunStart, attach func(*remoteProcess)) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	process := &remoteProcess{kernel: h.kernel, session: start.session, cancel: cancel, done: make(chan struct{}), failed: h.failed}
	output := newRemoteRunOutput(h.output, "\n\x1b[2m"+i18n.Shared(h.language, "desktop.run.remote.outputDropped")+"\x1b[0m\n")
	exit, err := h.kernel.RemoteRunProcess(ctx, start.session, start.open, core.RemoteProcessEvents{
		Started: func(processID uint64, _ int) {
			if process.id.CompareAndSwap(0, processID) {
				attach(process)
			}
		},
		Output: func(_ string, data []byte) { output.add(data) },
	})
	close(process.done)
	output.close()
	return h.endError(ctx, start.session, exit, err)
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
// to the window and reads as a lost connection.
func (h remoteRunHost) failure(session string, err error) error {
	if remoteConnectionClosed(err) {
		h.lost(session)
		return errors.New(i18n.Shared(h.language, "desktop.run.remote.connectionLost"))
	}
	return err
}

// cleanup removes the run's host temporary folder, after ctx ended too, so a stopped run leaves
// none. A folder a lost connection keeps is left to the host.
func (h remoteRunHost) cleanup(ctx context.Context, start remoteRunStart) {
	if start.scratch == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), remoteRunRequestTimeout)
	defer cancel()
	if err := h.kernel.RemoteRemove(ctx, start.session, start.scratch, true); err != nil && !remoteConnectionClosed(err) {
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
	kernel  Kernel
	session string
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

// Stop asks every process of the run to end, SIGTERM to its process group, and kills them once
// the stop time passed. A stop the host could not be asked for kills them at once.
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
			err := r.kernel.RemoteProcessKill(ctx, r.session, r.id.Load(), false)
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

	mu      sync.Mutex
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
		data, dropped, closed := o.pending, o.dropped, o.closed
		o.pending, o.dropped = nil, false
		o.mu.Unlock()
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
