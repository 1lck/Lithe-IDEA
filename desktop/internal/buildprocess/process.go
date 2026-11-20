// Package buildprocess starts the host-owned process a provider prepared, or a
// command build plan Core expanded. It owns the pipes, cancellation and exit
// wait; the caller owns what the output means.
package buildprocess

import (
	"context"
	"errors"
	"fmt"
	"github.com/1lck/Lithe-IDEA/desktop/internal/loginenv"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

// Stream says whether one output chunk came from stdout or stderr.
type Stream string

const (
	Stdout Stream = "stdout"
	Stderr Stream = "stderr"
)

// pipeDrainTimeout bounds how long a root that already exited may wait for a
// descendant to close its inherited output pipes. The process tree is told to
// end first; closing the read side after this bound keeps Wait finite even when
// a descendant ignores termination.
const pipeDrainTimeout = 2 * time.Second

// stopGrace is how long, in nanoseconds, Stop lets a process tree end on its own before it
// kills the tree. Zero kills at once.
var stopGrace atomic.Int64

// SetStopGrace sets how long a stopped process tree may take to end before it is killed. The
// owner passes Core's effective stop time (processLifecycle.resolve's
// gracefulStopMilliseconds), so this package holds no default or range of its own. A tree
// already stopping keeps the time it was given. Until it is set, Stop kills at once.
func SetStopGrace(grace time.Duration) { stopGrace.Store(int64(max(grace, 0))) }

// StopGrace is the time SetStopGrace last set.
func StopGrace() time.Duration { return time.Duration(stopGrace.Load()) }

// Spec is one process the host will start. All paths are already validated by
// Core or by the package resolver that owned the executable.
type Spec struct {
	// Kind, when set, records the started process in the active process ledger under this kind until
	// it ends, so an earlier run's leftover can be offered for ending at start-up. Empty records nothing.
	Kind             string
	Executable       string
	Arguments        []string
	WorkingDirectory string
	Environment      map[string]string
	// Stdin, when set, becomes the process's standard input. The caller owns
	// the reader's other end, so a protocol session (for example a debug
	// adapter) can write frames after the process starts while cancellation
	// still ends the whole tree.
	Stdin io.Reader
	// CommandLine, when set, is the exact Windows command line the process gets,
	// Executable included, instead of one quoted from Arguments. Core plans it for
	// a batch script run by cmd.exe, whose quoting rules differ from a program's.
	// Start refuses it on other platforms, which have no command line.
	CommandLine string
}

// Process is one running host-owned process. Wait must be called once to
// release it, even after Stop.
type Process struct {
	command  *exec.Cmd
	platform *processPlatform
	stdout   *os.File
	stderr   *os.File
	readers  sync.WaitGroup
	done     chan struct{}
	err      error
	// stopping is set by the first Stop, StopAfterRequest or Kill, so repeated
	// automatic stops neither signal again nor restart the wait.
	stopping atomic.Bool
}

// Start runs spec and reports every output chunk to observe. A chunk is the bytes
// the process wrote, in whatever encoding it chose, and may end inside a
// character; Core decides the characters (core.Client.DecodeOutputStyle). observe
// runs on a reader goroutine and must return promptly. The process is killed when
// ctx ends; Stop does the same explicitly.
//
// The host owns explicit pipes rather than exec.Cmd.StdoutPipe so root exit and
// pipe EOF are independent. Wait first reaps the root, then ends descendants
// that inherited the write side, then drains the pipes with a bound. This is
// what keeps a background compiler or script from holding Wait forever after
// its parent exited.
func Start(ctx context.Context, spec Spec, observe func(Stream, string)) (*Process, error) {
	if spec.Executable == "" {
		return nil, errors.New("buildprocess: no executable")
	}
	stdoutRead, stdoutWrite, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	stderrRead, stderrWrite, err := os.Pipe()
	if err != nil {
		_ = stdoutRead.Close()
		_ = stdoutWrite.Close()
		return nil, err
	}
	command := exec.Command(spec.Executable, spec.Arguments...)
	command.Dir = spec.WorkingDirectory
	command.Env = mergedEnvironment(spec.Environment, spec.WorkingDirectory)
	command.Stdin = spec.Stdin
	command.Stdout = stdoutWrite
	command.Stderr = stderrWrite
	platform := &processPlatform{}
	err = platform.configure(command, spec.CommandLine)
	if err == nil {
		err = command.Start()
	}
	if err != nil {
		for _, file := range []*os.File{stdoutRead, stdoutWrite, stderrRead, stderrWrite} {
			_ = file.Close()
		}
		return nil, fmt.Errorf("buildprocess: start %s: %w", spec.Executable, err)
	}
	// The child owns the write ends now. Keeping the parent copies open would
	// prevent EOF even when the root and its descendants have exited.
	_ = stdoutWrite.Close()
	_ = stderrWrite.Close()
	process := &Process{
		command:  command,
		platform: platform,
		stdout:   stdoutRead,
		stderr:   stderrRead,
		done:     make(chan struct{}),
	}
	if err := platform.adopt(command.Process); err != nil {
		_ = command.Process.Kill()
		_ = command.Wait()
		_ = stdoutRead.Close()
		_ = stderrRead.Close()
		return nil, fmt.Errorf("buildprocess: take ownership of %s: %w", spec.Executable, err)
	}
	process.readers.Add(2)
	go func() {
		defer process.readers.Done()
		stream(stdoutRead, Stdout, observe)
	}()
	go func() {
		defer process.readers.Done()
		stream(stderrRead, Stderr, observe)
	}()
	untrack := func() {}
	if spec.Kind != "" {
		untrack = processledger.Track(spec.Kind, command.Process.Pid)
	}
	go func() {
		process.err = command.Wait()
		untrack()
		process.drain()
		close(process.done)
	}()
	go func() {
		select {
		case <-ctx.Done():
			process.Stop()
		case <-process.done:
		}
	}()
	return process, nil
}

// Pid is the identifier of the root process, or 0 when it has none.
func (p *Process) Pid() int {
	if p == nil || p.command == nil || p.command.Process == nil {
		return 0
	}
	return p.command.Process.Pid
}

// Wait blocks until the root exited, its inherited output pipes were drained or
// bounded, and the process tree was released.
func (p *Process) Wait() error {
	if p == nil {
		return nil
	}
	<-p.done
	return p.err
}

// Stop ends the process tree. The first call asks the tree to end and kills it when it
// is still running after StopGrace, so a program can save its work and exit. Where the
// platform has no request the whole tree answers (Windows), or no grace was set, the
// tree is killed at once. Repeated calls do nothing more; Kill ends a tree that is still
// in its grace. No call, including one after the root exited, signals a reused process
// identity.
func (p *Process) Stop() {
	if p == nil || p.command == nil || p.command.Process == nil || !p.stopping.CompareAndSwap(false, true) {
		return
	}
	grace := StopGrace()
	if grace <= 0 || !p.platform.interrupt() {
		p.platform.terminate(p.command.Process)
		return
	}
	p.killAfter(grace)
}

// StopAfterRequest lets a process handle an exit request already delivered over
// its own protocol. It sends no platform signal: even a successful local write
// does not mean the process has consumed the request. The tree is killed after
// Core's effective StopGrace if it has not exited. Repeated stops preserve this
// grace; Kill still ends it immediately.
func (p *Process) StopAfterRequest() {
	if p == nil || p.command == nil || p.command.Process == nil || !p.stopping.CompareAndSwap(false, true) {
		return
	}
	grace := StopGrace()
	if grace <= 0 {
		p.platform.terminate(p.command.Process)
		return
	}
	p.killAfter(grace)
}

func (p *Process) killAfter(grace time.Duration) {
	go func() {
		timer := time.NewTimer(grace)
		defer timer.Stop()
		select {
		case <-timer.C:
			p.platform.terminate(p.command.Process)
		case <-p.done:
		}
	}()
}

// Kill ends the process tree at once, also while an earlier Stop is waiting for it to end.
// It is what stopping a program a second time does.
func (p *Process) Kill() {
	if p == nil || p.command == nil || p.command.Process == nil {
		return
	}
	p.stopping.Store(true)
	p.platform.terminate(p.command.Process)
}

func (p *Process) drain() {
	// The root has exited. Any descendant that still holds the write side is
	// part of the build tree and must not keep Wait blocked.
	p.platform.terminate(p.command.Process)
	drained := make(chan struct{})
	go func() {
		p.readers.Wait()
		close(drained)
	}()
	select {
	case <-drained:
	case <-time.After(pipeDrainTimeout):
		// A descendant that broke away from the group or job can still hold the
		// pipe. Close our read side so Wait remains bounded; output is already
		// no longer trustworthy at that point.
		_ = p.stdout.Close()
		_ = p.stderr.Close()
		<-drained
	}
	p.platform.release()
	_ = p.stdout.Close()
	_ = p.stderr.Close()
}

func stream(reader io.Reader, kind Stream, observe func(Stream, string)) {
	if observe == nil {
		_, _ = io.Copy(io.Discard, reader)
		return
	}
	buffer := make([]byte, 32*1024)
	for {
		read, err := reader.Read(buffer)
		if read > 0 {
			observe(kind, string(buffer[:read]))
		}
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, os.ErrClosed) {
				observe(kind, err.Error()+"\n")
			}
			return
		}
	}
}

