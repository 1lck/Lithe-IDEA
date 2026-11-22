package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteserver"
)

// The acceptance tests below run only against a real host the environment names, with the server
// builds build-remote-server.sh staged (scripts/desktop/desktop-go.sh exports their directory):
//
//	LITHE_TEST_REMOTE_SSH_HOST    an SSH host or ~/.ssh/config alias that accepts a key without asking;
//	LITHE_TEST_REMOTE_SSH_PORT    its port, LITHE_TEST_REMOTE_SSH_USER its user and
//	LITHE_TEST_REMOTE_SSH_KEY     a private key file, each optional;
//	LITHE_TEST_REMOTE_WSL_DISTRO  on Windows, an installed WSL distribution, and
//	LITHE_TEST_REMOTE_WSL_USER    optionally its user.
//
// Without them the tests skip, so CI never reaches a host. They never print the host, the user,
// the distribution or a path: a failure names the step and what was counted.

// remoteAcceptanceDeadline bounds each step against a real host, which may first upload a build.
const remoteAcceptanceDeadline = 90 * time.Second

// remoteAcceptanceHost is a host the environment names: how to connect to it and the name of the
// process, a child of this one, that carries the connection.
type remoteAcceptanceHost struct {
	name      string
	request   func(servers remoteserver.Bundle) RemoteConnectRequest
	transport string
}

// remoteAcceptanceHosts returns the hosts the environment names, skipping the test when it names
// none or has no staged server builds.
func remoteAcceptanceHosts(t *testing.T) ([]remoteAcceptanceHost, remoteserver.Bundle) {
	t.Helper()
	var hosts []remoteAcceptanceHost
	if host := os.Getenv("LITHE_TEST_REMOTE_SSH_HOST"); host != "" {
		connection := SSHConnection{Host: host, User: os.Getenv("LITHE_TEST_REMOTE_SSH_USER"), ConnectTimeoutSeconds: 15}
		if port := os.Getenv("LITHE_TEST_REMOTE_SSH_PORT"); port != "" {
			parsed, err := strconv.ParseUint(port, 10, 16)
			if err != nil {
				t.Fatalf("LITHE_TEST_REMOTE_SSH_PORT is not a port")
			}
			connection.Port = uint16(parsed)
		}
		if key := os.Getenv("LITHE_TEST_REMOTE_SSH_KEY"); key != "" {
			connection.Authentication, connection.IdentityFile = RemoteAuthenticationPrivateKey, key
		}
		transport := "ssh"
		if runtime.GOOS == "windows" {
			transport = "ssh.exe"
		}
		hosts = append(hosts, remoteAcceptanceHost{name: "ssh", transport: transport, request: func(servers remoteserver.Bundle) RemoteConnectRequest {
			return RemoteConnectRequest{Connection: connection, Servers: serverBuilds(servers), ServerVersion: servers.Version}
		}})
	}
	if distribution := os.Getenv("LITHE_TEST_REMOTE_WSL_DISTRO"); distribution != "" && runtime.GOOS == "windows" {
		wsl := WSLConnection{Distribution: distribution, User: os.Getenv("LITHE_TEST_REMOTE_WSL_USER")}
		hosts = append(hosts, remoteAcceptanceHost{name: "wsl", transport: "wsl.exe", request: func(servers remoteserver.Bundle) RemoteConnectRequest {
			return RemoteConnectRequest{WSL: &wsl, Servers: serverBuilds(servers), ServerVersion: servers.Version}
		}})
	}
	if len(hosts) == 0 {
		t.Skip("no LITHE_TEST_REMOTE_SSH_HOST or, on Windows, LITHE_TEST_REMOTE_WSL_DISTRO names a host")
	}
	stage := os.Getenv(remoteserver.StageEnv)
	if stage == "" {
		t.Skip(remoteserver.StageEnv + " names no staged server builds; run through scripts/desktop/desktop-go.sh")
	}
	servers, err := remoteserver.Staged(stage)
	if err != nil {
		t.Fatalf("read the staged server builds: mismatch = %v", errors.Is(err, remoteserver.ErrMismatch))
	}
	return hosts, servers
}

// serverBuilds is the bundle as remote.connect takes it.
func serverBuilds(bundle remoteserver.Bundle) []RemoteServerBuild {
	builds := make([]RemoteServerBuild, len(bundle.Builds))
	for i, build := range bundle.Builds {
		builds[i] = RemoteServerBuild{Target: build.Target, Path: build.Path, SHA256: build.SHA256}
	}
	return builds
}

