package workbench

import (
	"context"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteserver"
)

// The host the tests connect to: its account's home directory and the folders below it.
const (
	remoteTestHost = "build.example"
	remoteTestHome = "/home/dev"
)

// remoteTestFolders are the host's folders the folder browser lists.
var remoteTestFolders = map[string][]core.RemoteDirectoryEntry{
	remoteTestHome: {
		{Name: ".cache", Metadata: core.RemoteFileMetadata{Kind: core.RemoteFileKindDirectory}},
		{Name: "linked", Metadata: core.RemoteFileMetadata{Kind: core.RemoteFileKindSymlink, SymlinkTargetKind: core.RemoteFileKindDirectory}},
		{Name: "notes.txt", Metadata: core.RemoteFileMetadata{Kind: core.RemoteFileKindFile}},
		{Name: "project", Metadata: core.RemoteFileMetadata{Kind: core.RemoteFileKindDirectory}},
	},
	remoteTestHome + "/project": {
		{Name: "README.md", Metadata: core.RemoteFileMetadata{Kind: core.RemoteFileKindFile}},
		{Name: "src", Metadata: core.RemoteFileMetadata{Kind: core.RemoteFileKindDirectory}},
	},
}

// remoteHostKernel stands in for a host over SSH: it opens numbered sessions, lists
// remoteTestFolders, answers heartbeats as the test says, lists the workspace's tree only for a
// request that carries the workspace's session, keeps the files of files
// (remote_documents_test.go), watches the workspace's folder (remote_watch_test.go), searches
// it (remote_search_test.go) and forwards the host's ports (remote_ports_test.go). Everything else
// is the real Core.
type remoteHostKernel struct {
	*testKernel
	mu sync.Mutex
	// refuse is the status the next connections end with; "" connects.
	refuse core.RemoteProbeStatus
	// state is the heartbeat's answer; once, when set, is the next heartbeat's alone.
	state    error
	once     error
	connects int
	servers  [][]core.RemoteServerBuild
	beats    int
	closed   []string
	// listings are the sessions the Project tool window's listings carried, "" for none.
	listings []string
	// files are the host's files by host path, and modified the time each was last written.
	files    map[string][]byte
	modified map[string]int64
	// kinds are the host paths that are not regular files.
	kinds map[string]core.RemoteFileKind
	// fileErr fails the next request for a host file, once; writeErr fails the next write, once.
	fileErr, writeErr error
	// fileSessions are the sessions the requests for host files went over.
	fileSessions []string
	// terminals are the host's terminals (remote_terminal_test.go).
	terminals remoteHostTerminals
	// tree is the workspace's folders the Project tool window lists, by path relative to the
	// folder; nil lists remoteTestTree. missing is set while the folder is gone from the host.
	tree    map[string][]core.WorkspaceNode
	missing bool
	// watches are the host's watches of the folder (remote_watch_test.go).
	watches remoteHostWatches
	// search is Core's index of the folder and what the search's requests carried
	// (remote_search_test.go).
	search remoteHostSearch
	// git is the workspace's trust and the host's repository (remote_git_test.go).
	git remoteHostGit
	// ports are the host's listening ports and the sessions' forwards (remote_ports_test.go).
	ports remoteHostPorts
	// wsl is this computer's WSL distributions (remote_wsl_test.go).
	wsl remoteHostWSL
	// runs are the workspace's run configurations and the host's processes (remote_run_test.go).
	runs remoteHostRuns
	// containers are this computer's running containers (remote_container_test.go).
	containers remoteHostContainers
	// devcontainers is this computer's Dev Container CLI (remote_devcontainer_test.go).
	devcontainers remoteHostDevcontainers
	// close is what the host sessions run and keep (remote_close_test.go).
	close remoteHostClose
	// fsOps records host file management mutations (remote_files_test.go).
	fsOps remoteHostFileOps
}

