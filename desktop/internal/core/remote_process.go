package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"path"
)

// RemoteExecutableRequest describes a candidate Core already planned. The host
// checks its files or login environment without launching the program.
type RemoteExecutableRequest struct {
	Kind       string   `json:"kind"`
	Value      string   `json:"value,omitempty"`
	Root       string   `json:"root,omitempty"`
	Path       string   `json:"path,omitempty"`
	Variable   string   `json:"variable,omitempty"`
	Requires   []string `json:"requires,omitempty"`
	SearchPath *string  `json:"searchPath,omitempty"`
}

// ResolveRemoteExecutable locates a candidate in the bound workspace's host.
func (c *Client) ResolveRemoteExecutable(ctx context.Context, request RemoteExecutableRequest) (string, error) {
	var executable *string
	err := c.remoteWorkspaceHostRequest(ctx, "process.resolveExecutable", request, &executable)
	if executable == nil || err != nil {
		return "", err
	}
	return *executable, nil
}

// PickRemoteLoopbackPort asks the workspace host for a port the debuggee can bind.
func (c *Client) PickRemoteLoopbackPort(ctx context.Context) (int, error) {
	var port int
	err := c.remoteWorkspaceHostRequest(ctx, "ports.pickLoopback", nil, &port)
	return port, err
}

// RemoteProcessDebugPortReady observes whether the owned process session listens on port.
func (c *Client) RemoteProcessDebugPortReady(ctx context.Context, processID uint64, port int) (bool, error) {
	var ready bool
	err := c.remoteWorkspaceHostRequest(ctx, "process.debugPortReady", struct {
		ProcessID uint64 `json:"processId"`
		Port      int    `json:"port"`
	}{processID, port}, &ready)
	return ready, err
}

// RemoteDebugLaunch describes the scoped directory and environment for a debuggee.
type RemoteDebugLaunch struct {
	Cwd  string  `json:"cwd"`
	Path *string `json:"path"`
}

// ResolveRemoteDebugLaunch checks the working directory and plans PATH on the captured host.
func (c *Client) ResolveRemoteDebugLaunch(ctx context.Context, cwd RemoteScopedDirectory, path *string, pathPrepend []string) (RemoteDebugLaunch, error) {
	var launch RemoteDebugLaunch
	err := c.remoteWorkspaceHostRequest(ctx, "process.resolveDebugLaunch", struct {
		Cwd         RemoteScopedDirectory `json:"scopedCwd"`
		Path        *string               `json:"path,omitempty"`
		PathPrepend []string              `json:"pathPrepend,omitempty"`
	}{cwd, path, pathPrepend}, &launch)
	return launch, err
}

// remoteWorkspaceHostRequest derives the session from the operation's
// attachment and reports loss only to that attachment.
func (c *Client) remoteWorkspaceHostRequest(ctx context.Context, method string, params, result any) error {
	wire, binding, session, err := remoteWorkspaceRequest(ctx, method)
	if err != nil {
		return err
	}
	if wire == nil {
		return &Error{Code: CodeConnectionClosed, Message: "the remote workspace is not connected"}
	}
	err = c.RemoteHostRequest(ctx, wire.SessionID, method, params, result)
	remoteWorkspaceAnswered(binding, session, err)
	return err
}

// RemoteProcessOpen is how a host process starts.
type RemoteProcessOpen struct {
	// Argv is the program and its arguments; a program without "/" is looked up on the PATH of
	// Environment.
	Argv []string `json:"argv"`
	// Cwd is the absolute host working directory; empty starts in the user's home.
	Cwd string `json:"cwd,omitempty"`
	// ScopedCwd asks the host to resolve the working directory within the workspace.
	ScopedCwd *RemoteScopedDirectory `json:"scopedCwd,omitempty"`
	// Environment is the base environment: "login" asks the user's login shell for it, as an SSH
	// login sees it, and "server" (the default when empty) is the remote server's own.
	Environment string `json:"environment,omitempty"`
	// Env adds variables to the base environment.
	Env map[string]string `json:"env,omitempty"`
	// PathPrepend adds toolchain directories ahead of the host's effective PATH.
	PathPrepend []string `json:"pathPrepend,omitempty"`
	// PipeStdin keeps the program's standard input open; false gives it /dev/null.
	PipeStdin bool `json:"pipeStdin,omitempty"`
	// Label is what server.state reports for the process, so the window that closes the session
	// can name what still runs. Nil reports none.
	Label *RemoteResourceLabel `json:"label,omitempty"`
}

// RemoteProcessEnvironmentLogin is the base environment of a process the user starts: the one
// their login shell sets up, so tools installed through the profile are on the PATH.
const RemoteProcessEnvironmentLogin = "login"

