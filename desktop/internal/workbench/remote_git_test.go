package workbench

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

// remoteHostGit stands in for Core's record of the remote workspaces' trust and for the host's
// repository, which Core reaches over the session a request carries.
type remoteHostGit struct {
	// trust is each host folder's recorded trust; a folder missing is undecided. decisions are
	// the decisions recorded.
	trust     map[string]string
	decisions []core.RemoteWorkspaceTrustDecision
	trustErr  error
	// repository is where the host's repository starts: "" for none, "." at the folder, "above"
	// at the account's home folder, above the folder.
	repository string
	// statuses are the sessions the status reads carried; classified are the paths Core was
	// asked to classify, one batch each.
	statuses   []string
	classified [][]string
	// blame is the blame Core answers; blamed are the paths blamed.
	blame  []core.GitBlameLine
	blamed []string
	// created are the host folders created.
	created []string
	// references are the host repository's references; worktrees are its linked worktrees' host
	// folders, and creations the worktrees Core was asked to create (remote_worktree_test.go).
	references core.GitReferences
	worktrees  []string
	creations  []remoteWorktreeCreation
}

// remoteTrustStorage is the preference file the trust decisions are kept in.
var remoteTrustStorage = core.RemoteWorkspaceTrustStorage{RelativePath: "toolchains/remote-trust.json", MaximumBytes: 1 << 20}

