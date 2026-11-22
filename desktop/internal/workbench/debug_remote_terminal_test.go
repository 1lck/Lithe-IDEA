package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type debugTerminalReplies chan []byte

func (output debugTerminalReplies) Write(data []byte) (int, error) {
	select {
	case output <- bytes.Clone(data):
		return len(data), nil
	default:
		return 0, fmt.Errorf("the fixture did not consume the debug adapter's responses")
	}
}

func (debugTerminalReplies) Close() error { return nil }

// Test the window side of the reverse request using the real DAP reply reducer.
// The remote Core test supplies the remoteDirectory projection and path validation.
func TestRemoteDebugTerminalRepliesWithHostPIDAndStopsWithSession(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	p.trust.codeAllowed.Store(true)
	connection, ok := captureWorkspaceConnection(p)
	if !ok {
		t.Fatal("the workspace did not connect")
	}
	ctx, cancel := context.WithCancel(p.ctx)
	t.Cleanup(cancel)
	startup := make(chan struct{})
	close(startup)
	replies := make(debugTerminalReplies, 4)
	session := &debugSession{
		id: "desktop-debug-remote-terminal-fixture", adapterID: "fixture", project: p,
		ctx: ctx, cancel: cancel, startupDone: startup, created: true, connection: connection,
		generation: p.debug.generation, transport: replies,
	}
	_, err := k.CreateDebugSession(core.WithoutRemoteWorkspace(ctx), core.DebugCreateSessionRequest{
		SessionID: session.id, AdapterID: session.adapterID, RootPath: p.root, SupportsRunInTerminalRequest: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	p.debug.addSession(session)

	request := func(sequence int) {
		t.Helper()
		body := fmt.Sprintf(`{"seq":%d,"type":"request","command":"runInTerminal","arguments":`+
			`{"cwd":%q,"args":["/usr/bin/debuggee","a b","$(literal)"],"env":{"SET_ME":"value","DROP_ME":null},"title":"Fixture debuggee"}}`,
			sequence, remoteTestFolder+"/src")
		frame := fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
		update, err := k.ReceiveDebug(ctx, session.id, []byte(frame))
		if err != nil {
			t.Fatal(err)
		}
		if len(update.Events) != 1 || update.Events[0].RunInTerminal == nil {
			t.Fatalf("missing decoded reverse terminal request: %+v", update)
		}
		// The simulated host has no registered Core SSH transport. This is
		// the only field added to the result Core would send on a real host.
		directory := "src"
		update.Events[0].RunInTerminal.RemoteDirectory = &directory
		h.app.applyDebugUpdate(p, session, update)
	}
	type reply struct {
		Sequence int    `json:"request_seq"`
		Command  string `json:"command"`
		Success  bool   `json:"success"`
		Message  string `json:"message"`
		Body     struct {
			ProcessID int64 `json:"processId"`
		} `json:"body"`
	}
	readReply := func(sequence int) reply {
		t.Helper()
		var data []byte
		awaitStateWithin(t, h, 8*time.Second, "the debug adapter's terminal response", func() bool {
			select {
			case data = <-replies:
				return true
			default:
				return false
			}
		})
		_, body, _ := bytes.Cut(data, []byte("\r\n\r\n"))
		var response reply
		if err := json.Unmarshal(body, &response); err != nil || response.Sequence != sequence || response.Command != "runInTerminal" {
			t.Fatalf("unexpected debug adapter response %s: %v", body, err)
		}
		return response
	}

	k.terminals.set(func(host *remoteHostTerminals) {
		host.refuse = &core.Error{Code: core.CodeProcessFailed, Message: "fixture refused to start"}
	})
	request(10)
	if response := readReply(10); response.Success || response.Message != "fixture refused to start" {
		t.Fatalf("failed terminal launch response = %+v", response)
	}

	request(11)
	if response := readReply(11); !response.Success || response.Body.ProcessID != remoteTestTerminalPID {
		t.Fatalf("successful terminal launch response = %+v", response)
	}
	runs := k.terminals.started()
	if len(runs) != 1 {
		t.Fatalf("started host terminals = %d, want one", len(runs))
	}
	run := runs[0]
	if run.session != connection.SessionID() || run.open.ScopedCwd == nil ||
		*run.open.ScopedCwd != (core.RemoteScopedDirectory{Root: remoteTestFolder, Path: "src"}) ||
		!slices.Equal(run.open.Argv, []string{"/usr/bin/debuggee", "a b", "$(literal)"}) ||
		run.open.Environment != "login" || len(run.open.Env) != 1 || run.open.Env["SET_ME"] != "value" ||
		!slices.Equal(run.open.UnsetEnv, []string{"DROP_ME"}) {
		t.Fatalf("terminal opened on %q with %+v", run.session, run.open)
	}
	if len(session.remoteTerminals) != 2 {
		t.Fatalf("session owns terminal tabs %v, want both launch attempts", session.remoteTerminals)
	}
	term := p.terms.find(session.remoteTerminals[1])
	h.awaitTerminal(term, remoteHostPrompt)
	h.app.stopDebug(p)
	k.terminals.await(t, "the debuggee's terminal to stop", func() bool {
		select {
		case <-run.ended:
			return true
		default:
			return false
		}
	})
	if p.terms.find(term.id) != nil {
		t.Fatal("the debug session left its terminal tab behind")
	}
}