// RemoteProcessEvents receive a host process's events. Both run on the request's goroutine and
// must return at once: they must not wait for a UI thread. Core holds 1024 undelivered events
// per process and ends the process, and with it the request, when a subscriber stops reading.
type RemoteProcessEvents struct {
	// Started is called once, before any output, with the id process.kill takes and the
	// process's id on the host.
	Started func(processID uint64, pid int)
	// Output receives the bytes the program wrote to stream, "stdout" or "stderr", in order.
	// Output owns data.
	Output func(stream string, data []byte)
}

// RemoteProcessExit is how a host process's leader ended: ExitCode when it exited, Signal when a
// signal ended it.
type RemoteProcessExit struct {
	ExitCode *int `json:"exitCode"`
	Signal   *int `json:"signal"`
}

// remoteProcessEvent is one remote event of remote.runProcess.
type remoteProcessEvent struct {
	Type   string `json:"type"`
	Event  string `json:"event"`
	Params struct {
		ProcessID uint64 `json:"processId"`
		PID       *int   `json:"pid"`
		Stream    string `json:"stream"`
		Data      string `json:"data"`
	} `json:"params"`
}

// errRemoteProcessEvent is an event of remote.runProcess the client cannot read.
var errRemoteProcessEvent = errors.New("core: unreadable remote process event")

// RemoteRunProcess runs a process on the host of sessionID until its leader exits, and returns
// how it ended. It blocks the calling goroutine for the process's whole life, so run it off the
// UI thread. Ending ctx kills the process: Core sends process.kill with force, which kills every
// process of its session, and returns the context's error. A broken or unknown session fails
// with CodeConnectionClosed, and a program that cannot start with CodeProcessFailed. An event
// the client cannot read ends the process too and is returned as the error, since its output
// would be incomplete.
func (c *Client) RemoteRunProcess(ctx context.Context, sessionID string, open RemoteProcessOpen, events RemoteProcessEvents) (RemoteProcessExit, error) {
	return c.runRemoteProcess(ctx, sessionID, open, events, nil, nil)
}

// RunRemoteProcess runs on the workspace attachment captured in ctx.
func (c *Client) RunRemoteProcess(ctx context.Context, open RemoteProcessOpen, events RemoteProcessEvents) (RemoteProcessExit, error) {
	wire, binding, session, err := remoteWorkspaceRequest(ctx, "workspace.process")
	if err != nil {
		return RemoteProcessExit{}, err
	}
	if wire == nil {
		return RemoteProcessExit{}, &Error{Code: CodeConnectionClosed, Message: "the remote workspace is not connected"}
	}
	return c.runRemoteProcess(ctx, wire.SessionID, open, events, binding, session)
}

func (c *Client) runRemoteProcess(ctx context.Context, sessionID string, open RemoteProcessOpen, events RemoteProcessEvents, binding *RemoteWorkspace, session *remoteAttachment) (RemoteProcessExit, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var unreadable error
	observer := func(raw json.RawMessage) {
		if unreadable != nil {
			return
		}
		if err := deliverRemoteProcessEvent(raw, events); err != nil {
			// Cancelling ends the process rather than letting it run unseen.
			unreadable = err
			cancel()
		}
	}
	var exit RemoteProcessExit
	observationErr, err := c.ExecuteWithEvents(ctx, "remote.runProcess", struct {
		SessionID string            `json:"sessionId"`
		Params    RemoteProcessOpen `json:"params"`
	}{sessionID, open}, &exit, observer)
	remoteWorkspaceAnswered(binding, session, err)
	switch {
	case unreadable != nil:
		return RemoteProcessExit{}, unreadable
	case err != nil:
		return RemoteProcessExit{}, err
	case observationErr != nil:
		return RemoteProcessExit{}, observationErr
	}
	return exit, nil
}

// deliverRemoteProcessEvent hands one event of remote.runProcess to events. Events of other kinds
// are not the process's and are ignored.
func deliverRemoteProcessEvent(raw json.RawMessage, events RemoteProcessEvents) error {
	if !bytes.Contains(raw, []byte(`"remote"`)) {
		return nil
	}
	var event remoteProcessEvent
	if err := json.Unmarshal(raw, &event); err != nil || event.Type != "remote" {
		return nil
	}
	switch event.Event {
	case "process.started":
		if event.Params.ProcessID == 0 {
			return errRemoteProcessEvent
		}
		if events.Started != nil {
			pid := 0
			if event.Params.PID != nil {
				pid = *event.Params.PID
			}
			events.Started(event.Params.ProcessID, pid)
		}
	case "process.output":
		if event.Params.Stream != "stdout" && event.Params.Stream != "stderr" {
			return errRemoteProcessEvent
		}
		data, err := base64.StdEncoding.DecodeString(event.Params.Data)
		if err != nil {
			return errRemoteProcessEvent
		}
		if events.Output != nil && len(data) > 0 {
			events.Output(event.Params.Stream, data)
		}
	}
	return nil
}

