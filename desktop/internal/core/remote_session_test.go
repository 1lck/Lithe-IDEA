package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// shippedTargets are the server builds the application ships; the paths do not exist, so a host
// that has a build reads none and Core sends nothing.
var shippedTargets = []RemoteServerBuild{
	{Target: "x86_64-unknown-linux-musl", Path: "/nonexistent/lithe-remote-server-x86_64", SHA256: strings.Repeat("a", 64)},
	{Target: "aarch64-unknown-linux-musl", Path: "/nonexistent/lithe-remote-server-aarch64", SHA256: strings.Repeat("b", 64)},
}

// A session without verified target evidence cannot be kept for automatic recovery.
func TestRemoteResumeRequiresAndPreservesTheVerifiedBinding(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("remote/session-binding-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Session RemoteSession `json:"session"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	session := fixture.Session
	if !session.ResumeConsumed || !session.Resumed || session.SessionBinding == "" || session.SessionToken == nil {
		t.Fatal("verified session contract fields were not decoded")
	}
	binding := session.SessionBinding
	session.SessionBinding = ""
	if session.Resume() != nil {
		t.Fatal("a session without verified evidence was offered for recovery")
	}
	session.SessionBinding = binding
	resume := session.Resume()
	if resume == nil || resume.Binding != session.SessionBinding || resume.Key != session.SessionKey || resume.Token != *session.SessionToken {
		t.Fatal("verified recovery fields were not preserved")
	}
	encoded, err := json.Marshal(resume)
	if err != nil {
		t.Fatal(err)
	}
	var decoded RemoteResume
	if err := json.Unmarshal(encoded, &decoded); err != nil || decoded != *resume {
		t.Fatal("verified recovery fields did not round-trip")
	}
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
	for _, programs := range []RemoteClosePrograms{RemoteCloseEnd, RemoteCloseKeep, RemoteCloseAsk} {
		result, err := client.RemoteDisconnect(ctx, "no-such-session", programs)
		if err != nil || result.Closed || result.Kept {
			t.Fatalf("disconnect %s = %+v, %v, want nothing closed or kept", programs, result, err)
		}
	}
	var coreErr *Error
	if programs, err := client.RemoteRunningPrograms(ctx, "no-such-session"); programs == nil || len(programs) != 0 || !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("runningPrograms = %d, %v, want an empty list and connection_closed", len(programs), err)
	}
	if ended, err := client.RemoteEndPrograms(ctx, "no-such-session", nil); ended != 0 || !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("endPrograms = %d, %v, want connection_closed", ended, err)
	}
	if _, err := client.RemoteReadDir(ctx, "no-such-session", "/"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("readDir = %v, want connection_closed", err)
	}
	if err := client.RemoteServerState(ctx, "no-such-session"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("server.state = %v, want connection_closed", err)
	}
	if _, err := client.RemoteStat(ctx, "no-such-session", "/srv/repo/README.md"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("fs.stat = %v, want connection_closed", err)
	}
	if _, _, err := client.RemoteReadFile(ctx, "no-such-session", "/srv/repo/README.md"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("readFile = %v, want connection_closed", err)
	}
	modified := int64(1)
	if _, saved, err := client.RemoteWriteFile(ctx, "no-such-session", "/srv/repo/README.md", []byte("text"), &RemoteFileVersion{Size: 4, ModifiedMs: &modified}); saved || !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("writeFile = %v, %v, want connection_closed", saved, err)
	}
	if _, created, err := client.RemoteStartForward(ctx, "no-such-session", RemoteForwardTarget{Host: "127.0.0.1", Port: 8080}); created || !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("startForward = %v, %v, want connection_closed", created, err)
	}
	if stopped, err := client.RemoteStopForward(ctx, "no-such-session", 1); stopped || !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("stopForward = %v, %v, want connection_closed", stopped, err)
	}
	if _, err := client.RemoteForwards(ctx, "no-such-session"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("forwards = %v, want connection_closed", err)
	}
	if _, err := client.RemoteListeningPorts(ctx, "no-such-session"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("ports.listening = %v, want connection_closed", err)
	}
	if _, err := client.RemotePortRecords(ctx, nil, "no-such-session", "/srv/repo"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("portRecords = %v, want connection_closed", err)
	}
	label := RemotePortRecordEdit{Port: &RemotePortRecord{Port: 8080, Label: "web"}}
	if changed, updated, _, err := client.EditRemotePortRecords(ctx, nil, "no-such-session", "/srv/repo", label); changed || updated != nil || !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("editPortRecords = %v, %v, %v, want connection_closed", changed, updated != nil, err)
	}
	if restored, err := client.RestoreRemoteForwards(ctx, nil, "no-such-session", "/srv/repo"); restored != nil || !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("restoreForwards = %d, %v, want connection_closed", len(restored), err)
	}
}