// remoteHostClose is what the host's sessions run and keep. Each SSH session N has the key "key-N"
// and the token "token-N"; a connection that presents a kept session's key and token resumes it.
type remoteHostClose struct {
	// running are the programs the attached session runs, whichever it is; runningErr fails
	// listing them.
	running    []core.RemoteProgram
	runningErr error
	// choices are what each closed session was closed with, in closed's order.
	choices []core.RemoteClosePrograms
	// keys are the sessions' keys by session id.
	keys map[string]string
	// kept are the programs of the sessions the host keeps, by key; refuseKeep makes the host
	// close a session it was asked to keep.
	kept       map[string][]core.RemoteProgram
	refuseKeep bool
	// resumable makes the host keep every session whose connection broke, so presenting its token
	// resumes it with its programs.
	resumable bool
	// resumes are what each SSH connection presented, nil for nothing.
	resumes []*core.RemoteResume
	// ended are the programs each request to end some named.
	ended [][]core.RemoteProgram
}

// session is the SSH session numbered n, resuming the kept session resume names when it presents
// its token. It runs under the kernel's lock.
func (c *remoteHostClose) session(n int, resume *core.RemoteResume) *core.RemoteSession {
	c.resumes = append(c.resumes, resume)
	if c.keys == nil {
		c.keys = map[string]string{}
	}
	id := "session-" + strconv.Itoa(n)
	session := &core.RemoteSession{ID: id, HostName: "devbox", UserName: "dev", HomeDirectory: remoteTestHome, SessionKey: "key-" + strconv.Itoa(n), SessionBinding: strings.Repeat("b", 64)}
	session.ResumeConsumed = resume != nil && resume.Binding == session.SessionBinding
	if session.ResumeConsumed && resume.Token == "token-"+strings.TrimPrefix(resume.Key, "key-") {
		if kept, ok := c.kept[resume.Key]; ok {
			delete(c.kept, resume.Key)
			session.SessionKey, session.Resumed, session.KeptPrograms = resume.Key, true, kept
		} else if c.resumable {
			session.SessionKey, session.Resumed = resume.Key, true
		}
	}
	token := "token-" + strings.TrimPrefix(session.SessionKey, "key-")
	session.SessionToken = &token
	c.keys[id] = session.SessionKey
	return session
}

func (k *remoteHostKernel) RemoteRunningPrograms(context.Context, string) ([]core.RemoteProgram, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return slices.Clone(k.close.running), k.close.runningErr
}

func (k *remoteHostKernel) RemoteEndPrograms(_ context.Context, _ string, programs []core.RemoteProgram) (int, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.close.ended = append(k.close.ended, slices.Clone(programs))
	return len(programs), nil
}

// remoteTestTree is the workspace's tree the Project tool window lists by default.
var remoteTestTree = map[string][]core.WorkspaceNode{
	"": {
		{Path: "src", Name: "src", IsDirectory: true},
		{Path: "README.md", Name: "README.md"},
	},
}

func (k *remoteHostKernel) RemoteConnect(_ context.Context, request core.RemoteConnectRequest) (core.RemoteConnectResult, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.connects++
	k.servers = append(k.servers, request.Servers)
	if request.Container != nil {
		return k.containers.connect(k.connects, request)
	}
	if request.WSL != nil {
		return k.wsl.connect(k.connects, request)
	}
	if request.Connection.Host != remoteTestHost {
		return core.RemoteConnectResult{Status: core.RemoteProbeUnreachable}, nil
	}
	if k.refuse != "" {
		return core.RemoteConnectResult{Status: k.refuse}, nil
	}
	return core.RemoteConnectResult{Status: core.RemoteProbeConnected, Session: k.close.session(k.connects, request.Resume)}, nil
}

func (k *remoteHostKernel) RemoteReadDir(_ context.Context, _ string, dir string) (core.RemoteDirectory, error) {
	entries, ok := remoteTestFolders[dir]
	if !ok {
		return core.RemoteDirectory{}, &core.Error{Command: "remote.readDir", Code: core.CodeWorkspaceNotFound, Message: "no such folder: " + dir}
	}
	return core.RemoteDirectory{Entries: entries, SkippedNonUTF8: 1}, nil
}

func (k *remoteHostKernel) RemoteServerState(context.Context, string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.beats++
	if err := k.once; err != nil {
		k.once = nil
		return err
	}
	return k.state
}

