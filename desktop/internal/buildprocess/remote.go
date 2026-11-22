package buildprocess

import (
	"context"
	"errors"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// RemoteRunner streams a process on the workspace's captured connection.
type RemoteRunner interface {
	RunRemoteProcess(context.Context, core.RemoteProcessOpen, core.RemoteProcessEvents) (core.RemoteProcessExit, error)
}

// StartRemote waits for the host to start the process. The startup request may
// cancel it until then. The lifetime context owns the running process.
func StartRemote(ctx, lifetime context.Context, host RemoteRunner, spec core.RemoteProcessOpen, output func(Stream, string)) (*RemoteProcess, error) {
	return StartRemoteBytes(ctx, lifetime, host, spec, func(stream string, data []byte) {
		if output != nil {
			output(Stream(stream), string(data))
		}
	})
}

// StartRemoteBytes starts the same owned process, preserving stdout and
// stderr as bytes for framed protocols.
func StartRemoteBytes(ctx, lifetime context.Context, host RemoteRunner, spec core.RemoteProcessOpen, output func(string, []byte)) (*RemoteProcess, error) {
	lifetime, cancel := context.WithCancel(lifetime)
	stopStartup := context.AfterFunc(ctx, cancel)
	defer stopStartup()
	if err := ctx.Err(); err != nil {
		cancel()
		return nil, err
	}
	process := &RemoteProcess{cancel: cancel, done: make(chan struct{})}
	started := make(chan struct{})
	go func() {
		defer close(process.done)
		defer cancel()
		exit, err := host.RunRemoteProcess(lifetime, spec, core.RemoteProcessEvents{
			Started: func(processID uint64, _ int) {
				process.ID = processID
				stopStartup()
				close(started)
			},
			Output: output,
		})
		process.err = err
		if err == nil && (exit.Signal != nil || exit.ExitCode == nil || *exit.ExitCode != 0) {
			process.err = &RemoteExit{Status: exit}
		}
	}()
	select {
	case <-started:
		return process, nil
	case <-process.done:
		select {
		case <-started:
			return process, nil
		default:
			if process.err == nil {
				return nil, errors.New("remote process exited without a start event")
			}
			return nil, process.err
		}
	}
}

// RemoteProcess owns a Core call. Its PID is never a local process ID.
type RemoteProcess struct {
	// ID addresses this process on its captured remote session only.
	ID     uint64
	cancel context.CancelFunc
	done   chan struct{}
	err    error
}

func (p *RemoteProcess) Wait() error { <-p.done; return p.err }
func (p *RemoteProcess) Stop()       { p.cancel() }
func (p *RemoteProcess) Kill()       { p.cancel() }
func (p *RemoteProcess) Pid() int    { return 0 }

// RemoteExit is the status reported by the process's host.
type RemoteExit struct {
	Status core.RemoteProcessExit
}

func (e *RemoteExit) ExitCode() int {
	if e.Status.ExitCode == nil {
		return -1
	}
	return *e.Status.ExitCode
}

func (e *RemoteExit) Error() string {
	if e.Status.ExitCode != nil {
		return fmt.Sprintf("remote process exited with code %d", *e.Status.ExitCode)
	}
	if e.Status.Signal != nil {
		return fmt.Sprintf("remote process ended with signal %d", *e.Status.Signal)
	}
	return "remote process ended without an exit status"
}