// RemoteProcessKill signals every process of the host process processID of sessionID: SIGTERM,
// or SIGKILL with force. A process whose session already ended is no error.
func (c *Client) RemoteProcessKill(ctx context.Context, sessionID string, processID uint64, force bool) error {
	err := c.RemoteHostRequest(ctx, sessionID, "process.kill", struct {
		ProcessID uint64 `json:"processId"`
		Force     bool   `json:"force"`
	}{processID, force}, nil)
	if remoteHostCode(err) == "UNKNOWN_RESOURCE" {
		return nil
	}
	return err
}

// RemoteTempDirectory creates a fresh folder only the host account can open (0700) in the host's
// temporary directory and returns its absolute path. prefix names it for diagnostics: one to 64
// ASCII letters, digits, "-" and "_". The caller removes it (RemoteRemove) when done.
func (c *Client) RemoteTempDirectory(ctx context.Context, sessionID, prefix string) (string, error) {
	var result struct {
		Path string `json:"path"`
	}
	if err := c.RemoteHostRequest(ctx, sessionID, "fs.tempDirectory", struct {
		Prefix string `json:"prefix"`
	}{prefix}, &result); err != nil {
		return "", err
	}
	return result.Path, nil
}

// RemoteRemove deletes the host path, a folder with everything in it when recursive. Links are
// removed, never followed.
func (c *Client) RemoteRemove(ctx context.Context, sessionID, path string, recursive bool) error {
	return c.RemoteHostRequest(ctx, sessionID, "fs.remove", struct {
		Path      string `json:"path"`
		Recursive bool   `json:"recursive"`
	}{path, recursive}, nil)
}

// WriteRemoteProcessInput sends a bounded chunk of bytes to a process owned
// by the caller's captured connection.
func (c *Client) WriteRemoteProcessInput(ctx context.Context, processID uint64, data []byte) error {
	if workspace := RemoteWorkspaceOf(ctx); workspace == nil || workspace.CapturedConnection(ctx) == nil {
		return &Error{Code: CodeConnectionClosed, Message: "remote process input has no captured connection"}
	}
	return c.remoteWorkspaceHostRequest(ctx, "process.writeStdin", struct {
		ProcessID uint64 `json:"processId"`
		Data      []byte `json:"data"`
	}{processID, data}, nil)
}

// CreateRemoteRunDirectory allocates private scratch on the captured session.
func (c *Client) CreateRemoteRunDirectory(ctx context.Context, id string) (string, error) {
	return c.createRemoteRunDirectory(ctx, "fs.createRunDirectory", id)
}

func (c *Client) createRemoteRunDirectory(ctx context.Context, method, id string) (string, error) {
	var result struct {
		Path string `json:"path"`
	}
	err := c.remoteWorkspaceHostRequest(ctx, method, map[string]string{"directoryId": id}, &result)
	if err == nil && !path.IsAbs(result.Path) {
		err = errors.New("core: invalid remote run directory")
	}
	return result.Path, err
}

// WriteRemoteRunFile creates a file supplied by Core's run decoder in private session scratch.
func (c *Client) WriteRemoteRunFile(ctx context.Context, file string, data []byte) error {
	wire, binding, session, err := remoteWorkspaceRequest(ctx, "workspace.runFile")
	if err != nil {
		return err
	}
	if wire == nil {
		return &Error{Code: CodeConnectionClosed, Message: "the remote workspace is not connected"}
	}
	_, saved, err := c.RemoteWriteFile(ctx, wire.SessionID, file, data, nil)
	remoteWorkspaceAnswered(binding, session, err)
	if err == nil && !saved {
		err = errors.New("core: the remote run file already exists")
	}
	return err
}

// ReleaseRemoteRunDirectory frees the scratch owned by the captured session.
func (c *Client) ReleaseRemoteRunDirectory(ctx context.Context, id string) error {
	params := map[string]string{"directoryId": id}
	// A replacement attachment must never receive cleanup for this random
	// resource. The original session can still own it until close completes.
	connection, _ := ctx.Value(remoteWorkspaceKey{}).(RemoteWorkspaceConnection)
	if connection.session != nil {
		err := c.RemoteHostRequest(ctx, connection.session.id, "fs.releaseRunDirectory", params, nil)
		remoteWorkspaceAnswered(connection.workspace, connection.session, err)
		return err
	}
	return c.remoteWorkspaceHostRequest(ctx, "fs.releaseRunDirectory", params, nil)
}