func (k *remoteHostKernel) RemoteDisconnect(_ context.Context, id string, programs core.RemoteClosePrograms) (core.RemoteDisconnectResult, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.closed = append(k.closed, id)
	k.close.choices = append(k.close.choices, programs)
	kept := programs == core.RemoteCloseKeep && !k.close.refuseKeep
	if kept {
		if k.close.kept == nil {
			k.close.kept = map[string][]core.RemoteProgram{}
		}
		k.close.kept[k.close.keys[id]] = slices.Clone(k.close.running)
	}
	return core.RemoteDisconnectResult{Closed: true, Kept: kept}, nil
}

func (k *remoteHostKernel) ListDirectories(ctx context.Context, _ string, paths []string) ([]core.DirectoryListing, error) {
	session := ""
	if binding := core.RemoteWorkspaceOf(ctx); binding != nil {
		session = binding.SessionID()
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	k.listings = append(k.listings, session)
	switch {
	case session == "":
		return nil, &core.Error{Command: "workspace.listDirectories", Code: core.CodeConnectionClosed, Message: "the remote workspace is not connected"}
	case k.missing:
		return nil, &core.Error{Command: "workspace.listDirectories", Code: core.CodeWorkspaceNotFound, Message: "the folder is gone"}
	}
	tree := k.tree
	if tree == nil {
		tree = remoteTestTree
	}
	listings := make([]core.DirectoryListing, 0, len(paths))
	for _, dir := range paths {
		listings = append(listings, core.DirectoryListing{Path: dir, Children: slices.Clone(tree[dir])})
	}
	return listings, nil
}

// set changes how the host answers.
func (k *remoteHostKernel) set(change func(k *remoteHostKernel)) {
	k.mu.Lock()
	defer k.mu.Unlock()
	change(k)
}

// count reads one of the host's counters.
func (k *remoteHostKernel) count(read func(k *remoteHostKernel) int) int {
	k.mu.Lock()
	defer k.mu.Unlock()
	return read(k)
}

// remoteTimers keeps the heartbeats and reconnections a workspace schedules, so a test runs each
// when it chooses instead of waiting for it.
type remoteTimers struct {
	mu      sync.Mutex
	pending []*remoteTimer
}

type remoteTimer struct {
	after   time.Duration
	run     func()
	stopped bool
}

func (s *remoteTimers) start(d time.Duration, f func()) func() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	timer := &remoteTimer{after: d, run: f}
	s.pending = append(s.pending, timer)
	return func() bool {
		s.mu.Lock()
		defer s.mu.Unlock()
		stopped := !timer.stopped
		timer.stopped = true
		return stopped
	}
}

// take is the one timer still pending, which no longer is; a workspace has at most one.
func (s *remoteTimers) take(t *testing.T) *remoteTimer {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	var live []*remoteTimer
	for _, timer := range s.pending {
		if !timer.stopped {
			live = append(live, timer)
		}
	}
	s.pending = nil
	if len(live) != 1 {
		t.Fatalf("%d timers pending, want one", len(live))
	}
	live[0].stopped = true
	return live[0]
}

// live counts the timers still pending.
func (s *remoteTimers) live() (n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, timer := range s.pending {
		if !timer.stopped {
			n++
		}
	}
	return n
}

// fireReconnect waits for the pause before the first attempt to connect again, which the
// workspace schedules once it has read the reconnect delays off the window thread, checks it is
// Core's first pause and runs it.
func (h *harness) fireReconnect(t *testing.T, timers *remoteTimers, r *remoteProject) {
	t.Helper()
	h.await("the pause before connecting again", func() bool {
		return r.session == "" && len(r.delays) > 0 && r.attempt == 0 && timers.live() == 1
	})
	if d := h.fire(t, timers); d != time.Second {
		t.Fatalf("paused %v before connecting again, want Core's first pause of 1s", d)
	}
}

// fire runs the pending timer, applies the heartbeat or the attempt it starts, and says how long
// the workspace had asked to wait.
func (h *harness) fire(t *testing.T, timers *remoteTimers) time.Duration {
	t.Helper()
	timer := timers.take(t)
	timer.run()
	// The timer posts to the window, which starts the heartbeat or the attempt; the next pass
	// applies its result, which may start an attempt to connect again or the new session's first
	// heartbeat, applied by the last pass.
	h.settle()
	h.settle()
	h.settle()
	return timer.after
}

