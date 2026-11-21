package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
)

// shippedTargets are the server builds the application ships; the paths do not exist, so a host
// that has a build reads none and Core sends nothing.
var shippedTargets = []RemoteServerBuild{
	{Target: "x86_64-unknown-linux-musl", Path: "/nonexistent/lithe-remote-server-x86_64", SHA256: strings.Repeat("a", 64)},
	{Target: "aarch64-unknown-linux-musl", Path: "/nonexistent/lithe-remote-server-aarch64", SHA256: strings.Repeat("b", 64)},
}

// A request of a remote workspace context carries the binding's session and roots, a remote.*
// command never does, and a binding without a session fails before Core sees the request.
func TestRemoteWorkspaceRequestsCarryTheBindingExceptSessionCommands(t *testing.T) {
	binding := NewRemoteWorkspace("/cache/remote/1/abc/repo", "/srv/repo", nil)
	ctx := WithRemoteWorkspace(context.Background(), binding)

	if wire, _, _, err := remoteWorkspaceRequest(context.Background(), "file.read"); wire != nil || err != nil {
		t.Fatalf("a local context sent %+v, %v", wire, err)
	}
	_, _, _, err := remoteWorkspaceRequest(ctx, "file.read")
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("a binding without a session = %v, want connection_closed", err)
	}

	binding.Attach("session-7")
	wire, owner, session, err := remoteWorkspaceRequest(ctx, "file.read")
	if err != nil || owner != binding || session == nil || *session != "session-7" {
		t.Fatalf("request = %+v, %v, %v", wire, session, err)
	}
	encoded, err := json.Marshal(requestEnvelope{Command: "file.read", Payload: struct{}{}, RemoteWorkspace: wire})
	if err != nil {
		t.Fatal(err)
	}
	if want := `"remoteWorkspace":{"sessionId":"session-7","localRoot":"/cache/remote/1/abc/repo","remoteRoot":"/srv/repo"}`; !strings.Contains(string(encoded), want) {
		t.Fatalf("envelope = %s, want it to contain %s", encoded, want)
	}
	for _, command := range []string{"remote.readDir", "remote.disconnect", "remote.hostRequest"} {
		if wire, _, _, err := remoteWorkspaceRequest(ctx, command); wire != nil || err != nil {
			t.Errorf("%s sent %+v, %v", command, wire, err)
		}
	}
	if got := binding.Detach(); got != "session-7" || binding.SessionID() != "" {
		t.Fatalf("Detach = %q, then SessionID = %q", got, binding.SessionID())
	}
}

// With the real kernel: a command without a remote adapter is refused instead of reading the
// placeholder, and a command with one over a session Core does not know reports the loss once
// and detaches the binding, so the next request fails without reaching Core.
func TestCoreRefusesUnadaptedCommandsAndAClosedSessionDetachesTheBinding(t *testing.T) {
	client := NewClient()
	var lost atomic.Int32
	var lostSession atomic.Pointer[string]
	binding := NewRemoteWorkspace(t.TempDir(), "/srv/repo", func(sessionID string) {
		lost.Add(1)
		lostSession.Store(&sessionID)
	})
	binding.Attach("no-such-session")
	ctx := WithRemoteWorkspace(testContext(t), binding)

	err := client.Execute(ctx, "core.ping", nil, nil)
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Code != CodeNotSupported {
		t.Fatalf("core.ping in a remote workspace = %v, want not_supported", err)
	}
	if lost.Load() != 0 || binding.SessionID() != "no-such-session" {
		t.Fatal("a refused command detached the session")
	}

	_, err = client.ListDirectories(ctx, binding.LocalRoot(), []string{""})
	if !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("listing over an unknown session = %v, want connection_closed", err)
	}
	if lost.Load() != 1 || lostSession.Load() == nil || *lostSession.Load() != "no-such-session" || binding.SessionID() != "" {
		t.Fatalf("lost %d times, binding session %q", lost.Load(), binding.SessionID())
	}
	_, err = client.ListDirectories(ctx, binding.LocalRoot(), []string{""})
	if !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed || lost.Load() != 1 {
		t.Fatalf("after the loss = %v and lost %d times, want a local connection_closed", err, lost.Load())
	}
}

// The session commands answer for a session Core does not know: nothing to close, and a broken
// connection for a listing or a host request.
func TestRemoteSessionCommandsOfAnUnknownSession(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	closed, err := client.RemoteDisconnect(ctx, "no-such-session")
	if err != nil || closed {
		t.Fatalf("disconnect = %v, %v, want nothing closed", closed, err)
	}
	var coreErr *Error
	if _, err := client.RemoteReadDir(ctx, "no-such-session", "/"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("readDir = %v, want connection_closed", err)
	}
	if err := client.RemoteServerState(ctx, "no-such-session"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("server.state = %v, want connection_closed", err)
	}
}

