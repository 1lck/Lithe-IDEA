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

// The running containers of the test's computer: remoteTestContainer runs under Docker and
// connects, and remoteTestContainerGone runs under Podman and is gone by the time it is entered.
const (
	remoteTestContainer     = "web-frontend"
	remoteTestContainerGone = "pg-main"
	remoteTestImage         = "node:22-bookworm"
)

// The test kernels over the real Core find no container engine, so that no test runs this
// computer's docker or podman: only remoteHostKernel lists containers, the ones its test sets.
func (k *testKernel) RemoteListContainers(context.Context, string, string) (core.RemoteContainers, error) {
	return core.RemoteContainers{Containers: []core.RemoteContainer{}}, nil
}

func (k *remoteProbeKernel) RemoteListContainers(context.Context, string, string) (core.RemoteContainers, error) {
	return core.RemoteContainers{Containers: []core.RemoteContainer{}}, nil
}

// Nor does any test run this computer's Dev Container CLI: the test kernels over the real Core
// find none, and only remoteHostKernel builds, as its test says (remote_devcontainer_test.go).
func (k *testKernel) RemoteDevcontainerUp(context.Context, core.DevcontainerUpRequest, func(core.DevcontainerOutput)) (core.DevcontainerUp, error) {
	return core.DevcontainerUp{}, &core.Error{Command: "remote.devcontainerUp", Code: core.CodeRuntimeMissing, Message: "missing"}
}

func (k *remoteProbeKernel) RemoteDevcontainerUp(context.Context, core.DevcontainerUpRequest, func(core.DevcontainerOutput)) (core.DevcontainerUp, error) {
	return core.DevcontainerUp{}, &core.Error{Command: "remote.devcontainerUp", Code: core.CodeRuntimeMissing, Message: "missing"}
}

// remoteHostContainers stands in for the engines' CLIs: each engine lists its containers, and
// only remoteTestContainer connects on this computer and remoteTestHostContainer on a host, each
// connection asked for being recorded. Its zero value lists none, as Core answers on a computer
// without either engine.
type remoteHostContainers struct {
	// running are the containers each engine lists on this computer, and onHost those it lists
	// over a session (remote_host_containers_test.go); an engine without an entry has no CLI.
	// fail is the error an engine's listing ends with.
	running, onHost map[string][]core.RemoteContainer
	fail            map[string]error
	// listed are the engines listed and sessions the sessions they were listed over, in order.
	listed, sessions []string
	// requests are the connections asked for, in order, and hosts the hosts each went through:
	// the SSH host, wsl:distribution, or "" for this computer. preferences counts those that
	// carried the SSH preferences.
	requests    []core.ContainerConnection
	hosts       []string
	preferences int
	// refuse is the error the next connections end with; nil connects.
	refuse error
}

func (k *remoteHostKernel) RemoteListContainers(_ context.Context, engine, sessionID string) (core.RemoteContainers, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	c := &k.containers
	c.listed = append(c.listed, engine)
	c.sessions = append(c.sessions, sessionID)
	if err := c.fail[engine]; err != nil {
		return core.RemoteContainers{}, err
	}
	containers := c.running
	if sessionID != "" {
		containers = c.onHost
	}
	running, ok := containers[engine]
	return core.RemoteContainers{Available: ok, Containers: append([]core.RemoteContainer{}, running...)}, nil
}

// connect answers the connect request numbered n, which names a container. It runs under the
// kernel's lock.
func (c *remoteHostContainers) connect(n int, request core.RemoteConnectRequest) (core.RemoteConnectResult, error) {
	host, want := "", remoteTestContainer
	switch {
	case request.WSL != nil:
		host, want = "wsl:"+request.WSL.Distribution, remoteTestHostContainer
	case request.Connection != (core.SSHConnection{}):
		host, want = request.Connection.Host, remoteTestHostContainer
	}
	c.requests = append(c.requests, *request.Container)
	c.hosts = append(c.hosts, host)
	if request.Preferences != nil {
		c.preferences++
	}
	if c.refuse != nil {
		return core.RemoteConnectResult{}, c.refuse
	}
	if request.Container.Container != want || (request.WSL == nil && host != "" && host != remoteTestHost) {
		return core.RemoteConnectResult{Status: core.RemoteProbeUnreachable}, nil
	}
	session := &core.RemoteSession{ID: "session-" + strconv.Itoa(n), HostName: "3f2a9c1d", UserName: "app", HomeDirectory: remoteTestHome}
	return core.RemoteConnectResult{Status: core.RemoteProbeConnected, Session: session}, nil
}