// countFailures counts the logged failures of operation, of the user's actions and of the
// window's own work alike.
func countFailures(logger *treeRecordingLog, operation string) int {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	n := 0
	for _, event := range logger.events {
		if (event.Event == operationFailedEvent || event.Event == backgroundFailedEvent) && event.Fields["operation"] == operation {
			n++
		}
	}
	return n
}

// remoteWorkspaceHarness is an English window with one saved connection to remoteTestHost and the
// Remote Development window open on it, whose host is k and whose timers are timers'.
func remoteWorkspaceHarness(t *testing.T) (*harness, *remoteHostKernel, *remoteTimers, *treeRecordingLog) {
	t.Helper()
	k := &remoteHostKernel{testKernel: &testKernel{Client: core.NewClient()}}
	// The folder was kept in safe mode before, so it opens at once and runs none of its code.
	k.git.trust = map[string]string{remoteTestFolder: core.WorkspaceDistrusted}
	h := newHarnessWithLanguages(t, k, []string{"en-US"})
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	timers := &remoteTimers{}
	anchor := filepath.Join(t.TempDir(), remoteplaceholder.AnchorName)
	h.app.remoteBundle = func() (remoteserver.Bundle, error) {
		return remoteserver.Bundle{Version: "0.0.0-test", Builds: []remoteserver.Build{{
			Target: "x86_64-unknown-linux-musl", Path: "/bundle/lithe-server", SHA256: strings.Repeat("0", 64),
		}}}, nil
	}
	h.app.remoteAnchor = func() (string, error) { return anchor, nil }
	h.app.remoteAfter = timers.start
	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	r := &h.app.remote
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.new"))
	r.form.host.SetText(remoteTestHost)
	r.form.user.SetText("dev")
	h.redraw()
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.save"))
	h.settle()
	if r.entry(r.selected) == nil || r.dirty() {
		t.Fatal("the connection was not saved and selected")
	}
	return h, k, timers, logger
}

// clickFront clicks the front-most control named label: the Remote Development window and the
// status bar's menu are declared over the welcome page and the workbench, whose controls share
// names such as Open with theirs.
func (h *harness) clickFront(label string) {
	h.t.Helper()
	h.click(center(h.frontLabeled(label)))
}

// connectAndBrowse presses Connect and waits for the home folder's listing.
func (h *harness) connectAndBrowse(t *testing.T) *remoteBrowser {
	t.Helper()
	h.clickFront(i18n.Shared(h.app.language(), "desktop.remote.openFolder"))
	h.await("the home folder's listing", func() bool {
		b := h.app.remote.browser
		return b != nil && !b.loading
	})
	h.settle()
	return h.app.remote.browser
}

// openRemoteTestProject connects, chooses the project folder and opens it, and waits for the
// Project tool window's listing.
func (h *harness) openRemoteTestProject(t *testing.T) *project {
	t.Helper()
	return h.openBrowsedProject(t, h.connectAndBrowse(t))
}

// openBrowsedProject chooses the project folder in b, opens it and waits for the Project tool
// window's listing.
func (h *harness) openBrowsedProject(t *testing.T, b *remoteBrowser) *project {
	t.Helper()
	h.clickFront("project")
	h.settle()
	if got := b.target(); got != remoteTestHome+"/project" {
		t.Fatalf("Open would open %q, want the selected folder", got)
	}
	open := i18n.SharedFormat(h.app.language(), "desktop.remote.browse.open", map[string]string{"name": "project"})
	if !h.shows(open) {
		t.Fatal("Open does not name the folder it opens")
	}
	h.clickFront(open)
	h.await("the workspace's tree and first heartbeat", func() bool {
		p := h.app.project
		return p != nil && p.remote != nil && !p.remote.beating && p.tree.root != nil && p.tree.root.listed && !p.tree.reading
	})
	h.settle()
	return h.app.project
}