func (k *remoteHostKernel) RemoteWorkspaceTrust(_ context.Context, _ *string, session, workspace string) (core.RemoteWorkspaceTrustState, error) {
	state := core.RemoteWorkspaceTrustState{Storage: remoteTrustStorage}
	if session == "" {
		return state, nil
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.git.trustErr != nil {
		return state, k.git.trustErr
	}
	decided, ok := k.git.trust[workspace]
	if !ok {
		decided = core.WorkspaceTrustUnset
	}
	state.ProjectCodeAllowed = decided == core.WorkspaceTrusted
	state.WorkspaceTrust = &core.RemoteWorkspaceTrustOf{State: decided, Workspace: workspace}
	return state, nil
}

func (k *remoteHostKernel) EditRemoteWorkspaceTrust(_ context.Context, _ *string, decision core.RemoteWorkspaceTrustDecision) (core.RemoteWorkspaceTrustPublication, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.git.decisions = append(k.git.decisions, decision)
	if k.git.trust == nil {
		k.git.trust = map[string]string{}
	}
	k.git.trust[decision.Workspace] = core.WorkspaceDistrusted
	if decision.Trusted {
		k.git.trust[decision.Workspace] = core.WorkspaceTrusted
	}
	document := "{}"
	return core.RemoteWorkspaceTrustPublication{Changed: true, Document: &document}, nil
}

// onHost answers a request as Core does: one without the workspace's binding runs on this
// computer (local), one whose workspace has no session fails as a lost connection, and the host
// answers the rest from where its repository starts (host).
func onHost[T any](ctx context.Context, k *remoteHostKernel, command string, local func() (T, error), host func(repository string) (T, error)) (T, error) {
	binding := core.RemoteWorkspaceOf(ctx)
	if binding == nil {
		return local()
	}
	if binding.SessionID() == "" {
		var zero T
		return zero, &core.Error{Command: command, Code: core.CodeConnectionClosed, Message: "the remote workspace is not connected"}
	}
	k.mu.Lock()
	repository := k.git.repository
	k.mu.Unlock()
	return host(repository)
}

// remoteRepositoryTop is the placeholder path of the host repository's top folder.
func remoteRepositoryTop(root, repository string) string {
	if repository == "above" {
		top, _ := remoteplaceholder.LocalPath(root, remoteTestFolder, remoteTestHome)
		return top
	}
	return root
}

func (k *remoteHostKernel) GitStatus(ctx context.Context, root string) (core.GitStatus, error) {
	if binding := core.RemoteWorkspaceOf(ctx); binding != nil {
		k.set(func(k *remoteHostKernel) { k.git.statuses = append(k.git.statuses, binding.SessionID()) })
	}
	return onHost(ctx, k, "git.status", func() (core.GitStatus, error) { return k.testKernel.GitStatus(ctx, root) },
		func(repository string) (core.GitStatus, error) {
			switch repository {
			case "":
				return core.GitStatus{}, nil
			case "above":
				return core.GitStatus{RepositoryRoot: remoteRepositoryTop(root, repository), Branch: "main"}, nil
			}
			return core.GitStatus{RepositoryRoot: ".", Branch: "main"}, nil
		})
}

func (k *remoteHostKernel) GitWatchContextOf(ctx context.Context, root string) (core.GitWatchContext, bool, error) {
	type answer struct {
		watch core.GitWatchContext
		found bool
	}
	got, err := onHost(ctx, k, "git.watchContext", func() (answer, error) {
		watch, found, err := k.Client.GitWatchContextOf(ctx, root)
		return answer{watch, found}, err
	}, func(repository string) (answer, error) {
		if repository == "" {
			return answer{}, nil
		}
		top := remoteRepositoryTop(root, repository)
		git := filepath.Join(top, ".git")
		return answer{core.GitWatchContext{RepositoryRoot: top, GitDirectory: git, GitCommonDirectory: git}, true}, nil
	})
	return got.watch, got.found, err
}

func (k *remoteHostKernel) GitClassifyMetadataChanges(ctx context.Context, metadata core.GitMetadataContext, paths []string) ([]core.GitMetadataEvent, error) {
	return onHost(ctx, k, "git.classifyMetadataChanges", func() ([]core.GitMetadataEvent, error) {
		return k.Client.GitClassifyMetadataChanges(ctx, metadata, paths)
	}, func(string) ([]core.GitMetadataEvent, error) {
		k.set(func(k *remoteHostKernel) { k.git.classified = append(k.git.classified, slices.Clone(paths)) })
		events := make([]core.GitMetadataEvent, len(paths))
		for i := range events {
			events[i] = core.GitMetadataEvent{Kind: "metadata"}
		}
		return events, nil
	})
}

func (k *remoteHostKernel) DiscoverWorkspaceRepositories(ctx context.Context, root string) ([]core.WorkspaceRepository, error) {
	return onHost(ctx, k, "workspace.repositories", func() ([]core.WorkspaceRepository, error) {
		return k.Client.DiscoverWorkspaceRepositories(ctx, root)
	}, func(string) ([]core.WorkspaceRepository, error) { return nil, nil })
}

func (k *remoteHostKernel) GitRebaseSession(ctx context.Context, root string) (*core.RebaseSession, error) {
	return onHost(ctx, k, "git.rebaseSession", func() (*core.RebaseSession, error) { return k.Client.GitRebaseSession(ctx, root) },
		func(string) (*core.RebaseSession, error) { return nil, nil })
}

func (k *remoteHostKernel) GitOperationState(ctx context.Context, root string) (core.GitOperation, error) {
	return onHost(ctx, k, "git.operationState", func() (core.GitOperation, error) { return k.Client.GitOperationState(ctx, root) },
		func(string) (core.GitOperation, error) { return core.GitOperation{}, nil })
}

func (k *remoteHostKernel) GitReferences(ctx context.Context, root string) (core.GitReferences, error) {
	return onHost(ctx, k, "git.references", func() (core.GitReferences, error) { return k.Client.GitReferences(ctx, root) },
		func(string) (core.GitReferences, error) {
			k.mu.Lock()
			defer k.mu.Unlock()
			return k.git.references, nil
		})
}

// GitReferenceTree groups the host's references as Core does: its handler computes from the
// names alone, so the tree is the one this computer's Core builds.
func (k *remoteHostKernel) GitReferenceTree(ctx context.Context, names []string, prioritized map[string]bool) ([]core.ReferenceTreeNode, error) {
	return onHost(ctx, k, "git.referenceTree", func() ([]core.ReferenceTreeNode, error) { return k.Client.GitReferenceTree(ctx, names, prioritized) },
		func(string) ([]core.ReferenceTreeNode, error) {
			return k.Client.GitReferenceTree(context.Background(), names, prioritized)
		})
}

func (k *remoteHostKernel) GitHistoryPage(ctx context.Context, root, reference, cursor string, limit, maxCommits int) (core.GitHistoryPage, error) {
	return onHost(ctx, k, "git.historyPage", func() (core.GitHistoryPage, error) {
		return k.Client.GitHistoryPage(ctx, root, reference, cursor, limit, maxCommits)
	}, func(string) (core.GitHistoryPage, error) { return core.GitHistoryPage{}, nil })
}

func (k *remoteHostKernel) GitGraph(ctx context.Context, request core.GraphRequest) (core.Graph, error) {
	return onHost(ctx, k, "git.graph", func() (core.Graph, error) { return k.Client.GitGraph(ctx, request) },
		func(string) (core.Graph, error) { return core.Graph{}, nil })
}

func (k *remoteHostKernel) GitDiff(ctx context.Context, request core.GitDiffRequest) ([]core.GitDiffFile, error) {
	return onHost(ctx, k, "git.diff", func() ([]core.GitDiffFile, error) { return k.Client.GitDiff(ctx, request) },
		func(string) ([]core.GitDiffFile, error) { return nil, nil })
}

func (k *remoteHostKernel) GitBlame(ctx context.Context, root, path string) ([]core.GitBlameLine, error) {
	return onHost(ctx, k, "git.blame", func() ([]core.GitBlameLine, error) { return k.Client.GitBlame(ctx, root, path) },
		func(string) ([]core.GitBlameLine, error) {
			k.mu.Lock()
			defer k.mu.Unlock()
			k.git.blamed = append(k.git.blamed, path)
			return slices.Clone(k.git.blame), nil
		})
}

func (k *remoteHostKernel) RemoteCreateDirectory(_ context.Context, session, path string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.takeFileError(session); err != nil {
		return err
	}
	k.git.created = append(k.git.created, path)
	if k.kinds == nil {
		k.kinds = map[string]core.RemoteFileKind{}
	}
	k.kinds[path] = core.RemoteFileKindDirectory
	return nil
}

// hostGit is a copy of what the host's repository was asked.
func (k *remoteHostKernel) hostGit() remoteHostGit {
	k.mu.Lock()
	defer k.mu.Unlock()
	g := k.git
	g.statuses, g.classified, g.decisions = slices.Clone(g.statuses), slices.Clone(g.classified), slices.Clone(g.decisions)
	g.blamed, g.created = slices.Clone(g.blamed), slices.Clone(g.created)
	return g
}

// trustAtHost records the host folder's trust and where its repository starts before it opens.
func (k *remoteHostKernel) trustAtHost(trust, repository string) {
	k.set(func(k *remoteHostKernel) {
		k.git.trust[remoteTestFolder] = trust
		k.git.repository = repository
	})
}

// watchAt is the watch the host ran last of root.
func (k *remoteHostKernel) watchAt(t *testing.T, root string) *remoteHostWatch {
	t.Helper()
	k.watches.mu.Lock()
	defer k.watches.mu.Unlock()
	for i := len(k.watches.runs) - 1; i >= 0; i-- {
		if k.watches.runs[i].root == root {
			return k.watches.runs[i]
		}
	}
	t.Fatal("the host ran no watch of the folder")
	return nil
}

// sessionKept fails t when the workspace lost its session: a request Core does not answer for a
// remote workspace ends it.
func sessionKept(t *testing.T, logger *treeRecordingLog, p *project, session string) {
	t.Helper()
	if got := countFailures(logger, "remote_session_lost"); got != 0 || p.remote.session != session {
		logger.mu.Lock()
		defer logger.mu.Unlock()
		for _, event := range logger.events {
			if event.Fields["operation"] == "remote_session_lost" {
				t.Logf("lost: %v", event.Fields)
			}
		}
		t.Fatalf("the session was lost %d times", got)
	}
}

// awaitRemoteGit waits until the trusted workspace p read its repository's status and watches its
// git directory over its session.
func (h *harness) awaitRemoteGit(p *project) *remoteGitWatch {
	h.t.Helper()
	dir := filepath.Join(p.root, ".git")
	h.await("the host's status and Git watch", func() bool {
		w := p.observe.remote[dir]
		if w == nil || !p.git.isRepository() {
			return false
		}
		w.mu.Lock()
		defer w.mu.Unlock()
		return w.watching
	})
	h.settle()
	return p.observe.remote[dir]
}

// A folder never decided is asked about before it opens; trusting it records the decision with
// the connection's name and opens it trusted, so its Git runs on the host over the session and
// the notice says Git works there. Neither the host nor its paths are logged.
func TestRemoteWorkspaceAsksToTrustBeforeItOpens(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.set(func(k *remoteHostKernel) {
		delete(k.git.trust, remoteTestFolder)
		k.git.repository = "."
	})
	h.connectAndBrowse(t)
	h.clickFront("project")
	h.settle()
	h.clickFront(i18n.SharedFormat(lang, "desktop.remote.browse.open", map[string]string{"name": "project"}))
	h.await("the trust question", func() bool { return h.app.remote.trust != nil })
	h.redraw()
	if p := h.app.project; p != nil && p.remote != nil {
		t.Fatal("the folder opened before the question was answered")
	}
	h.clickFront(i18n.Shared(lang, "desktop.remote.trust.trustOpen"))
	h.await("the trusted workspace", func() bool {
		p := h.app.project
		return p != nil && p.remote != nil && p.tree.root != nil && p.tree.root.listed
	})
	p := h.app.project
	h.awaitRemoteGit(p)
	h.redraw()
	g := k.hostGit()
	want := core.RemoteWorkspaceTrustDecision{SessionID: "session-1", Workspace: remoteTestFolder, Trusted: true, Label: remoteTestHost}
	if len(g.decisions) != 1 || g.decisions[0] != want {
		t.Fatalf("recorded %d decisions, want the trust of the folder under the connection's name", len(g.decisions))
	}
	if p.safeMode() || len(g.statuses) == 0 || slices.ContainsFunc(g.statuses, func(s string) bool { return s != "session-1" }) {
		t.Fatalf("safe mode = %v, %d status reads: Git did not run over the session", p.safeMode(), len(g.statuses))
	}
	if !h.showsWrapped(i18n.Shared(lang, "desktop.remote.workspace.banner")) || h.showsWrapped(i18n.Shared(lang, "desktop.remote.workspace.safeBanner")) {
		t.Fatal("the notice does not say the trusted workspace runs Git on the host")
	}
	if got := remoteActions(logger); !slices.Contains(got, "remote.workspace.trust") {
		t.Fatalf("performed %q, want the trust", got)
	}
	sessionKept(t, logger, p, "session-1")
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A folder kept in safe mode opens with Git off and says so; trusting it from the notice records
// the trust and starts Git on the host: the status, and the watch of the git directory, whose
// changes read the status again. A new session watches it again, and nothing of the repository
// is written to the placeholder.
func TestRemoteWorkspaceTrustStartsGitOnTheHost(t *testing.T) {
	h, k, timers, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.set(func(k *remoteHostKernel) { k.git.repository = "." })
	p := h.openRemoteTestProject(t)
	r := p.remote
	if !p.safeMode() || !p.git.safeMode || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.workspace.safeBanner")) {
		t.Fatal("the folder kept in safe mode did not open in safe mode")
	}
	if g := k.hostGit(); len(g.statuses) != 0 || k.watchRuns() != 1 {
		t.Fatalf("%d status reads, %d watches: Git ran in safe mode", len(g.statuses), k.watchRuns())
	}

	h.app.askToTrustProject(p, nil)
	h.redraw()
	h.clickFront(i18n.Shared(lang, "desktop.trust.trustProject"))
	w := h.awaitRemoteGit(p)
	host := k.watchAt(t, remoteTestFolder+"/.git")
	if w.session != "session-1" || host.session != "session-1" || len(host.excludes) != 0 {
		t.Fatalf("watched the git directory over %q excluding %d folders, want the session and the whole folder", host.session, len(host.excludes))
	}
	if g := k.hostGit(); len(g.decisions) != 1 || !g.decisions[0].Trusted || g.decisions[0].Workspace != remoteTestFolder {
		t.Fatal("trusting the workspace did not record its trust")
	}

	reads := len(k.hostGit().statuses)
	host.changed(t, ".git/HEAD")
	head := filepath.Join(p.root, ".git", "HEAD")
	h.await("the classified change and the status read after it", func() bool {
		g := k.hostGit()
		return slices.ContainsFunc(g.classified, func(paths []string) bool { return slices.Contains(paths, head) }) && len(g.statuses) > reads
	})
	h.settle()
	sessionKept(t, logger, p, "session-1")

	k.set(func(k *remoteHostKernel) {
		k.once = &core.Error{Command: "remote.serverState", Code: core.CodeConnectionClosed, Message: "closed"}
	})
	h.fire(t, timers)
	host.awaitEnd(t)
	h.fireReconnect(t, timers, r)
	h.await("the second session", func() bool { return r.session == "session-2" && !r.beating })
	if w := h.awaitRemoteGit(p); w.session != "session-2" || k.watchAt(t, remoteTestFolder+"/.git").session != "session-2" {
		t.Fatal("the new session does not watch the git directory")
	}
	if _, err := os.Lstat(filepath.Join(p.root, ".git")); err == nil {
		t.Fatal("the repository's metadata was written to the placeholder")
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// Losing the connection revokes permission immediately. Reconnecting reads the host folder's
// current decision before starting Git, including a decision changed while disconnected.
func TestRemoteReconnectRechecksWorkspaceTrust(t *testing.T) {
	for _, failed := range []bool{false, true} {
		name := "revoked"
		if failed {
			name = "unreadable"
		}
		t.Run(name, func(t *testing.T) {
			h, k, timers, logger := remoteWorkspaceHarness(t)
			k.trustAtHost(core.WorkspaceTrusted, ".")
			p := h.openRemoteTestProject(t)
			h.awaitRemoteGit(p)
			h.app.loseRemote(p, p.remote.session, &core.Error{Code: core.CodeConnectionClosed})
			if !p.safeMode() {
				t.Fatal("the disconnected workspace retained permission to run code")
			}
			if failed {
				k.set(func(k *remoteHostKernel) { k.git.trustErr = &core.Error{Code: core.CodeParseFailed} })
			} else {
				k.trustAtHost(core.WorkspaceDistrusted, ".")
			}
			h.fireReconnect(t, timers, p.remote)
			h.await("the second session", func() bool { return p.remote.session == "session-2" && !p.remote.beating })
			h.settle()
			if !p.safeMode() || slices.Contains(k.hostGit().statuses, "session-2") {
				t.Fatal("reconnecting reused permission without a current trust decision")
			}
			if failed && countFailures(logger, "remote_trust_read") != 1 {
				t.Fatal("the failed trust read was not logged")
			}
		})
	}
}

// Excluding a file adds its pattern to the host repository's info/exclude: the folder Git
// creates from its template is created when missing, and a file that does not end its last line
// gets the line ended first.
func TestRemoteWorkspaceExcludesOnTheHost(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	k.trustAtHost(core.WorkspaceTrusted, ".")
	p := h.openRemoteTestProject(t)
	h.awaitRemoteGit(p)
	exclude := remoteTestFolder + "/.git/info/exclude"

	h.app.excludeLocally(p, core.GitChange{Path: "build/"})
	h.await("the first exclusion", func() bool { text, _ := k.file(exclude); return text == "/build/\n" })
	if got := k.hostGit().created; !slices.Equal(got, []string{remoteTestFolder + "/.git/info"}) {
		t.Fatalf("created %q, want the missing info folder", got)
	}
	k.put(exclude, "# local\n/build/")
	h.app.excludeLocally(p, core.GitChange{Path: "out.log"})
	h.await("the second exclusion", func() bool { text, _ := k.file(exclude); return text == "# local\n/build/\n/out.log\n" })
	h.settle()
	if got := countFailures(logger, "git_exclude"); got != 0 || len(k.hostGit().created) != 1 {
		t.Fatalf("%d exclusions failed: the existing file was not added to", got)
	}
	sessionKept(t, logger, p, "session-1")
}

// The blame of a file shows the host's text of it beside Core's annotations.
func TestRemoteWorkspaceBlamesTheHostsFile(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	k.put(remoteTestReadme, "# Project\nText\n")
	k.trustAtHost(core.WorkspaceTrusted, ".")
	k.set(func(k *remoteHostKernel) {
		k.git.blame = []core.GitBlameLine{{Line: 1, Hash: "a1", AuthorName: "Dev", AuthorTime: 1}, {Line: 2, Hash: "a1", AuthorName: "Dev", AuthorTime: 1}}
	})
	p := h.openRemoteTestProject(t)
	h.awaitRemoteGit(p)
	h.app.openBlame(p, "README.md")
	h.await("the blame", func() bool { return !p.review.blame.loading })
	b := &p.review.blame
	if b.err != "" || len(b.lines) != 2 || !slices.Equal(b.text, []string{"# Project", "Text"}) {
		t.Fatalf("blame failed = %v with %d lines and %d of text, want the host's file", b.err != "", len(b.lines), len(b.text))
	}
	if got := k.hostGit().blamed; !slices.Equal(got, []string{"README.md"}) {
		t.Fatalf("blamed %q, want the file", got)
	}
	sessionKept(t, logger, p, "session-1")
}

// A folder inside a repository that starts above it on the host keeps its Git views empty and
// says why, rather than show changes the project tree does not hold.
func TestRemoteWorkspaceSaysItsRepositoryStartsAbove(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.trustAtHost(core.WorkspaceTrusted, "above")
	p := h.openRemoteTestProject(t)
	h.await("the status", func() bool { return p.git.remoteAbove })
	above := i18n.Shared(lang, "desktop.remote.workspace.gitAbove")
	for _, window := range []string{itemCommit, itemGit} {
		h.app.openToolWindow(window)
		h.redraw()
		if !h.showsWrapped(above) {
			t.Fatalf("the %s tool window does not say the repository starts above the folder", window)
		}
	}
	if _, ok := p.git.changeCount(); ok || p.git.branch() != "" || countFailures(logger, "git_status") != 0 {
		t.Fatal("the repository above the folder was shown or logged as a failure")
	}
	sessionKept(t, logger, p, "session-1")
}

// What runs the project's code on this computer refuses in a trusted remote workspace too, and
// says so: Debug, the current file's run, a run that is not a configuration, the tests and the
// build tasks, and the Debug tool window. Run configurations start on the host
// (remote_run_test.go).
func TestRemoteWorkspaceRefusesToRunItsCode(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.trustAtHost(core.WorkspaceTrusted, ".")
	p := h.openRemoteTestProject(t)
	h.awaitRemoteGit(p)
	h.app.titleStart(p, titleActionDebug)
	h.app.performCurrentFileAction(p, titleActionRun)
	h.app.startRun(p, "run", func(*App, *project) { t.Error("a run started") })
	h.app.startTests(p, testSelection{})
	if _, err := h.app.runBuildTask(p, "project", "target", "task", nil); err == nil {
		t.Fatal("a build task started")
	}
	h.settle()
	for _, operation := range []string{"title_run", "run_current_file", "run_start", "test_start", "build_task"} {
		if !rejected(logger, operation, "remote_workspace") {
			t.Fatalf("%s was not logged as refused", operation)
		}
	}
	localOnly := i18n.Shared(lang, "desktop.remote.workspace.localOnly")
	if !h.notified(localOnly) || p.trust.asking {
		t.Fatal("the refusal was not notified, or the trusted workspace asked to be trusted")
	}
	h.app.openToolWindow(itemDebug)
	h.redraw()
	if !h.showsWrapped(localOnly) {
		t.Fatal("the Debug tool window does not say it does not work here")
	}
	sessionKept(t, logger, p, "session-1")
}