// remoteAcceptanceContext is a context bounded by remoteAcceptanceDeadline and released with the
// test.
func remoteAcceptanceContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), remoteAcceptanceDeadline)
	t.Cleanup(cancel)
	return ctx
}

// connectAcceptanceHost opens a session to host, attaching to the host session resume names when
// it is set, and fails the test unless it connected.
func connectAcceptanceHost(t *testing.T, client *Client, host remoteAcceptanceHost, servers remoteserver.Bundle, resume *RemoteResume) RemoteSession {
	t.Helper()
	request := host.request(servers)
	request.Resume = resume
	var result RemoteConnectResult
	var err error
	finishesWithin(t, "connect", remoteAcceptanceDeadline, func() {
		result, err = client.RemoteConnect(remoteAcceptanceContext(t), request)
	})
	if err != nil {
		var coreErr *Error
		code := ""
		if errors.As(err, &coreErr) {
			code = string(coreErr.Code)
		}
		t.Fatalf("connect failed with code %q", code)
	}
	if result.Status != RemoteProbeConnected || result.Session == nil {
		t.Fatalf("connect status = %q, session = %v", result.Status, result.Session != nil)
	}
	return *result.Session
}

// remoteOutput collects what a host process writes and wakes whoever waits for a line.
type remoteOutput struct {
	mu       sync.Mutex
	text     bytes.Buffer
	changed  chan struct{}
	attached chan bool
}

func newRemoteOutput() *remoteOutput {
	return &remoteOutput{changed: make(chan struct{}, 1), attached: make(chan bool, 1)}
}

func (o *remoteOutput) events(started chan<- uint64) RemoteProcessEvents {
	return RemoteProcessEvents{
		Started: func(processID uint64, _ int) {
			if started != nil {
				started <- processID
			}
		},
		Attached: func(truncated bool) { o.attached <- truncated },
		Output: func(_ string, data []byte) {
			o.mu.Lock()
			o.text.Write(data)
			o.mu.Unlock()
			select {
			case o.changed <- struct{}{}:
			default:
			}
		},
	}
}

func (o *remoteOutput) has(line string) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	return strings.Contains(o.text.String(), line+"\n")
}

// waitFor waits, at most remoteAcceptanceDeadline, until the process has written line.
func (o *remoteOutput) waitFor(t *testing.T, line string) {
	t.Helper()
	timer := time.NewTimer(remoteAcceptanceDeadline)
	defer timer.Stop()
	for !o.has(line) {
		select {
		case <-o.changed:
		case <-timer.C:
			t.Fatalf("the process did not write %q within %s", line, remoteAcceptanceDeadline)
		}
	}
}

// remoteAcceptanceScript writes "ready", waits for the file $1.during and writes "during", waits
// for $1.after and writes "after", then exits 0. It gives up after a minute with status 3, so a
// failed test leaves nothing running on the host.
const remoteAcceptanceScript = `echo ready
n=0
while [ ! -e "$1.during" ]; do n=$((n+1)); [ $n -gt 600 ] && exit 3; sleep 0.1; done
echo during
while [ ! -e "$1.after" ]; do n=$((n+1)); [ $n -gt 1200 ] && exit 3; sleep 0.1; done
echo after
rm -f "$1.during" "$1.after"`

// touchOnHost creates path on the host through session.
func touchOnHost(t *testing.T, client *Client, session, path string) {
	t.Helper()
	exit, err := client.RemoteRunProcess(remoteAcceptanceContext(t), session, RemoteProcessOpen{Argv: []string{"touch", path}}, RemoteProcessEvents{})
	if err != nil || exit.ExitCode == nil || *exit.ExitCode != 0 {
		t.Fatalf("touch on the host: err = %v, exited = %v", err != nil, exit.ExitCode != nil)
	}
}

// startAcceptanceProcess starts remoteAcceptanceScript on the host and waits for "ready". The
// returned channel receives how the run ended.
func startAcceptanceProcess(t *testing.T, client *Client, session, flag string) (uint64, *remoteOutput, <-chan error) {
	t.Helper()
	output := newRemoteOutput()
	started := make(chan uint64, 1)
	ended := make(chan error, 1)
	ctx := remoteAcceptanceContext(t)
	go func() {
		_, err := client.RemoteRunProcess(ctx, session, RemoteProcessOpen{
			Argv: []string{"sh", "-c", remoteAcceptanceScript, "sh", flag},
		}, output.events(started))
		ended <- err
	}()
	var processID uint64
	timer := time.NewTimer(remoteAcceptanceDeadline)
	defer timer.Stop()
	select {
	case processID = <-started:
	case err := <-ended:
		t.Fatalf("the process ended before it started: %v", err != nil)
	case <-timer.C:
		t.Fatalf("the process did not start within %s", remoteAcceptanceDeadline)
	}
	output.waitFor(t, "ready")
	return processID, output, ended
}