// remoteTestContainerKey is the list's key of the Docker container remoteTestContainer.
var remoteTestContainerKey = core.ContainerEngineDocker + ":" + strings.Repeat("a", 64)

// remoteContainerHarness is remoteWorkspaceHarness on a computer running remoteTestContainer under
// Docker and remoteTestContainerGone under Podman, the window opened again so that it lists them.
func remoteContainerHarness(t *testing.T) (*harness, *remoteHostKernel, *treeRecordingLog) {
	t.Helper()
	h, k, _, logger := remoteWorkspaceHarness(t)
	k.set(func(k *remoteHostKernel) {
		k.containers.running = map[string][]core.RemoteContainer{
			core.ContainerEngineDocker: {{ID: strings.Repeat("a", 64), Name: remoteTestContainer, Image: remoteTestImage, Status: "Up 2 hours"}},
			core.ContainerEnginePodman: {{ID: strings.Repeat("b", 64), Name: remoteTestContainerGone, Image: "postgres:17", Status: "Up 5 minutes"}},
		}
	})
	h.app.closeRemote()
	h.app.openRemote(surfaceMenu)
	h.await("the containers", func() bool { return h.app.remote.containers.loaded && !h.app.remote.loading })
	h.settle()
	return h, k, logger
}

// The window lists the running containers under their own heading after the saved connections,
// and a container's page opens a folder in it as the user typed: Core is asked to enter it through
// its engine, by name and without the SSH preferences, and the workspace names the container.
// Nothing is saved for it, and neither the container, its image nor the user is logged.
func TestRemoteContainerOpensAFolderInAContainer(t *testing.T) {
	h, k, logger := remoteContainerHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	heading := i18n.Shared(lang, "desktop.remote.container.heading")
	if !h.shows(heading) || !h.shows(remoteTestContainer) || !h.shows(remoteTestContainerGone) {
		t.Fatal("the list does not show the containers' heading with the containers")
	}
	row := i18n.SharedFormat(lang, "desktop.remote.container.row", map[string]string{"engine": "Docker", "image": remoteTestImage})
	if !h.shows(row) {
		t.Fatal("the container's row does not name its engine and image")
	}
	if at := r.containerRow(remoteTestContainerKey); at <= r.rowOf(r.selected) {
		t.Fatalf("container row %d, saved row %d: the containers are not after the saved connections", at, r.rowOf(r.selected))
	}

	h.clickFront(remoteTestContainer)
	h.settle()
	if r.containers.selected == nil || r.containers.selected.key() != remoteTestContainerKey || r.selected != "" ||
		r.list.Selected() != r.containerRow(remoteTestContainerKey) {
		t.Fatal("choosing the container does not show its page")
	}
	about := i18n.SharedFormat(lang, "desktop.remote.container.about", map[string]string{"engine": "Docker"})
	if !h.showsWrapped(about) || !h.shows("docker:"+remoteTestContainer) {
		t.Fatal("the page does not say how the container opens")
	}
	r.containers.user.SetText("app")
	h.redraw()
	if !h.shows("docker:app@" + remoteTestContainer) {
		t.Fatal("the page does not name the user typed")
	}

	p := h.openBrowsedProject(t, h.connectAndBrowse(t))
	want := core.ContainerConnection{Engine: core.ContainerEngineDocker, Container: remoteTestContainer, User: "app"}
	if got := k.containers.requests; len(got) != 1 || got[0] != want || k.containers.preferences != 0 || !slices.Equal(k.containers.hosts, []string{""}) {
		t.Fatalf("asked for %d container connections, %d with SSH preferences; want the container by name as the user typed, on this computer", len(got), k.containers.preferences)
	}
	identity := "docker:app@" + remoteTestContainer
	anchor, _ := h.app.remoteAnchor()
	if want := remoteplaceholder.Root(anchor, identity, remoteTestHome+"/project"); p.root != want || p.remote.connectionID != identity {
		t.Fatal("the workspace is not placed under the container's identity")
	}
	if got, want := h.app.projectDisplayName(p), "project [Container: "+remoteTestContainer+"]"; got != want {
		t.Fatalf("title %q, want %q", got, want)
	}
	if status := remoteStatusText(lang, p.remote); !strings.HasPrefix(status, "Container: "+remoteTestContainer) || !h.remoteHostHasStatus(p.remote) {
		t.Fatalf("status %q does not name the container", status)
	}
	saved := savedRemoteConnections(t, h)
	if len(saved) != 1 || len(saved[0].RecentFolders) != 0 || saved[0].LastConnectedAt != 0 {
		t.Fatalf("%d saved connections: opening in a container changed the saved list", len(saved))
	}
	if countFailures(logger, "remote_remember_folder") != 0 {
		t.Fatal("remembering the folder was tried for a container")
	}
	actions := []string{"remote.connections.open", "remote.connection.new", "remote.connection.save", "remote.connections.open", "remote.container.select", "remote.connect", "remote.workspace.open"}
	if got := remoteActions(logger); !slices.Equal(got, actions) {
		t.Fatalf("performed %q, want %q", got, actions)
	}
	if event := loggedAny(t, logger, remoteTestContainer, remoteTestContainerGone, remoteTestImage, "app@", remoteTestHome); event != "" {
		t.Fatal("logged a container, its image, the user or a host path")
	}

	// Each opening of the window lists both engines on this computer, and a window over the
	// container shows it connected, whatever the user.
	h.app.openRemote(surfaceMenu)
	h.await("the containers", func() bool { return h.app.remote.containers.loaded })
	var listed, sessions []string
	k.set(func(k *remoteHostKernel) {
		listed, sessions = slices.Clone(k.containers.listed), slices.Clone(k.containers.sessions)
	})
	engines := []string{core.ContainerEngineDocker, core.ContainerEnginePodman}
	if !slices.Equal(listed, slices.Concat(engines, engines, engines)) || slices.ContainsFunc(sessions, func(s string) bool { return s != "" }) {
		t.Fatalf("listed %d times, want both engines on this computer at each of the 3 openings", len(listed))
	}
	if h.app.remoteContainerWindows(core.ContainerEngineDocker, remoteTestContainer) != 1 ||
		h.app.remoteContainerWindows(core.ContainerEnginePodman, remoteTestContainer) != 0 ||
		h.app.remoteContainerWindows(core.ContainerEngineDocker, remoteTestContainerGone) != 0 {
		t.Fatal("the windows open in the container are not counted by engine and name")
	}
	h.app.closeRemote()
	h.redraw()
	h.openRemoteHostChoices(t)
	h.clickFront(i18n.Shared(lang, "desktop.remote.hostSwitcher.chooseFolder"))
	h.await("another folder on the current container", func() bool { return r.browser != nil && !r.browser.loading })
	if r.browser.host.container == nil || *r.browser.host.container != want || r.containers.selected == nil ||
		r.containers.selected.Name != remoteTestContainer || r.containers.user.Text() != want.User {
		t.Fatal("choosing another folder lost the current container or its selected row/user")
	}
	h.app.closeRemote()
	h.settle()
}