// Connect lists the host account's home folder, its folders and links to folders with hidden ones
// last, and Open opens the selected one as a remote workspace: its root is a placeholder of the
// cache directory, its title names the connection, the title bar shows the connection, and the
// folder is remembered with the connection. Neither the host nor its paths are logged.
func TestRemoteWorkspaceOpensTheChosenFolder(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	b := h.connectAndBrowse(t)
	if got, want := b.folders, []string{"linked", "project", ".cache"}; !slices.Equal(got, want) {
		t.Fatalf("listed %q, want %q", got, want)
	}
	if got, want := b.files, []string{"notes.txt"}; !slices.Equal(got, want) {
		t.Fatalf("listed files %q, want %q", got, want)
	}
	if !h.shows(i18n.SharedFormat(lang, "desktop.remote.browse.title", map[string]string{"name": remoteTestHost})) ||
		!h.showsWrapped(remoteSkippedText(lang, 1)) || !h.shows("notes.txt") {
		t.Fatal("the browser does not show the connection with the home folder's entries")
	}
	if servers := k.servers[0]; len(servers) != 1 || servers[0].Path != "/bundle/lithe-server" {
		t.Fatalf("connected with %+v, want the client's server builds", servers)
	}

	p := h.openBrowsedProject(t, b)
	r := p.remote
	if h.app.remote.open || r == nil || r.session != "session-1" {
		t.Fatalf("window open = %v, remote = %+v: the workspace did not take the session", h.app.remote.open, r)
	}
	entry := savedRemoteConnections(t, h)[0]
	anchor, _ := h.app.remoteAnchor()
	if want := remoteplaceholder.Root(anchor, entry.ID, remoteTestHome+"/project"); p.root != want {
		t.Fatalf("root %q, want the placeholder %q", p.root, want)
	}
	if !slices.Equal(entry.RecentFolders, []string{remoteTestHome + "/project"}) {
		t.Fatalf("remembered %q, want the opened folder", entry.RecentFolders)
	}
	if got, want := h.app.projectDisplayName(p), "project [SSH: "+remoteTestHost+"]"; got != want {
		t.Fatalf("title %q, want %q", got, want)
	}
	if !h.shows("README.md") || !h.remoteHostHasStatus(r) || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.workspace.safeBanner")) {
		t.Fatal("the workspace does not show its tree, its connection and that it is in safe mode")
	}
	if got := k.listings; len(got) == 0 || slices.Contains(got, "") {
		t.Fatalf("listings carried sessions %q, want the workspace's on every one", got)
	}
	if k.beats == 0 || r.link != remoteConnected {
		t.Fatalf("beats = %d, link = %v: the heartbeat did not start", k.beats, r.link)
	}
	if slices.ContainsFunc(h.app.recent, func(recent core.RecentProject) bool { return recent.Path == p.root }) {
		t.Fatal("the placeholder was added to the recent projects")
	}
	want := []string{"remote.connections.open", "remote.connection.new", "remote.connection.save", "remote.connect", "remote.workspace.open"}
	if got := remoteActions(logger); !slices.Equal(got, want) {
		t.Fatalf("performed %q, want %q", got, want)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// What still runs on this computer refuses in a remote workspace and says so: opening a file
// outside the host folder or in a viewer, a plugin's terminal, local history and every tool
// window but the project's, the terminal's, Find's, Git's, Commit's and the notifications'. Copying
// a path copies the host's.
func TestRemoteWorkspaceRefusesWhatRunsLocally(t *testing.T) {
	h, _, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemoteTestProject(t)
	localOnly := i18n.Shared(lang, "desktop.remote.workspace.localOnly")

	// The viewers and a file outside the folder would read this computer's files.
	h.app.openFile(p, filepath.Join(p.root, "logo.png"))
	h.app.openFile(p, filepath.Join(filepath.Dir(p.root), "elsewhere.txt"))
	h.app.openLocalHistory(p, filepath.Join(p.root, "README.md"))
	if h.app.newTerminalWith(p, terminalOptions{plugin: &pluginTerminal{}}) != nil {
		t.Fatal("a plugin's terminal started in the remote workspace")
	}
	h.settle()
	if p.selectedDocument(p.terms.bench.FocusedGroup) != nil || len(p.docs.opening) != 0 {
		t.Fatal("the workspace opened a file")
	}
	for _, operation := range []string{"open_viewer", "open_file", "local_history", "open_terminal"} {
		if !rejected(logger, operation, "remote_workspace") {
			t.Fatalf("%s was not logged as refused", operation)
		}
	}
	if list := h.app.notifications.list; len(list) == 0 || list[0].text != localOnly {
		t.Fatal("the refusal was not notified")
	}

	h.app.openToolWindow(itemBuild)
	h.redraw()
	if !h.showsWrapped(localOnly) {
		t.Fatal("the Build tool window does not say it does not work here")
	}

	var copied []string
	saved := treeCopyText
	treeCopyText = func(text string) error {
		copied = append(copied, text)
		return nil
	}
	t.Cleanup(func() { treeCopyText = saved })
	h.app.copyTreePath(filepath.Join(p.root, "src", "main.go"), false)
	h.app.copyTreePath(p.root, false)
	h.app.copyTreePath(filepath.Join(p.root, "src", "main.go"), true)
	if want := []string{remoteTestHome + "/project/src/main.go", remoteTestHome + "/project", "src/main.go"}; !slices.Equal(copied, want) {
		t.Fatalf("copied %q, want %q", copied, want)
	}
}

// Unanswered heartbeats show the connection not responding; the third ends the session, and the
// workspace connects again on its own, pausing longer each time, until it gives up and shows it
// disconnected. Reconnect in the status bar's menu then connects and lists the tree again over the
// new session, and Disconnect and Close ends the session and closes the workspace.
func TestRemoteWorkspaceReconnectsAfterMissedHeartbeats(t *testing.T) {
	h, k, timers, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemoteTestProject(t)
	r := p.remote

	k.set(func(k *remoteHostKernel) { k.state = context.DeadlineExceeded })
	for miss := 1; miss < remoteHeartbeatMisses; miss++ {
		if d := h.fire(t, timers); d != remoteHeartbeatInterval {
			t.Fatalf("heartbeat after %v, want %v", d, remoteHeartbeatInterval)
		}
		if r.link != remoteUnresponsive || r.session != "session-1" || !h.remoteHostHasStatus(r) {
			t.Fatalf("after %d misses: link %v, session %q", miss, r.link, r.session)
		}
	}
	k.set(func(k *remoteHostKernel) { k.refuse = core.RemoteProbeUnreachable })
	h.fire(t, timers)
	if r.session != "" || r.link != remoteReconnecting || !slices.Contains(k.closed, "session-1") {
		t.Fatalf("after the last miss: session %q, link %v, closed %q", r.session, r.link, k.closed)
	}
	var pauses []time.Duration
	for r.link == remoteReconnecting {
		// The first pause waits for the reconnect delays, which are read off the window thread.
		h.await("the next pause", func() bool { return timers.live() == 1 || r.link != remoteReconnecting })
		if r.link != remoteReconnecting {
			break
		}
		pauses = append(pauses, h.fire(t, timers))
	}
	// Core's automatic reconnect limit of 60 seconds: one attempt after each pause.
	want := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 29 * time.Second}
	if !slices.Equal(pauses, want) {
		t.Fatalf("paused %v before connecting again, want %v", pauses, want)
	}
	if got := k.count(func(k *remoteHostKernel) int { return k.connects }); got != 1+len(want) {
		t.Fatalf("connected %d times, want the first and %d attempts", got, len(want))
	}
	if r.link != remoteDisconnected || !h.remoteHostHasStatus(r) {
		t.Fatalf("link %v after the last attempt, want disconnected", r.link)
	}

	k.set(func(k *remoteHostKernel) { k.refuse, k.state = "", nil })
	listed := k.count(func(k *remoteHostKernel) int { return len(k.listings) })
	h.clickFront(i18n.Shared(lang, "desktop.remote.status.label"))
	h.settle()
	if !h.shows(r.remoteLocation()) || !h.shows(i18n.Shared(lang, "desktop.remote.probe.unreachable")) {
		t.Fatal("the menu does not show the workspace and why connecting again failed")
	}
	h.clickFront(i18n.Shared(lang, "desktop.remote.status.reconnect"))
	h.await("the new session", func() bool { return r.session != "" && !r.beating && !p.tree.reading })
	h.settle()
	if r.link != remoteConnected || r.failure != nil || k.count(func(k *remoteHostKernel) int { return len(k.listings) }) == listed {
		t.Fatalf("link %v, failure %+v: Reconnect did not connect and list the tree again", r.link, r.failure)
	}
	session := r.session

	h.clickFront(i18n.Shared(lang, "desktop.remote.status.label"))
	h.settle()
	h.clickFront(i18n.Shared(lang, "desktop.remote.status.disconnect"))
	h.await("the workspace to close", func() bool { return h.app.project == nil })
	h.settle()
	if !slices.Contains(k.closed, session) {
		t.Fatalf("closed %q, want the workspace's session %q", k.closed, session)
	}
	// The first miss, the lost session and the attempt that gave up are logged once each; the
	// misses after the first and the attempts before the last are the same failure.
	for _, operation := range []string{"remote_heartbeat", "remote_session_lost", "remote_reconnect"} {
		if got := countFailures(logger, operation); got != 1 {
			t.Fatalf("%s logged %d times, want once", operation, got)
		}
	}
	actions := []string{"remote.hosts.open", "remote.workspace.reconnect", "remote.hosts.open", "remote.workspace.disconnect"}
	if got := remoteActions(logger); !slices.Equal(got[len(got)-len(actions):], actions) {
		t.Fatalf("performed %q, want it to end with %q", got, actions)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A heartbeat that finds the connection closed ends the session at once, and the workspace
// connects again on its own over a new session.
func TestRemoteWorkspaceReconnectsWhenTheConnectionCloses(t *testing.T) {
	h, k, timers, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	r := p.remote
	k.set(func(k *remoteHostKernel) {
		k.once = &core.Error{Command: "remote.serverState", Code: core.CodeConnectionClosed, Message: "closed"}
	})
	h.fire(t, timers)
	h.fireReconnect(t, timers, r)
	h.await("the new session", func() bool { return r.session == "session-2" && !r.beating && !p.tree.reading })
	if r.link != remoteConnected || !slices.Contains(k.closed, "session-1") {
		t.Fatalf("link %v, closed %q: the lost session was not replaced", r.link, k.closed)
	}
}

// Back ends the browser's session and shows the form again; a folder that does not exist says so
// in the browser and keeps Open disabled.
func TestRemoteBrowserBackEndsTheSession(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	b := h.connectAndBrowse(t)
	b.path.SetText("~/missing")
	h.app.goRemoteFolder()
	h.await("the missing folder", func() bool { return !b.loading })
	h.settle()
	if b.dir != remoteTestHome+"/missing" || b.openable() || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.browse.notFound")) {
		t.Fatalf("dir %q, openable %v: the missing folder is not reported", b.dir, b.openable())
	}
	b.path.SetText("relative/path")
	h.app.goRemoteFolder()
	h.settle()
	if !rejected(logger, "remote_read_dir", "path_not_absolute") {
		t.Fatal("a relative path was not refused")
	}

	h.clickFront(i18n.Shared(lang, "desktop.remote.browse.back"))
	h.settle()
	h.settle()
	if h.app.remote.browser != nil || !h.app.remote.open || !slices.Contains(k.closed, "session-1") {
		t.Fatalf("browser %v, closed %q: Back did not end the session", h.app.remote.browser, k.closed)
	}
	if !h.shows(i18n.Shared(lang, "desktop.remote.openFolder")) {
		t.Fatal("Back does not show the form again")
	}
	if event := loggedAny(t, logger, remoteTestHome); event != "" {
		t.Fatalf("logged a host path: %s", event)
	}
}

// After a listing the folder page tags the subfolders holding a .git entry, a folder or a
// worktree's file, and leaves the others untagged.
func TestRemoteBrowserTagsGitRepositories(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	k.set(func(k *remoteHostKernel) {
		k.kinds = map[string]core.RemoteFileKind{
			remoteTestHome + "/project/.git": core.RemoteFileKindDirectory,
			remoteTestHome + "/linked/.git":  core.RemoteFileKindFile,
		}
	})
	b := h.connectAndBrowse(t)
	h.await("the Git tags", func() bool { return b.repositories != nil })
	h.settle()
	if !b.repositories["project"] || !b.repositories["linked"] || b.repositories[".cache"] {
		t.Fatalf("repositories = %v, want project and linked", b.repositories)
	}
	if !h.shows(i18n.Shared(h.app.language(), "desktop.remote.browse.git")) {
		t.Fatal("the folder list does not tag the repositories")
	}
}