// waitEnded waits, at most remoteAcceptanceDeadline, for a run started by startAcceptanceProcess
// to end and returns its error code.
func waitEnded(t *testing.T, ended <-chan error) ErrorCode {
	t.Helper()
	timer := time.NewTimer(remoteAcceptanceDeadline)
	defer timer.Stop()
	select {
	case err := <-ended:
		var coreErr *Error
		if errors.As(err, &coreErr) {
			return coreErr.Code
		}
		if err != nil {
			return "unexpected"
		}
		return ""
	case <-timer.C:
		t.Fatalf("the run did not end within %s", remoteAcceptanceDeadline)
		return ""
	}
}

// attachAndFinish attaches to processID through session, checks that what the process wrote while
// nobody received it arrives first, lets it write once more and checks that it exits 0.
func attachAndFinish(t *testing.T, client *Client, session string, processID uint64, flag string) {
	t.Helper()
	touchOnHost(t, client, session, flag+".during")
	output := newRemoteOutput()
	type outcome struct {
		exit RemoteProcessExit
		err  error
	}
	done := make(chan outcome, 1)
	ctx := remoteAcceptanceContext(t)
	go func() {
		exit, err := client.RemoteAttachProcess(ctx, session, processID, output.events(nil))
		done <- outcome{exit, err}
	}()
	timer := time.NewTimer(remoteAcceptanceDeadline)
	defer timer.Stop()
	select {
	case truncated := <-output.attached:
		if truncated {
			t.Fatalf("attach said output is missing")
		}
	case result := <-done:
		var coreErr *Error
		code := ""
		if errors.As(result.err, &coreErr) {
			code = string(coreErr.Code)
		}
		t.Fatalf("attach ended before it attached, code %q", code)
	case <-timer.C:
		t.Fatalf("attach did not attach within %s", remoteAcceptanceDeadline)
	}
	output.waitFor(t, "during")
	touchOnHost(t, client, session, flag+".after")
	output.waitFor(t, "after")
	select {
	case result := <-done:
		if result.err != nil || result.exit.ExitCode == nil || *result.exit.ExitCode != 0 {
			t.Fatalf("attached run: err = %v, exited = %v", result.err != nil, result.exit.ExitCode != nil)
		}
	case <-timer.C:
		t.Fatalf("the attached run did not end within %s", remoteAcceptanceDeadline)
	}
}

// dropTransport kills the child processes of this one named name, as a lost network or a closed
// laptop lid would end the connection, and returns how many it killed.
func dropTransport(t *testing.T, name string) int {
	t.Helper()
	pid := strconv.Itoa(os.Getpid())
	ctx := remoteAcceptanceContext(t)
	if runtime.GOOS == "windows" {
		script := fmt.Sprintf("Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq %s -and $_.Name -eq '%s' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; 'killed' }", pid, name)
		output, _ := exec.CommandContext(ctx, "powershell", "-NoProfile", "-NonInteractive", "-Command", script).Output()
		return strings.Count(string(output), "killed")
	}
	// pgrep exits 1 when nothing matches; the count says so.
	output, _ := exec.CommandContext(ctx, "pgrep", "-P", pid, "-x", name).Output()
	killed := 0
	for _, field := range strings.Fields(string(output)) {
		child, err := strconv.Atoi(field)
		if err != nil {
			continue
		}
		if process, err := os.FindProcess(child); err == nil && process.Kill() == nil {
			killed++
		}
	}
	return killed
}