// A container that is gone fails at the connection with the containers' own text and no OpenSSH
// hint, a refused user and a missing engine are explained, a search lists the saved connections
// only, and folding the heading hides the containers.
func TestRemoteContainerFailuresSearchAndFolding(t *testing.T) {
	h, k, _ := remoteContainerHarness(t)
	lang := h.app.language()
	r := &h.app.remote

	h.clickFront(remoteTestContainerGone)
	h.settle()
	h.clickFront(i18n.Shared(lang, "desktop.remote.connect"))
	h.await("the failed connection", func() bool { return r.steps != nil && r.steps.failed })
	h.settle()
	outcome := r.steps.outcome
	unreachable := i18n.Shared(lang, "desktop.remote.container.unreachable")
	if outcome.engine != core.ContainerEnginePodman || remoteFailureText(lang, outcome) != unreachable || remoteFailureHint(lang, outcome) != "" {
		t.Fatal("the failure does not read as a container's")
	}
	if !h.showsWrapped(unreachable) || h.showsWrapped(i18n.Shared(lang, "desktop.remote.probe.hint.unreachable")) {
		t.Fatal("the page does not show the container's failure alone")
	}
	if !h.shows("podman:" + remoteTestContainerGone) {
		t.Fatal("the steps do not name the container")
	}
	if !h.shows(i18n.Shared(lang, "desktop.remote.container.start")) || h.shows(i18n.Shared(lang, "desktop.remote.step.config")) ||
		h.shows(i18n.Shared(lang, "desktop.remote.step.authenticate")) || h.shows(i18n.Shared(lang, "desktop.remote.steps.editConnection")) {
		t.Fatal("the steps of a container list OpenSSH's, or offer a connection's form")
	}

	// Core refusing the user names the user, on the container's page.
	h.app.stopRemoteConnect()
	r.steps = nil
	k.set(func(k *remoteHostKernel) {
		k.containers.refuse = &core.Error{Command: "remote.connect", Code: core.CodeInvalidRequest, Message: "invalid", Details: `{"field":"user","reason":"invalid"}`}
	})
	r.containers.user.SetText("root;id")
	h.redraw()
	h.clickFront(i18n.Shared(lang, "desktop.remote.connect"))
	h.await("the refused user", func() bool { return r.connect == nil && r.err != "" })
	h.settle()
	if r.err != i18n.Shared(lang, "desktop.remote.container.userInvalid") || r.steps != nil || !h.shows(r.err) {
		t.Fatal("the refused user is not explained on the page")
	}

	// Without the engine's CLI, the failure names the engine to install.
	k.set(func(k *remoteHostKernel) {
		k.containers.refuse = &core.Error{Command: "remote.connect", Code: core.CodeRuntimeMissing, Message: "missing"}
	})
	r.containers.user.SetText("")
	h.redraw()
	h.clickFront(i18n.Shared(lang, "desktop.remote.connect"))
	h.await("the missing engine", func() bool { return r.steps != nil && r.steps.failed })
	h.settle()
	missing := i18n.SharedFormat(lang, "desktop.remote.container.missing", map[string]string{"engine": "Podman"})
	if remoteFailureText(lang, r.steps.outcome) != missing || !h.showsWrapped(missing) {
		t.Fatal("the missing engine is not named")
	}
	h.app.stopRemoteConnect()
	r.steps = nil

	// Choosing a saved connection leaves the container's page.
	h.clickFront(remoteTestHost)
	h.settle()
	if r.containers.selected != nil || r.entry(r.selected) == nil {
		t.Fatal("choosing the saved connection does not show it")
	}

	r.query.SetText(remoteTestHost)
	h.app.searchRemote()
	h.await("the search", func() bool { return r.found != nil })
	h.settle()
	if r.containerRow(remoteTestContainerKey) >= 0 || h.shows(remoteTestContainer) {
		t.Fatal("a search lists the containers")
	}
	h.app.clearRemoteSearch()
	h.settle()
	if r.containerRow(remoteTestContainerKey) < 0 {
		t.Fatal("clearing the search does not list the containers again")
	}
	h.app.toggleRemoteGroup(remoteContainerHeading)
	h.redraw()
	if r.containerRow(remoteTestContainerKey) >= 0 || !h.shows(i18n.Shared(lang, "desktop.remote.container.heading")) {
		t.Fatal("folding the containers' heading does not keep the heading alone")
	}
}