// mergedEnvironment is the started process's environment: the login shell's
// variables, then PWD for directory, then the spec's own variables, which win.
func mergedEnvironment(extra map[string]string, directory string) []string {
	// The login shell's variables fill what the process lacks (loginenv).
	base := loginenv.Environ()
	pwd := workingDirectoryVariable(directory)
	if len(extra) == 0 && pwd == "" {
		return base
	}
	merged := make(map[string]string, len(extra)+len(base)+1)
	for _, entry := range base {
		key, value, ok := splitEnvironment(entry)
		if ok {
			merged[key] = value
		}
	}
	if pwd != "" {
		merged["PWD"] = pwd
	}
	for key, value := range extra {
		merged[key] = value
	}
	environment := make([]string, 0, len(merged))
	for key, value := range merged {
		environment = append(environment, key+"="+value)
	}
	return environment
}

// workingDirectoryVariable is the PWD a process started in directory needs, or
// "" when it needs none. On POSIX systems a process finds its directory through
// PWD when PWD names it, and through the kernel's spelling otherwise. Without
// this the process would see the host's PWD, which names another directory, and
// a tool in it would spell a directory reached through a symbolic link (macOS's
// /var is /private/var) differently from the paths the host passed it: Go, for
// one, then finds the package /var/x outside the module it found in
// /private/var/x. os/exec sets PWD the same way, but only when the command has
// no environment of its own. Windows has no PWD.
func workingDirectoryVariable(directory string) string {
	if directory == "" || runtime.GOOS == "windows" {
		return ""
	}
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return ""
	}
	return absolute
}

func splitEnvironment(entry string) (string, string, bool) {
	for index := 0; index < len(entry); index++ {
		if entry[index] == '=' {
			return entry[:index], entry[index+1:], true
		}
	}
	return "", "", false
}
