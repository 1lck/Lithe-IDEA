package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"unicode/utf8"
)

// RemoteTerminalOpen is how a host terminal starts.
type RemoteTerminalOpen struct {
	// Argv is the program and its arguments; empty runs the user's login shell as a login
	// shell, which reads the same profile files as an SSH login.
	Argv []string `json:"argv,omitempty"`
	// Cwd is the absolute host working directory; empty starts in the user's home.
	Cwd string `json:"cwd,omitempty"`
	// Env adds variables to the server's environment. TERM is xterm-256color unless Env sets
	// it.
	Env map[string]string `json:"env,omitempty"`
	// Columns and Rows are the size in character cells; both must be at least 1.
	Columns uint16 `json:"columns"`
	Rows    uint16 `json:"rows"`
	// Label is what server.state reports for the terminal, so the window that closes the
	// session can name what still runs. Nil reports none.
	Label *RemoteResourceLabel `json:"label,omitempty"`
}

// RemoteResourceLabel names a host resource in server.state.
type RemoteResourceLabel struct {
	// Kind is the client's category, such as "terminal"; at most 64 characters.
	Kind string `json:"kind"`
	// Name is shown to the user; at most 256 characters, and NewRemoteResourceLabel cuts a
	// longer one.
	Name string `json:"name"`
}

// Core's limits on a resource label, in characters.
const (
	remoteLabelKindChars = 64
	remoteLabelNameChars = 256
)

// NewRemoteResourceLabel is a label of kind and name cut to the lengths Core accepts, so a
// long tab title cannot fail the request.
func NewRemoteResourceLabel(kind, name string) *RemoteResourceLabel {
	return &RemoteResourceLabel{Kind: cutRunes(kind, remoteLabelKindChars), Name: cutRunes(name, remoteLabelNameChars)}
}

// cutRunes is text cut to at most limit characters.
func cutRunes(text string, limit int) string {
	if utf8.RuneCountInString(text) <= limit {
		return text
	}
	return string([]rune(text)[:limit])
}

// RemoteTerminalEvents receive a host terminal's events. Both run on the request's goroutine
// and must return at once: they must not wait for a UI thread or for the terminal's input.
// Core holds 1024 undelivered events per terminal and ends the terminal, and with it the
// request, when a subscriber stops reading.
type RemoteTerminalEvents struct {
	// Started is called once, before any output, with the id terminal.write, terminal.resize
	// and terminal.close take.
	Started func(terminalID uint64)
	// Output receives the bytes the program wrote, in order. Output owns data.
	Output func(data []byte)
}

// RemoteTerminalExit is how a host terminal's program ended: ExitCode when it exited, Signal
// when a signal ended it.
type RemoteTerminalExit struct {
	ExitCode *int `json:"exitCode"`
	Signal   *int `json:"signal"`
}

// remoteTerminalEvent is one remote event of remote.runTerminal.
type remoteTerminalEvent struct {
	Type   string `json:"type"`
	Event  string `json:"event"`
	Params struct {
		TerminalID uint64 `json:"terminalId"`
		Data       string `json:"data"`
	} `json:"params"`
}

// errRemoteTerminalEvent is an event of remote.runTerminal the client cannot read.
var errRemoteTerminalEvent = errors.New("core: unreadable remote terminal event")

// RemoteRunTerminal runs a terminal on the host of sessionID until its program exits, and
// returns how it ended. It blocks the calling goroutine for the terminal's whole life, so run
// it off the UI thread. Ending ctx closes the terminal: Core sends terminal.close, which hangs
// the program up and kills it two seconds later, and returns the context's error. A broken or
// unknown session fails with CodeConnectionClosed, and a program that cannot start with
// CodeProcessFailed. An event the client cannot read ends the terminal too and is returned as
// the error, since its output would be incomplete.
func (c *Client) RemoteRunTerminal(ctx context.Context, sessionID string, open RemoteTerminalOpen, events RemoteTerminalEvents) (RemoteTerminalExit, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var unreadable error
	observer := func(raw json.RawMessage) {
		if unreadable != nil {
			return
		}
		if err := deliverRemoteTerminalEvent(raw, events); err != nil {
			// Cancelling ends the terminal rather than letting it run unseen.
			unreadable = err
			cancel()
		}
	}
	var exit RemoteTerminalExit
	observationErr, err := c.ExecuteWithEvents(ctx, "remote.runTerminal", struct {
		SessionID string             `json:"sessionId"`
		Params    RemoteTerminalOpen `json:"params"`
	}{sessionID, open}, &exit, observer)
	switch {
	case unreadable != nil:
		return RemoteTerminalExit{}, unreadable
	case err != nil:
		return RemoteTerminalExit{}, err
	case observationErr != nil:
		return RemoteTerminalExit{}, observationErr
	}
	return exit, nil
}

// deliverRemoteTerminalEvent hands one event of remote.runTerminal to events. Events of other
// kinds are not the terminal's and are ignored.
func deliverRemoteTerminalEvent(raw json.RawMessage, events RemoteTerminalEvents) error {
	if !bytes.Contains(raw, []byte(`"remote"`)) {
		return nil
	}
	var event remoteTerminalEvent
	if err := json.Unmarshal(raw, &event); err != nil || event.Type != "remote" {
		return nil
	}
	switch event.Event {
	case "terminal.started":
		if events.Started != nil {
			events.Started(event.Params.TerminalID)
		}
	case "terminal.output":
		data, err := base64.StdEncoding.DecodeString(event.Params.Data)
		if err != nil {
			return errRemoteTerminalEvent
		}
		if events.Output != nil && len(data) > 0 {
			events.Output(data)
		}
	}
	return nil
}

// RemoteTerminalWrite types data into the host terminal terminalID of sessionID. busy is true
// when the program has not read what it was given before and the host refused data without
// taking any of it: sending the same bytes again later is safe. A terminal that already ended
// fails with CodeProcessFailed, a broken or unknown session with CodeConnectionClosed.
func (c *Client) RemoteTerminalWrite(ctx context.Context, sessionID string, terminalID uint64, data []byte) (busy bool, err error) {
	err = c.RemoteHostRequest(ctx, sessionID, "terminal.write", struct {
		TerminalID uint64 `json:"terminalId"`
		Data       string `json:"data"`
	}{terminalID, base64.StdEncoding.EncodeToString(data)}, nil)
	if remoteHostCode(err) == "BUSY" {
		return true, nil
	}
	return false, err
}

// RemoteTerminalResize tells the host terminal terminalID of sessionID its size in cells; both
// must be at least 1.
func (c *Client) RemoteTerminalResize(ctx context.Context, sessionID string, terminalID uint64, columns, rows uint16) error {
	return c.RemoteHostRequest(ctx, sessionID, "terminal.resize", struct {
		TerminalID uint64 `json:"terminalId"`
		Columns    uint16 `json:"columns"`
		Rows       uint16 `json:"rows"`
	}{terminalID, columns, rows}, nil)
}

// remoteHostCode is the host protocol's code of a host method that failed, such as "BUSY" or
// "UNKNOWN_RESOURCE"; empty when err is not one. Core reports it in the error's details.
func remoteHostCode(err error) string {
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Details == "" {
		return ""
	}
	var details struct {
		RemoteCode string `json:"remoteCode"`
	}
	if json.Unmarshal([]byte(coreErr.Details), &details) != nil {
		return ""
	}
	return details.RemoteCode
}