// An engine whose listing fails leaves out its containers alone, and the failure is logged
// without what the other engine found.
func TestRemoteContainersKeepTheOtherEngineWhenOneFails(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	k.set(func(k *remoteHostKernel) {
		k.containers.running = map[string][]core.RemoteContainer{
			core.ContainerEngineDocker: {{ID: strings.Repeat("a", 64), Name: remoteTestContainer, Image: remoteTestImage, Status: "Up 2 hours"}},
		}
		k.containers.fail = map[string]error{core.ContainerEnginePodman: &core.Error{Command: "remote.listContainers", Code: core.CodeTimedOut, Message: "timed out"}}
	})
	h.app.closeRemote()
	h.app.openRemote(surfaceMenu)
	h.await("the containers", func() bool { return h.app.remote.containers.loaded && !h.app.remote.loading })
	h.settle()
	r := &h.app.remote
	if r.containerRow(remoteTestContainerKey) < 0 || len(r.containers.list) != 1 || !h.shows(remoteTestContainer) {
		t.Fatal("the containers of the engine that answered are not listed")
	}
	if countFailures(logger, "remote_containers_list") != 1 {
		t.Fatal("the engine's failed listing is not logged once")
	}
	if event := loggedAny(t, logger, remoteTestContainer, remoteTestImage); event != "" {
		t.Fatal("logged a container or its image")
	}
}

// Without an engine, Core answers the lists as unavailable, and the window shows no containers'
// heading.
func TestRemoteContainersAbsentShowsNothing(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	r := &h.app.remote
	h.await("the containers", func() bool { return r.containers.loaded })
	h.settle()
	if k.count(func(k *remoteHostKernel) int { return len(k.containers.listed) }) != 2 {
		t.Fatal("the engines are not listed once each when the window opens")
	}
	if slices.ContainsFunc(r.rows, func(row remoteListRow) bool { return row.container != nil || row.group == remoteContainerHeading }) {
		t.Fatal("the list shows container rows without an engine")
	}
	if h.shows(i18n.Shared(h.app.language(), "desktop.remote.container.heading")) {
		t.Fatal("the window shows the containers' heading without an engine")
	}
}

// Runtime discovery is outside the unit test boundary; integration tests use the real Core.
func (k *testKernel) RemoteContainerRuntimes(context.Context) (core.ContainerRuntimes, error) {
	return core.ContainerRuntimes{}, nil
}
func (k *remoteProbeKernel) RemoteContainerRuntimes(context.Context) (core.ContainerRuntimes, error) {
	return core.ContainerRuntimes{}, nil
}
