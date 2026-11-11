// Package buildprocess starts the host-owned process a provider prepared, or a
// command build plan Core expanded. It owns the pipes, cancellation and exit
// wait; the caller owns what the output means.
package buildprocess

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
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

// Spec is one process the host will start. All paths are already validated by
// Core or by the package resolver that owned the executable.
type Spec struct {
	Executable       string
	Arguments        []string
	WorkingDirectory string
	Environment      map[string]string
	// Stdin, when set, becomes the process's standard input. The caller owns
	// the reader's other end, so a protocol session (for example a debug
	// adapter) can write frames after the process starts while cancellation
	// still ends the whole tree.
	Stdin io.Reader
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
	// stopOnce prevents a second signal from racing the first.
	stopOnce sync.Once
}

// Start runs spec and reports every output chunk to observe. observe runs on a
// reader goroutine and must return promptly. The process is killed when ctx
// ends; Stop does the same explicitly.
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
	command.Env = mergedEnvironment(spec.Environment)
	command.Stdin = spec.Stdin
	command.Stdout = stdoutWrite
	command.Stderr = stderrWrite
	platform := &processPlatform{}
	platform.configure(command)
	if err := command.Start(); err != nil {
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
	go func() {
		process.err = command.Wait()
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

// Stop terminates the process tree. Repeated calls, including after the root
// exited, are harmless and never signal a reused process identity.
func (p *Process) Stop() {
	if p == nil {
		return
	}
	p.stopOnce.Do(func() {
		if p.command == nil || p.command.Process == nil {
			return
		}
		p.platform.terminate(p.command.Process)
	})
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

func mergedEnvironment(extra map[string]string) []string {
	if len(extra) == 0 {
		return os.Environ()
	}
	merged := make(map[string]string, len(extra)+len(os.Environ()))
	for _, entry := range os.Environ() {
		key, value, ok := splitEnvironment(entry)
		if ok {
			merged[key] = value
		}
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

func splitEnvironment(entry string) (string, string, bool) {
	for index := 0; index < len(entry); index++ {
		if entry[index] == '=' {
			return entry[:index], entry[index+1:], true
		}
	}
	return "", "", false
}
