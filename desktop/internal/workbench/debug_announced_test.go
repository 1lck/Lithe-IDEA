package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// debugAnnouncedManifest declares an adapter process that listens on a loopback
// port it picks itself and prints on stdout, for adapters with no stdio mode.
const debugAnnouncedManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.debug-announced",
  "displayName": "Announced Debug Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"debugAdapters": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["debug.launch"],
  "activationEvents": ["onDebug:announced"],
  "languages": [],
  "debugAdapters": [{
    "id": "announced",
    "displayName": "Announced DAP",
    "adapterID": "announced-dap",
    "requests": ["launch"],
    "configurations": {"launch": {"arguments": {"stopOnEntry": true}}},
    "launch": {
      "process": {"launch": {"kind": "packaged", "path": "adapter"}, "arguments": ["-test.run=^TestDebugAnnouncedAdapterRunner$"]},
      "transport": "tcpAnnounced",
      "endpoint": {"stream": "stdout", "prefix": "DAP server listening at: ", "value": "hostPort"}
    }
  }]
}`

// announcedFixtureLifetime bounds the fixture process: one the host failed to
// stop still ends by itself, and the test that waits for its end fails first.
const announcedFixtureLifetime = 2 * time.Minute

// announcedFixture is what the workspace's announce.marker tells the runner:
// how the adapter behaves, and the test's watch address it holds a connection
// to, which closes when the process ends.
type announcedFixture struct {
	Mode  string `json:"mode"`
	Watch string `json:"watch"`
}

// TestDebugAnnouncedAdapterRunner is the fixture tcpAnnounced adapter. The host
// starts the copied test binary with the manifest's -test.run argument and the
// fixture workspace as its working directory. Its modes:
//
//   - "" listens on a free loopback port, prints a line on each stream and then
//     the announcement, serves the fixture DAP on the one connection, and tells
//     the watch connection when the host sent disconnect;
//   - "exit" prints a line and exits before announcing;
//   - "silent" prints a line and never announces;
//   - "remote" announces an address that is not on this computer.
//
// The last two stay up until the host stops them or the test closes the watch
// connection, so the watch's end shows the process ended.
func TestDebugAnnouncedAdapterRunner(t *testing.T) {
	marker, err := os.ReadFile("announce.marker")
	if err != nil {
		t.Skip("not the announced debug adapter fixture workspace")
	}
	var fixture announcedFixture
	if err := json.Unmarshal(marker, &fixture); err != nil {
		os.Exit(2)
	}
	watch, err := net.DialTimeout("tcp", fixture.Watch, 10*time.Second)
	if err != nil {
		os.Exit(2)
	}
	_ = watch.SetDeadline(time.Now().Add(announcedFixtureLifetime))
	hold := func() {
		_, _ = io.Copy(io.Discard, watch)
		os.Exit(0)
	}
	switch fixture.Mode {
	case "exit":
		fmt.Println("started without a listener")
		os.Exit(0)
	case "silent":
		fmt.Println("started")
		hold()
	case "remote":
		fmt.Println("DAP server listening at: 192.0.2.1:5678")
		hold()
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		os.Exit(3)
	}
	_ = listener.(*net.TCPListener).SetDeadline(time.Now().Add(announcedFixtureLifetime))
	fmt.Fprintln(os.Stderr, "stderr before the announcement")
	fmt.Println("stdout before the announcement")
	// A CRLF line end, as a Windows adapter may print it.
	fmt.Printf("DAP server listening at: %s\r\n", listener.Addr())
	conn, err := listener.Accept()
	_ = listener.Close()
	if err != nil {
		os.Exit(3)
	}
	_ = conn.SetDeadline(time.Now().Add(announcedFixtureLifetime))
	workspace, err := os.Getwd()
	if err != nil {
		os.Exit(2)
	}
	var requests bytes.Buffer
	code := serveFixtureAdapter(io.TeeReader(conn, &requests), conn, workspace)
	if bytes.Contains(requests.Bytes(), []byte(`"disconnect"`)) {
		fmt.Fprintln(watch, "disconnected")
		// Finish the successful report before exiting. An abrupt Windows
		// process exit can reset even this separate observation socket.
		if err := watch.Close(); err != nil {
			os.Exit(8)
		}
	}
	os.Exit(code)
}

// announcedWatch accepts the fixture process's watch connection.
type announcedWatch struct {
	listener net.Listener
	accepted chan net.Conn
	conn     net.Conn
}

// announcedWorkspace is the fixture workspace for one mode, and the watch the
// fixture process connects to.
func announcedWorkspace(t *testing.T, mode string) (root, source string, watch *announcedWatch) {
	t.Helper()
	root, source = fixtureWorkspace(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	watch = &announcedWatch{listener: listener, accepted: make(chan net.Conn, 1)}
	t.Cleanup(func() {
		_ = listener.Close()
		if watch.conn != nil {
			_ = watch.conn.Close()
		}
		select {
		case conn := <-watch.accepted:
			if conn != nil {
				_ = conn.Close()
			}
		case <-time.After(5 * time.Second):
			t.Error("the adapter watch listener did not stop after closing")
		}
	})
	go func() {
		defer close(watch.accepted)
		conn, err := listener.Accept()
		if err == nil {
			watch.accepted <- conn
		}
	}()
	marker, err := json.Marshal(announcedFixture{Mode: mode, Watch: listener.Addr().String()})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "announce.marker"), marker, 0o600); err != nil {
		t.Fatal(err)
	}
	return root, source, watch
}

// awaitConnected waits for the fixture process to connect to the watch so tests
// can synchronize deterministically with the running child before triggering
// timeouts.
func (w *announcedWatch) awaitConnected(t *testing.T, limit time.Duration) {
	t.Helper()
	if w.conn != nil {
		return
	}
	select {
	case conn := <-w.accepted:
		if conn == nil {
			t.Fatal("the adapter watch listener stopped before accepting the connection")
		}
		w.conn = conn
	case <-time.After(limit):
		t.Fatal("the adapter process never connected to the watch")
	}
}

// ended waits for the fixture process to end and returns what it reported
// before it did.
func (w *announcedWatch) ended(t *testing.T, limit time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(limit)
	w.awaitConnected(t, limit)
	conn := w.conn
	w.conn = nil
	defer conn.Close()
	if err := conn.SetReadDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	reported, err := io.ReadAll(conn)
	// The fixture owns the peer socket until exit. Terminating it can reset
	// the loopback connection instead of returning EOF. Winsock uses 10054.
	const wsaConnectionReset = syscall.Errno(10054)
	if err != nil && !errors.Is(err, syscall.ECONNRESET) && !errors.Is(err, wsaConnectionReset) {
		t.Fatalf("the adapter process still runs after %v (read: %v)", limit, err)
	}
	return string(reported)
}

func TestDebugAnnouncedAdapterBreakpointPauseContinueStop(t *testing.T) {
	previous := buildprocess.StopGrace()
	t.Cleanup(func() { buildprocess.SetStopGrace(previous) })
	h := debugPluginHarness(t, "dev.lithe.test.debug-announced", debugAnnouncedManifest, true)
	// The harness does not run App.Run, which normally loads Core's stop time.
	h.app.refreshStopGrace()
	root, source, watch := announcedWorkspace(t, "")
	p := openHostedPanel(t, h, root)
	if declaration := p.debug.adapters[0].Declaration; declaration.Transport != "tcpAnnounced" || declaration.LaunchKind != "packaged" {
		t.Fatalf("declaration = %+v, want the announced adapter's process", declaration)
	}
	h.app.openFileAtPosition(p, source, 2, 0)
	h.settle()
	toggleBreakpointInDialog(h)

	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 30*time.Second, "the paused announced session and its output", func() bool {
		if p.debug.failure != "" {
			t.Fatalf("debug start failed: %s", p.debug.failure)
		}
		output := strings.Join(p.debug.output, "\n")
		return p.debug.state == "paused" && len(p.debug.frames) == 2 &&
			strings.Contains(output, "stdout before the announcement") && strings.Contains(output, "stderr before the announcement")
	})
	// The announcement is the host's reading, not the adapter's console output.
	if output := strings.Join(p.debug.output, "\n"); strings.Contains(output, "DAP server listening at") {
		t.Fatalf("the console shows the announcement: %q", output)
	}

	h.clickNamed(h.app.text.Debug.Continue)
	awaitStateWithin(t, h, 20*time.Second, "the continued session", func() bool {
		return p.debug.state == "running" && len(p.debug.frames) == 0
	})
	h.clickNamed(h.app.text.Debug.Pause)
	awaitStateWithin(t, h, 20*time.Second, "the paused session", func() bool {
		return p.debug.state == "paused" && len(p.debug.frames) == 2
	})
	awaitStateWithin(t, h, 20*time.Second, "Core's effective exit grace", func() bool {
		return h.app.stopTime.Load() != nil && buildprocess.StopGrace() > 0
	})

	stoppedSession := p.debug.activeSession()
	h.clickNamed(h.app.text.Debug.Stop)
	awaitStateWithin(t, h, 20*time.Second, "the stopped session", func() bool {
		if p.debug.activeSession() != nil || p.debug.state != "idle" {
			return false
		}
		select {
		case <-stoppedSession.cleanupDone:
			return true
		default:
			return false
		}
	})
	// The process outlives the session's context, so the disconnect reaches it
	// before it is stopped.
	if reported := watch.ended(t, 20*time.Second); !strings.Contains(reported, "disconnected") {
		t.Fatalf("the adapter process ended without its disconnect (reported %q)", reported)
	}
}

func TestDebugAnnouncedAdapterThatExitsFirstFailsWithAMessage(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-announced", debugAnnouncedManifest, true)
	root, _, watch := announcedWorkspace(t, "exit")
	p := openHostedPanel(t, h, root)
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 20*time.Second, "the failure", func() bool { return p.debug.failure != "" })
	if p.debug.failure != h.app.text.Debug.NotAnnounced || p.debug.activeSession() != nil {
		t.Fatalf("failure = %q, session = %v; want the missing announcement", p.debug.failure, p.debug.activeSession())
	}
	watch.ended(t, 20*time.Second)
}

func TestDebugAnnouncedRemoteEndpointFailsAndStopsTheProcess(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-announced", debugAnnouncedManifest, true)
	root, _, watch := announcedWorkspace(t, "remote")
	p := openHostedPanel(t, h, root)
	h.clickNamed(h.app.text.Debug.Start)
	awaitStateWithin(t, h, 20*time.Second, "the failure", func() bool { return p.debug.failure != "" })
	if p.debug.failure != h.app.text.Debug.InvalidEndpoint || p.debug.activeSession() != nil {
		t.Fatalf("failure = %q, session = %v; want the refused endpoint", p.debug.failure, p.debug.activeSession())
	}
	watch.ended(t, 20*time.Second)
}

func TestDebugAnnouncedAdapterThatNeverAnnouncesTimesOut(t *testing.T) {
	h := debugPluginHarness(t, "dev.lithe.test.debug-announced", debugAnnouncedManifest, true)
	root, _, watch := announcedWorkspace(t, "silent")
	// Control the initialize timeout deterministically so child startup never
	// races the timeout clock.
	trigger := make(chan struct{})
	t.Cleanup(func() {
		select {
		case <-trigger:
		default:
			close(trigger)
		}
	})
	h.app.debugInitializeTrigger = trigger
	p := openHostedPanel(t, h, root)
	h.clickNamed(h.app.text.Debug.Start)
	session := p.debug.activeSession()
	if session == nil {
		t.Fatal("the announced adapter never entered its startup session")
	}
	watch.awaitConnected(t, 20*time.Second)
	close(trigger)
	awaitStateWithin(t, h, 20*time.Second, "the timeout", func() bool { return p.debug.failure != "" })
	if p.debug.failure != h.app.text.Debug.TimedOut || p.debug.activeSession() != nil {
		t.Fatalf("failure = %q, want the timeout message", p.debug.failure)
	}
	watch.ended(t, 20*time.Second)
	awaitDebugSessionDone(t, session)
	select {
	case <-session.cleanupDone:
	case <-time.After(debugAdapterExitWait):
		t.Fatal("the timed-out debug session did not finish cleanup before the deadline")
	}
}

// announcementRecorder is a reader whose Core answer is a fixed rule: a line
// "announce <port>" announces 127.0.0.1, "remote" is refused, and "broken" is a
// failed reading. Callers run on one goroutine, so it needs no lock.
type announcementRecorder struct {
	lines   []string
	console []string
}

var errBrokenReading = errors.New("broken reading")

func (r *announcementRecorder) reader() *debugAnnouncementReader {
	return newDebugAnnouncementReader(func(stream, line string) (core.DebugAnnouncement, error) {
		r.lines = append(r.lines, stream+":"+line)
		var port int
		switch {
		case line == "remote":
			return core.DebugAnnouncement{Status: "invalid", Reason: "notLoopback"}, nil
		case line == "broken":
			return core.DebugAnnouncement{}, errBrokenReading
		case stream == "stdout":
			if _, err := fmt.Sscanf(line, "announce %d", &port); err == nil {
				return core.DebugAnnouncement{Status: "announced", Host: "127.0.0.1", Port: port}, nil
			}
		}
		return core.DebugAnnouncement{Status: "none"}, nil
	}, func(text string) { r.console = append(r.console, text) }, errors.New("refused endpoint"))
}

// decided returns the endpoint the observed output decided. observe decides
// synchronously, so the result is either there already or missing.
func decided(t *testing.T, reader *debugAnnouncementReader) (string, int, error) {
	t.Helper()
	select {
	case endpoint := <-reader.found:
		return endpoint.host, endpoint.port, endpoint.err
	default:
		t.Fatal("no line decided the endpoint")
		return "", 0, nil
	}
}

func TestDebugAnnouncementReaderJoinsChunksAndHidesTheAnnouncement(t *testing.T) {
	recorder := &announcementRecorder{}
	reader := recorder.reader()
	reader.observe(buildprocess.Stream("stdout"), "building\nannou")
	reader.observe(buildprocess.Stream("stdout"), "nce 4711\r\nafter\npartial")
	host, port, err := decided(t, reader)
	if host != "127.0.0.1" || port != 4711 || err != nil {
		t.Fatalf("endpoint = %s:%d, %v", host, port, err)
	}
	if want := []string{"stdout:building", "stdout:announce 4711"}; strings.Join(recorder.lines, "|") != strings.Join(want, "|") {
		t.Fatalf("read lines = %q, want %q", recorder.lines, want)
	}
	// Output after the announcement is the console's as it arrives, unread.
	reader.observe(buildprocess.Stream("stdout"), " line\nannounce 9\n")
	if got := strings.Join(recorder.console, ""); got != "building\nafter\npartial line\nannounce 9\n" {
		t.Fatalf("console = %q", got)
	}
	if len(recorder.lines) != 2 {
		t.Fatalf("lines after the announcement were read: %q", recorder.lines)
	}
}

func TestDebugAnnouncementReaderKeepsEachStreamsLineApart(t *testing.T) {
	recorder := &announcementRecorder{}
	reader := recorder.reader()
	reader.observe(buildprocess.Stream("stderr"), "warning: ")
	reader.observe(buildprocess.Stream("stdout"), "announce ")
	reader.observe(buildprocess.Stream("stderr"), "slow disk\nannounce 1\n")
	select {
	case <-reader.found:
		t.Fatal("a stderr line decided the endpoint")
	default:
	}
	reader.observe(buildprocess.Stream("stdout"), "4712\n")
	if _, port, err := decided(t, reader); port != 4712 || err != nil {
		t.Fatalf("port = %d, %v", port, err)
	}
	if got := strings.Join(recorder.console, ""); got != "warning: slow disk\nannounce 1\n" {
		t.Fatalf("console = %q", got)
	}
}

func TestDebugAnnouncementReaderShowsUnfinishedOutputOnceDecided(t *testing.T) {
	recorder := &announcementRecorder{}
	reader := recorder.reader()
	reader.observe(buildprocess.Stream("stderr"), "progress 50%")
	reader.observe(buildprocess.Stream("stdout"), "announce 4713\n")
	decided(t, reader)
	if got := strings.Join(recorder.console, ""); got != "progress 50%" {
		t.Fatalf("console = %q, want the other stream's unfinished line", got)
	}
}

func TestDebugAnnouncementReaderPassesAnOverlongLineUnread(t *testing.T) {
	recorder := &announcementRecorder{}
	reader := recorder.reader()
	long := strings.Repeat("x", debugAnnouncementLineLimit+1)
	reader.observe(buildprocess.Stream("stdout"), long)
	reader.observe(buildprocess.Stream("stdout"), "announce 1 tail\nannounce 4714\n")
	if _, port, err := decided(t, reader); port != 4714 || err != nil {
		t.Fatalf("port = %d, %v", port, err)
	}
	if len(recorder.lines) != 1 || recorder.lines[0] != "stdout:announce 4714" {
		t.Fatalf("read lines = %q, want only the line after the overlong one", recorder.lines)
	}
	if got := strings.Join(recorder.console, ""); got != long+"announce 1 tail\n" {
		t.Fatalf("console shows %d bytes, want the overlong line whole", len(got))
	}
}

func TestDebugAnnouncementReaderRefusalAndFailedReadingEndTheWait(t *testing.T) {
	for _, test := range []struct {
		line string
		want string
	}{
		{line: "remote", want: "refused endpoint"},
		{line: "broken", want: errBrokenReading.Error()},
	} {
		recorder := &announcementRecorder{}
		reader := recorder.reader()
		reader.observe(buildprocess.Stream("stdout"), test.line+"\nannounce 4715\n")
		if _, _, err := decided(t, reader); err == nil || err.Error() != test.want {
			t.Fatalf("%s: err = %v, want %q", test.line, err, test.want)
		}
		// The refused line stays visible, and what follows is the console's.
		if got := strings.Join(recorder.console, ""); got != test.line+"\nannounce 4715\n" {
			t.Fatalf("%s: console = %q", test.line, got)
		}
	}
}

func TestDebugAnnouncementReaderWaitEndsWithItsContext(t *testing.T) {
	reader := (&announcementRecorder{}).reader()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := reader.wait(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("wait = %v, want cancellation", err)
	}
}