// A run whose connection is lost ends with CodeConnectionClosed; the next connection resumes the
// host session, and attaching receives first what the process wrote meanwhile and then what it
// writes afterwards, until it exits. A session closed with RemoteCloseKeep resumes the same way.
func TestRemoteAcceptanceRunsSurviveALostConnectionAndAKeptClose(t *testing.T) {
	hosts, servers := remoteAcceptanceHosts(t)
	for _, host := range hosts {
		t.Run(host.name, func(t *testing.T) {
			client := NewClient()
			flag := fmt.Sprintf("/tmp/lithe-acceptance-%d", time.Now().UnixNano())

			first := connectAcceptanceHost(t, client, host, servers, nil)
			if first.Resume() == nil {
				t.Fatalf("the host issued no resume token")
			}
			processID, _, ended := startAcceptanceProcess(t, client, first.ID, flag+"-lost")
			if killed := dropTransport(t, host.transport); killed == 0 {
				t.Fatalf("no transport process to kill")
			}
			if code := waitEnded(t, ended); code != CodeConnectionClosed {
				t.Fatalf("the run of a lost connection ended with %q, want %q", code, CodeConnectionClosed)
			}
			second := connectAcceptanceHost(t, client, host, servers, first.Resume())
			if !second.Resumed {
				t.Fatalf("the reconnection did not resume the host session")
			}
			attachAndFinish(t, client, second.ID, processID, flag+"-lost")

			processID, _, ended = startAcceptanceProcess(t, client, second.ID, flag+"-kept")
			var closed RemoteDisconnectResult
			var err error
			finishesWithin(t, "disconnect", remoteAcceptanceDeadline, func() {
				closed, err = client.RemoteDisconnect(remoteAcceptanceContext(t), second.ID, RemoteCloseKeep)
			})
			if err != nil || !closed.Closed || !closed.Kept {
				t.Fatalf("keep: err = %v, closed = %v, kept = %v", err != nil, closed.Closed, closed.Kept)
			}
			if code := waitEnded(t, ended); code == "" {
				t.Fatalf("the run of a closed session ended without an error")
			}
			third := connectAcceptanceHost(t, client, host, servers, second.Resume())
			kept := 0
			for _, program := range third.KeptPrograms {
				if program.Kind == RemoteProgramProcess && program.ID == processID {
					kept++
				}
			}
			if !third.Resumed || kept != 1 {
				t.Fatalf("resumed = %v, the kept process listed %d times among %d", third.Resumed, kept, len(third.KeptPrograms))
			}
			attachAndFinish(t, client, third.ID, processID, flag+"-kept")
			finishesWithin(t, "disconnect", remoteAcceptanceDeadline, func() {
				closed, err = client.RemoteDisconnect(remoteAcceptanceContext(t), third.ID, RemoteCloseEnd)
			})
			if err != nil || !closed.Closed || closed.Kept {
				t.Fatalf("end: err = %v, closed = %v, kept = %v", err != nil, closed.Closed, closed.Kept)
			}
		})
	}
}

// A WSL distribution that is not installed is RemoteProbeUnreachable; an unknown user of an
// installed one is RemoteProbeFailed, with wsl.exe's message and its error code as the
// diagnostics. Neither opens a session.
func TestRemoteAcceptanceWSLRefusesAnAbsentDistributionAndUser(t *testing.T) {
	hosts, servers := remoteAcceptanceHosts(t)
	for _, host := range hosts {
		if host.name != "wsl" {
			continue
		}
		client := NewClient()
		for _, tc := range []struct {
			name   string
			wsl    func(WSLConnection) WSLConnection
			status RemoteProbeStatus
			code   string
		}{
			{"distribution", func(w WSLConnection) WSLConnection { w.Distribution = "lithe-absent-distribution"; return w },
				RemoteProbeUnreachable, "WSL_E_DISTRO_NOT_FOUND"},
			{"user", func(w WSLConnection) WSLConnection { w.User = "lithe-absent-user"; return w },
				RemoteProbeFailed, "WSL_E_USER_NOT_FOUND"},
		} {
			request := host.request(servers)
			wsl := tc.wsl(*request.WSL)
			request.WSL = &wsl
			var result RemoteConnectResult
			var err error
			finishesWithin(t, "connect", remoteAcceptanceDeadline, func() {
				result, err = client.RemoteConnect(remoteAcceptanceContext(t), request)
			})
			// The diagnostics name the distribution or the user, so only whether the code is there
			// is reported.
			coded := strings.Contains(result.Diagnostics, tc.code)
			if err != nil || result.Status != tc.status || result.Session != nil || !coded {
				t.Fatalf("an absent %s: err = %v, status = %q, session = %v, %s in diagnostics = %v",
					tc.name, err != nil, result.Status, result.Session != nil, tc.code, coded)
			}
		}
		return
	}
	t.Skip("no LITHE_TEST_REMOTE_WSL_DISTRO names a distribution")
}