// A context without its remote workspace sends requests that compute from their payload as
// local ones, and leaves a local context as it was.
// A payload-only command of a remote workspace goes as a local request, connected or not, so
// typing and decoding keep working while the host is away; a command that reads the workspace
// still needs the session.
func TestPayloadOnlyCommandsSendNoRemoteWorkspace(t *testing.T) {
	binding := NewRemoteWorkspace("/cache/remote/1/abc/repo", "/srv/repo", nil)
	ctx := WithRemoteWorkspace(context.Background(), binding)
	for _, attached := range []bool{false, true} {
		if attached {
			binding.Attach("session-7")
		}
		for command := range payloadOnlyCommands {
			if wire, owner, session, err := remoteWorkspaceRequest(ctx, command); wire != nil || owner != nil || session != nil || err != nil {
				t.Fatalf("%s (attached %v) = %+v, %v, %v, %v, want a local request", command, attached, wire, owner, session, err)
			}
		}
	}
	if wire, _, _, err := remoteWorkspaceRequest(ctx, "file.read"); wire == nil || err != nil {
		t.Fatalf("file.read = %+v, %v, want the binding", wire, err)
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
		probe, probeErr = client.RemoteProbe(WithGitAuthentication(testContext(t), prompt), connection, nil)
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

// A WSL connection is sent as the wsl field alone, and Core refuses one it cannot run by the field
// it names before wsl.exe starts: so do a request naming both a host and a distribution and one
// naming neither.
func TestRemoteConnectSendsWSLAloneAndCoreRefusesItByField(t *testing.T) {
	wire, err := json.Marshal(RemoteConnectRequest{WSL: &WSLConnection{Distribution: "Ubuntu"}, Servers: []RemoteServerBuild{}})
	if err != nil || strings.Contains(string(wire), `"connection"`) || !strings.Contains(string(wire), `"wsl":{"distribution":"Ubuntu"}`) {
		t.Fatalf("request = %s, %v, want the wsl field without a connection", wire, err)
	}
	if identity := (WSLConnection{Distribution: " Debian ", User: " dev "}).Identity(); identity != "wsl:dev@Debian" {
		t.Fatalf("identity = %q", identity)
	}
	client := NewClient()
	for _, tc := range []struct {
		request       RemoteConnectRequest
		field, reason string
	}{
		{RemoteConnectRequest{WSL: &WSLConnection{Distribution: " "}}, "distribution", "required"},
		{RemoteConnectRequest{WSL: &WSLConnection{Distribution: "-d"}}, "distribution", "invalid"},
		{RemoteConnectRequest{WSL: &WSLConnection{Distribution: "Ubuntu", User: "a b"}}, "user", "invalid"},
		{RemoteConnectRequest{Connection: SSHConnection{Host: "devbox"}, WSL: &WSLConnection{Distribution: "Ubuntu"}}, "wsl", "invalid"},
		{RemoteConnectRequest{}, "connection", "required"},
	} {
		tc.request.Servers, tc.request.ServerVersion = shippedTargets, "0.0.0-test"
		_, err := client.RemoteConnect(testContext(t), tc.request)
		if field, reason, ok := RemoteConnectionFieldError(err); !ok || field != tc.field || reason != tc.reason {
			t.Fatalf("connect refused %q %q (%v), want %q %q", field, reason, ok, tc.field, tc.reason)
		}
	}
}

// Outside Windows there is no WSL: the listing says so without running anything.
func TestRemoteListWSLDistributionsIsUnavailableOutsideWindows(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows lists the machine's own distributions")
	}
	listed, err := NewClient().RemoteListWSLDistributions(testContext(t))
	if err != nil || listed.Available || listed.Distributions == nil || len(listed.Distributions) != 0 || listed.Diagnostics != "" {
		t.Fatalf("listing = %+v, %v, want unavailable with an empty list", listed, err)
	}
}

// A container is sent as the container field alone, and Core refuses a malformed one by the field
// it names before the engine starts.
func TestRemoteConnectSendsAContainerAloneAndCoreRefusesItByField(t *testing.T) {
	container := &ContainerConnection{Engine: ContainerEnginePodman, Container: "web"}
	wire, err := json.Marshal(RemoteConnectRequest{Container: container, Servers: []RemoteServerBuild{}})
	if err != nil || strings.Contains(string(wire), `"connection"`) || !strings.Contains(string(wire), `"container":{"engine":"podman","container":"web"}`) {
		t.Fatalf("request = %s, %v, want the container field without a connection", wire, err)
	}
	if identity := (ContainerConnection{Engine: ContainerEngineDocker, Container: " web ", User: " dev "}).Identity(); identity != "docker:dev@web" {
		t.Fatalf("identity = %q", identity)
	}
	client := NewClient()
	for _, tc := range []struct {
		container     ContainerConnection
		field, reason string
	}{
		{ContainerConnection{Engine: ContainerEngineDocker, Container: " "}, "container", "required"},
		{ContainerConnection{Engine: ContainerEngineDocker, Container: "-web"}, "container", "invalid"},
		{ContainerConnection{Engine: ContainerEngineDocker, Container: "web", User: "root;id"}, "user", "invalid"},
	} {
		request := RemoteConnectRequest{Container: &tc.container, Servers: shippedTargets, ServerVersion: "0.0.0-test"}
		_, err := client.RemoteConnect(testContext(t), request)
		if field, reason, ok := RemoteConnectionFieldError(err); !ok || field != tc.field || reason != tc.reason {
			t.Fatalf("connect refused %q %q (%v), want %q %q", field, reason, ok, tc.field, tc.reason)
		}
	}
}

// Listing over a session that is not open is CodeConnectionClosed, and an engine Core does not
// know is refused before anything runs; neither depends on what this machine has installed.
func TestRemoteListContainersNamesTheSessionAndTheEngine(t *testing.T) {
	client := NewClient()
	var coreErr *Error
	if _, err := client.RemoteListContainers(testContext(t), ContainerEngineDocker, "absent"); !errors.As(err, &coreErr) || coreErr.Code != CodeConnectionClosed {
		t.Fatalf("listing over an absent session = %v, want connection_closed", err)
	}
	if _, err := client.RemoteListContainers(testContext(t), "nerdctl", ""); !errors.As(err, &coreErr) || coreErr.Code != CodeInvalidRequest {
		t.Fatalf("listing with an unknown engine = %v, want invalid_request", err)
	}
}
