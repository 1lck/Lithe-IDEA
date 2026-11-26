package workbench

import (
	"context"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

// The WSL distributions of the test's computer: remoteTestWSL is installed and connects, and
// remoteTestWSLGone is listed but does not start.
const (
	remoteTestWSL     = "Ubuntu-24.04"
	remoteTestWSLGone = "Debian"
)

// remoteHostWSL stands in for wsl.exe: it lists the distributions and connects to remoteTestWSL
// alone, recording each connection asked for. Its zero value lists none, as Core answers on a
// system without WSL.
type remoteHostWSL struct {
	list core.RemoteWSLDistributions
	// lists counts the listings; requests are the connections asked for, in order.
	lists    int
	requests []core.WSLConnection
	// refuse is the error the next connections end with; nil connects.
	refuse error
}

func (k *remoteHostKernel) RemoteListWSLDistributions(context.Context) (core.RemoteWSLDistributions, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.wsl.lists++
	return k.wsl.list, nil
}

// connect answers the connect request numbered n, which names a WSL distribution. It runs under
// the kernel's lock.
func (w *remoteHostWSL) connect(n int, request core.RemoteConnectRequest) (core.RemoteConnectResult, error) {
	w.requests = append(w.requests, *request.WSL)
	if w.refuse != nil {
		return core.RemoteConnectResult{}, w.refuse
	}
	if request.Connection != (core.SSHConnection{}) || request.WSL.Distribution != remoteTestWSL {
		return core.RemoteConnectResult{Status: core.RemoteProbeUnreachable}, nil
	}
	session := &core.RemoteSession{ID: "session-" + strconv.Itoa(n), HostName: "wsl", UserName: "dev", HomeDirectory: remoteTestHome}
	return core.RemoteConnectResult{Status: core.RemoteProbeConnected, Session: session}, nil
}

// remoteWSLHarness is remoteWorkspaceHarness on a computer with remoteTestWSL and
// remoteTestWSLGone installed, the window opened again so that it lists them.
func remoteWSLHarness(t *testing.T) (*harness, *remoteHostKernel, *treeRecordingLog) {
	t.Helper()
	h, k, _, logger := remoteWorkspaceHarness(t)
	k.set(func(k *remoteHostKernel) {
		k.wsl.list = core.RemoteWSLDistributions{Available: true, Distributions: []string{remoteTestWSL, remoteTestWSLGone}}
	})
	h.app.closeRemote()
	h.app.openRemote(surfaceMenu)
	h.await("the WSL distributions", func() bool { return h.app.remote.wsl.loaded && !h.app.remote.loading })
	h.settle()
	return h, k, logger
}

// The window lists the WSL distributions under their own heading after the saved connections, and
// a distribution's page opens a folder in it as the account typed: Core is asked to connect over
// wsl.exe, not OpenSSH, and the workspace names the distribution. Nothing is saved for it, and
// neither the distribution nor the account is logged.
func TestRemoteWSLOpensAFolderInADistribution(t *testing.T) {
	h, k, logger := remoteWSLHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	heading := i18n.Shared(lang, "desktop.remote.wsl.heading")
	if !h.shows(heading) || !h.shows(remoteTestWSL) || !h.shows(remoteTestWSLGone) {
		t.Fatal("the list does not show the WSL heading with the distributions")
	}
	if at := r.wslRow(remoteTestWSL); at <= r.rowOf(r.selected) {
		t.Fatalf("WSL row %d, saved row %d: the distributions are not after the saved connections", at, r.rowOf(r.selected))
	}

	h.clickFront(remoteTestWSL)
	h.settle()
	if r.wsl.selected != remoteTestWSL || r.selected != "" || r.list.Selected() != r.wslRow(remoteTestWSL) {
		t.Fatal("choosing the distribution does not show its page")
	}
	if !h.showsWrapped(i18n.Shared(lang, "desktop.remote.wsl.about")) || !h.shows("wsl:"+remoteTestWSL) {
		t.Fatal("the page does not say how the distribution opens")
	}
	r.wsl.user.SetText("dev")
	h.redraw()
	if !h.shows("wsl:dev@" + remoteTestWSL) {
		t.Fatal("the page does not name the account typed")
	}

	p := h.openBrowsedProject(t, h.connectAndBrowse(t))
	if got := k.wsl.requests; len(got) != 1 || got[0] != (core.WSLConnection{Distribution: remoteTestWSL, User: "dev"}) {
		t.Fatalf("asked for %d WSL connections, want the distribution as the account typed", len(got))
	}
	identity := "wsl:dev@" + remoteTestWSL
	anchor, _ := h.app.remoteAnchor()
	if want := remoteplaceholder.Root(anchor, identity, remoteTestHome+"/project"); p.root != want || p.remote.connectionID != identity {
		t.Fatal("the workspace is not placed under the distribution's identity")
	}
	if got, want := h.app.projectDisplayName(p), "project [WSL: "+remoteTestWSL+"]"; got != want {
		t.Fatalf("title %q, want %q", got, want)
	}
	if status := remoteStatusText(lang, p.remote); !strings.HasPrefix(status, "WSL: "+remoteTestWSL) || !h.remoteHostHasStatus(p.remote) {
		t.Fatalf("status %q does not name the distribution over WSL", status)
	}
	saved := savedRemoteConnections(t, h)
	if len(saved) != 1 || len(saved[0].RecentFolders) != 0 || saved[0].LastConnectedAt != 0 {
		t.Fatalf("%d saved connections: opening in WSL changed the saved list", len(saved))
	}
	if countFailures(logger, "remote_remember_folder") != 0 {
		t.Fatal("remembering the folder was tried for a distribution")
	}
	want := []string{"remote.connections.open", "remote.connection.new", "remote.connection.save", "remote.connections.open", "remote.wsl.select", "remote.connect", "remote.workspace.open"}
	if got := remoteActions(logger); !slices.Equal(got, want) {
		t.Fatalf("performed %q, want %q", got, want)
	}
	if event := loggedAny(t, logger, remoteTestWSL, "dev@", remoteTestHome); event != "" {
		t.Fatal("logged the distribution, the account or a host path")
	}

	// A window over the distribution shows it connected, whatever the account.
	h.app.openRemote(surfaceMenu)
	h.await("the WSL distributions", func() bool { return h.app.remote.wsl.loaded })
	if h.app.remoteWSLWindows(remoteTestWSL) != 1 || h.app.remoteWSLWindows(remoteTestWSLGone) != 0 {
		t.Fatal("the windows open over the distribution are not counted")
	}
}

// A distribution that does not start fails at the connection with WSL's own text and no OpenSSH
// hint; a search lists the saved connections only, and folding the heading hides the
// distributions.
func TestRemoteWSLFailuresSearchAndFolding(t *testing.T) {
	h, k, _ := remoteWSLHarness(t)
	lang := h.app.language()
	r := &h.app.remote

	h.clickFront(remoteTestWSLGone)
	h.settle()
	h.clickFront(i18n.Shared(lang, "desktop.remote.connect"))
	h.await("the failed connection", func() bool { return r.steps != nil && r.steps.failed })
	h.settle()
	outcome := r.steps.outcome
	if !outcome.wsl || remoteFailureText(lang, outcome) != i18n.Shared(lang, "desktop.remote.wsl.unreachable") || remoteFailureHint(lang, outcome) != "" {
		t.Fatal("the failure does not read as WSL's")
	}
	if !h.showsWrapped(i18n.Shared(lang, "desktop.remote.wsl.unreachable")) || h.showsWrapped(i18n.Shared(lang, "desktop.remote.probe.hint.unreachable")) {
		t.Fatal("the page does not show WSL's failure alone")
	}
	if !h.shows("wsl:" + remoteTestWSLGone) {
		t.Fatal("the steps do not name the distribution")
	}
	if !h.shows(i18n.Shared(lang, "desktop.remote.wsl.start")) || h.shows(i18n.Shared(lang, "desktop.remote.step.config")) ||
		h.shows(i18n.Shared(lang, "desktop.remote.step.authenticate")) || h.shows(i18n.Shared(lang, "desktop.remote.steps.editConnection")) {
		t.Fatal("the steps of a distribution list OpenSSH's, or offer a connection's form")
	}

	// Core refusing the account names the account, on the distribution's page.
	h.app.stopRemoteConnect()
	r.steps = nil
	k.set(func(k *remoteHostKernel) {
		k.wsl.refuse = &core.Error{Command: "remote.connect", Code: core.CodeInvalidRequest, Message: "invalid", Details: `{"field":"user","reason":"tooLong"}`}
	})
	r.wsl.user.SetText(strings.Repeat("u", 40))
	h.redraw()
	h.clickFront(i18n.Shared(lang, "desktop.remote.connect"))
	h.await("the refused account", func() bool { return r.connect == nil && r.err != "" })
	h.settle()
	if r.err != i18n.Shared(lang, "desktop.remote.wsl.userTooLong") || r.steps != nil || !h.shows(r.err) {
		t.Fatal("the refused account is not explained on the page")
	}

	// Choosing a saved connection leaves the distribution's page.
	h.clickFront(remoteTestHost)
	h.settle()
	if r.wsl.selected != "" || r.entry(r.selected) == nil {
		t.Fatal("choosing the saved connection does not show it")
	}

	r.query.SetText(remoteTestHost)
	h.app.searchRemote()
	h.await("the search", func() bool { return r.found != nil })
	h.settle()
	if r.wslRow(remoteTestWSL) >= 0 || h.shows(remoteTestWSL) {
		t.Fatal("a search lists the WSL distributions")
	}
	h.app.clearRemoteSearch()
	h.settle()
	if r.wslRow(remoteTestWSL) < 0 {
		t.Fatal("clearing the search does not list the distributions again")
	}
	h.app.toggleRemoteGroup(remoteWSLHeading)
	h.redraw()
	if r.wslRow(remoteTestWSL) >= 0 || !h.shows(i18n.Shared(lang, "desktop.remote.wsl.heading")) {
		t.Fatal("folding the WSL heading does not keep the heading alone")
	}
}

// Without WSL, Core answers the list as unavailable, and the window shows no WSL heading.
func TestRemoteWSLAbsentShowsNothing(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	r := &h.app.remote
	h.await("the WSL distributions", func() bool { return r.wsl.loaded })
	h.settle()
	if k.count(func(k *remoteHostKernel) int { return k.wsl.lists }) != 1 {
		t.Fatal("the distributions are not listed once when the window opens")
	}
	if slices.ContainsFunc(r.rows, func(row remoteListRow) bool { return row.wsl != "" || row.group == remoteWSLHeading }) {
		t.Fatal("the list shows WSL rows without WSL")
	}
	if h.shows(i18n.Shared(h.app.language(), "desktop.remote.wsl.heading")) {
		t.Fatal("the window shows the WSL heading without WSL")
	}
}