// Closing every session ends the process's remote development: Core then refuses to connect.
// It runs in a child process, since the refusal lasts as long as the process.
func TestRemoteCloseAllRefusesLaterConnections(t *testing.T) {
	if os.Getenv("LITHE_TEST_REMOTE_CLOSE_ALL") == "1" {
		client := NewClient()
		ctx := testContext(t)
		if closed, err := client.RemoteCloseAll(ctx); err != nil || closed != 0 {
			t.Fatalf("closeAll = %d, %v, want nothing to close", closed, err)
		}
		_, err := client.RemoteConnect(ctx, RemoteConnectRequest{
			Connection:    SSHConnection{Host: "devbox"},
			Servers:       shippedTargets,
			ServerVersion: "0.0.0-test",
		})
		var coreErr *Error
		if !errors.As(err, &coreErr) || coreErr.Code != CodeCancelled {
			t.Fatalf("connect after closeAll = %v, want cancelled", err)
		}
		return
	}
	child := exec.CommandContext(testContext(t), os.Args[0], "-test.run=^TestRemoteCloseAllRefusesLaterConnections$", "-test.count=1")
	child.Env = append(os.Environ(), "LITHE_TEST_REMOTE_CLOSE_ALL=1")
	if output, err := child.CombinedOutput(); err != nil {
		t.Fatalf("child: %v\n%s", err, output)
	}
}

// Connecting relays the password question like a probe. A host without a shipped build is
// unsupportedPlatform and gets nothing; a host with one fails with remote_server_invalid, since
// the shipped file cannot be read, and is sent nothing either.
func TestRemoteConnectAsksThroughTheHostAndSendsNoUnreadableBuild(t *testing.T) {
	standInSSH(t)
	client := NewClient()
	var asked atomic.Int32
	prompt := func(challenge GitAuthChallenge) {
		asked.Add(1)
		go func() {
			_, _ = client.RemoteAuthRespond(context.Background(), challenge.RequestID, answerText("s3cret"))
		}()
	}
	connection := SSHConnection{Host: "devbox", User: "dev"}
	var probe RemoteProbeResult
	var probeErr error
	finishesWithin(t, "probe", testDeadline, func() {
		probe, probeErr = client.RemoteProbe(WithGitAuthentication(testContext(t), prompt), connection)
	})
	if probeErr != nil || probe.Host == nil {
		t.Fatalf("probe = %+v, %v", probe, probeErr)
	}
	var result RemoteConnectResult
	var err error
	finishesWithin(t, "connect", testDeadline, func() {
		result, err = client.RemoteConnect(WithGitAuthentication(testContext(t), prompt), RemoteConnectRequest{
			Connection:    connection,
			Servers:       shippedTargets,
			ServerVersion: "0.0.0-test",
		})
	})
	if asked.Load() < 2 {
		t.Fatalf("asked %d times, want the probe's and the connection's password questions; connect = %+v, %v", asked.Load(), result, err)
	}
	shipped := false
	for _, build := range shippedTargets {
		shipped = shipped || build.Target == probe.Host.ServerTarget
	}
	if !shipped {
		if err != nil || result.Status != RemoteProbeUnsupportedPlatform || result.Session != nil {
			t.Fatalf("connect = %+v, %v, want unsupportedPlatform without a session", result, err)
		}
		return
	}
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Code != CodeRemoteServerInvalid || strings.Contains(coreErr.Details, "/nonexistent") {
		t.Fatalf("connect = %+v, %v, want remote_server_invalid without the path", result, err)
	}
}

// A malformed build is refused before OpenSSH starts.
func TestRemoteConnectRefusesAMalformedBuildBeforeConnecting(t *testing.T) {
	_, err := NewClient().RemoteConnect(testContext(t), RemoteConnectRequest{
		Connection:    SSHConnection{Host: "devbox"},
		Servers:       []RemoteServerBuild{{Target: "x86_64-unknown-linux-musl", Path: "/nonexistent", SHA256: "not-hex"}},
		ServerVersion: "0.0.0-test",
	})
	var coreErr *Error
	if !errors.As(err, &coreErr) || coreErr.Code != CodeInvalidRequest {
		t.Fatalf("connect = %v, want invalid_request", err)
	}
}
