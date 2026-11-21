package core

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

// The terminal's events reach their callbacks in order: started with its id, output decoded,
// an empty output dropped, and events that are not the terminal's ignored. Output that is not
// base64 is an error, since what the terminal shows would be incomplete.
func TestRemoteTerminalEventsReachTheirCallbacks(t *testing.T) {
	var got []string
	events := RemoteTerminalEvents{
		Started: func(id uint64) { got = append(got, "started "+strconv.FormatUint(id, 10)) },
		Output:  func(data []byte) { got = append(got, "output "+string(data)) },
	}
	for _, raw := range []string{
		`{"type":"progress","message":"remote"}`,
		`{"type":"remote","event":"terminal.started","params":{"terminalId":7}}`,
		`{"type":"remote","event":"terminal.output","params":{"terminalId":7,"data":"aGk="}}`,
		`{"type":"remote","event":"terminal.output","params":{"terminalId":7,"data":""}}`,
		`{"type":"remote","event":"terminal.exit","params":{"terminalId":7,"exitCode":0}}`,
		`{"type":"remote","event":"watch.changed","params":{}}`,
	} {
		if err := deliverRemoteTerminalEvent(json.RawMessage(raw), events); err != nil {
			t.Fatalf("event %s: %v", raw, err)
		}
	}
	if want := []string{"started 7", "output hi"}; strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("delivered %q, want %q", got, want)
	}
	bad := `{"type":"remote","event":"terminal.output","params":{"terminalId":7,"data":"not base64!"}}`
	if err := deliverRemoteTerminalEvent(json.RawMessage(bad), events); !errors.Is(err, errRemoteTerminalEvent) {
		t.Fatalf("unreadable output = %v, want errRemoteTerminalEvent", err)
	}
}

// The host protocol's code is read from a Core error's details; anything else has none.
func TestRemoteHostCodeReadsTheDetails(t *testing.T) {
	busy := &Error{Command: "remote.hostRequest", Code: CodeProcessFailed, Details: `{"remoteCode":"BUSY"}`}
	if got := remoteHostCode(busy); got != "BUSY" {
		t.Fatalf("code = %q, want BUSY", got)
	}
	for _, err := range []error{
		nil,
		errors.New("plain"),
		&Error{Code: CodeProcessFailed},
		&Error{Code: CodeProcessFailed, Details: "not json"},
		&Error{Code: CodeProcessFailed, Details: `{"other":"BUSY"}`},
	} {
		if got := remoteHostCode(err); got != "" {
			t.Errorf("code of %v = %q, want none", err, got)
		}
	}
}

// A label longer than Core accepts is cut by characters, not bytes.
func TestNewRemoteResourceLabelCutsToCoreLimits(t *testing.T) {
	label := NewRemoteResourceLabel(strings.Repeat("k", 70), strings.Repeat("终", 300))
	if utf8.RuneCountInString(label.Kind) != remoteLabelKindChars || utf8.RuneCountInString(label.Name) != remoteLabelNameChars || !utf8.ValidString(label.Name) {
		t.Fatalf("label kind %d, name %d characters", utf8.RuneCountInString(label.Kind), utf8.RuneCountInString(label.Name))
	}
	if short := NewRemoteResourceLabel("terminal", "devbox"); short.Kind != "terminal" || short.Name != "devbox" {
		t.Fatalf("short label = %+v", short)
	}
}

// With the real kernel, a terminal, its input and its size over a session Core does not know
// fail with connection_closed, and the run never reports a start.
func TestRemoteTerminalOfAnUnknownSession(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	started := false
	_, err := client.RemoteRunTerminal(ctx, "no-such-session", RemoteTerminalOpen{Columns: 80, Rows: 24}, RemoteTerminalEvents{
		Started: func(uint64) { started = true },
	})
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed || started {
		t.Fatalf("runTerminal = %v, started %v, want connection_closed", err, started)
	}
	if busy, err := client.RemoteTerminalWrite(ctx, "no-such-session", 1, []byte("x")); busy || !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("write = %v, %v, want connection_closed", busy, err)
	}
	if err := client.RemoteTerminalResize(ctx, "no-such-session", 1, 80, 24); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("resize = %v, want connection_closed", err)
	}
}
