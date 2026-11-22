package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
)

// RemoteProcessOpen is how a host process starts.
type RemoteProcessOpen struct {
	// Argv is the program and its arguments; a program without "/" is looked up on the PATH of
	// Environment.
	Argv []string `json:"argv"`
	// Cwd is the absolute host working directory; empty starts in the user's home.
	Cwd string `json:"cwd,omitempty"`
	// Environment is the base environment: "login" asks the user's login shell for it, as an SSH
	// login sees it, and "server" (the default when empty) is the remote server's own.
	Environment string `json:"environment,omitempty"`
	// Env adds variables to the base environment.
	Env map[string]string `json:"env,omitempty"`
	// PipeStdin keeps the program's standard input open; false gives it /dev/null.
	PipeStdin bool `json:"pipeStdin,omitempty"`
	// Label is what server.state reports for the process, so the window that closes the session
	// can name what still runs. Nil reports none.
	Label *RemoteResourceLabel `json:"label,omitempty"`
}

// RemoteProcessEnvironmentLogin is the base environment of a process the user starts: the one
// their login shell sets up, so tools installed through the profile are on the PATH.
const RemoteProcessEnvironmentLogin = "login"

// RemoteProcessEvents receive a host process's events. They run on the request's goroutine and
// must return at once: they must not wait for a UI thread. Core holds 1024 undelivered events
// per process and ends the process, and with it the request, when a subscriber stops reading.
type RemoteProcessEvents struct {
	// Started is called once, before any output, with the id process.kill takes and the
	// process's id on the host. remote.attachProcess does not call it.
	Started func(processID uint64, pid int)
	// Attached is called once, before any output, when remote.attachProcess receives the process
	// again. truncated means some of what the process wrote while nobody received it is missing.
	Attached func(truncated bool)
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

// remoteProcessEvent is one remote event of remote.runProcess or remote.attachProcess.
type remoteProcessEvent struct {
	Type   string `json:"type"`
	Event  string `json:"event"`
	Params struct {
		ProcessID uint64 `json:"processId"`
		PID       *int   `json:"pid"`
		Stream    string `json:"stream"`
		Data      string `json:"data"`
		Truncated bool   `json:"truncated"`
	} `json:"params"`
}

// errRemoteProcessEvent is an event of remote.runProcess or remote.attachProcess the client
// cannot read.
var errRemoteProcessEvent = errors.New("core: unreadable remote process event")

// RemoteRunProcess runs a process on the host of sessionID until its leader exits, and returns
// how it ended. It blocks the calling goroutine for the process's whole life, so run it off the
// UI thread. Ending ctx kills the process: Core sends process.kill with force, which kills every
// process of its session, and returns the context's error. A broken or unknown session fails
// with CodeConnectionClosed, and a program that cannot start with CodeProcessFailed. An event
// the client cannot read ends the process too and is returned as the error, since its output
// would be incomplete.
func (c *Client) RemoteRunProcess(ctx context.Context, sessionID string, open RemoteProcessOpen, events RemoteProcessEvents) (RemoteProcessExit, error) {
	return c.receiveRemoteProcess(ctx, "remote.runProcess", struct {
		SessionID string            `json:"sessionId"`
		Params    RemoteProcessOpen `json:"params"`
	}{sessionID, open}, events)
}

// RemoteAttachProcess receives again the host process processID that an earlier connection to
// the host session started, after sessionID resumed that session (design §9.3): first Attached,
// then what the process wrote meanwhile and after, until its leader exits, and returns how it
// ended. The request then owns the process as RemoteRunProcess's does: ending ctx kills it. A
// broken or unknown session fails with CodeConnectionClosed, a process nothing can receive any
// more with CodeRemoteProcessGone, and one another request receives with
// CodeRemoteProcessAttached.
func (c *Client) RemoteAttachProcess(ctx context.Context, sessionID string, processID uint64, events RemoteProcessEvents) (RemoteProcessExit, error) {
	return c.receiveRemoteProcess(ctx, "remote.attachProcess", struct {
		SessionID string `json:"sessionId"`
		ProcessID uint64 `json:"processId"`
	}{sessionID, processID}, events)
}

// receiveRemoteProcess runs command, which relays one host process's events until its leader
// exits, and returns the exit. An event the client cannot read cancels the request, which ends
// the process, and is returned as the error.
func (c *Client) receiveRemoteProcess(ctx context.Context, command string, payload any, events RemoteProcessEvents) (RemoteProcessExit, error) {
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
	observationErr, err := c.ExecuteWithEvents(ctx, command, payload, &exit, observer)
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

// deliverRemoteProcessEvent hands one event of remote.runProcess or remote.attachProcess to
// events. Events of other kinds are not the process's and are ignored.
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
		if events.Started != nil {
			pid := 0
			if event.Params.PID != nil {
				pid = *event.Params.PID
			}
			events.Started(event.Params.ProcessID, pid)
		}
	case "process.attached":
		if events.Attached != nil {
			events.Attached(event.Params.Truncated)
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
