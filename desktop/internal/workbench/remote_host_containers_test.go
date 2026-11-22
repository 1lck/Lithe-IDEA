package workbench

import (
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

// The running containers of the saved host remoteTestHost: remoteTestHostContainer runs under
// Docker and connects, and remoteTestContainerGone runs under Podman and is gone by the time it is
// entered.
const (
	remoteTestHostContainer = "api-server"
	remoteTestHostImage     = "golang:1.26-bookworm"
)

// remoteHostContainersHarness is remoteContainerHarness whose saved host also runs containers,
// connected and browsing the host's home folder, the host's containers listed in place of its
// folders.
func remoteHostContainersHarness(t *testing.T) (*harness, *remoteHostKernel, *treeRecordingLog, *remoteBrowser) {
	t.Helper()
	h, k, logger := remoteContainerHarness(t)
	k.set(func(k *remoteHostKernel) {
		k.containers.onHost = map[string][]core.RemoteContainer{
			core.ContainerEngineDocker: {{ID: strings.Repeat("c", 64), Name: remoteTestHostContainer, Image: remoteTestHostImage, Status: "Up 3 days"}},
			core.ContainerEnginePodman: {{ID: strings.Repeat("d", 64), Name: remoteTestContainerGone, Image: "postgres:17", Status: "Up 1 hour"}},
		}
	})
	if h.app.remote.entry(h.app.remote.selected) == nil {
		t.Fatal("the saved connection is not selected")
	}
	b := h.connectAndBrowse(t)
	k.set(func(k *remoteHostKernel) { k.containers.listed, k.containers.sessions = nil, nil })
	h.clickFront(i18n.Shared(h.app.language(), "desktop.remote.hostContainers.show"))
	h.await("the host's containers", func() bool { return b.containers != nil && !b.containers.loading })
	h.settle()
	return h, k, logger, b
}

// On a saved SSH host, the folder browser lists the host's running containers over its own session,
// both engines, and Enter Container ends that session and connects to the host and on into the
// container as the user typed, logging in as the host does: the workspace's identity is the
// connection's and the container's, it is named after both, and nothing is remembered with the
// saved connection. Neither the host, the container, its image, the user nor a host path is logged.
func TestRemoteHostContainersOpenAFolderInAContainerOnTheHost(t *testing.T) {
	h, k, logger, b := remoteHostContainersHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	entryID, session := b.entryID, b.session.ID
	var listed, sessions []string
	k.set(func(k *remoteHostKernel) {
		listed, sessions = slices.Clone(k.containers.listed), slices.Clone(k.containers.sessions)
	})
	if !slices.Equal(listed, []string{core.ContainerEngineDocker, core.ContainerEnginePodman}) || !slices.Equal(sessions, []string{session, session}) {
		t.Fatalf("listed %d times, want both engines over the browser's session", len(listed))
	}
	if len(b.containers.list) != 2 || b.containers.list[0].Name != remoteTestHostContainer || b.containers.engines != 2 {
		t.Fatal("the browser does not list the host's containers, Docker's first")
	}
	row := i18n.SharedFormat(lang, "desktop.remote.container.row", map[string]string{"engine": "Docker", "image": remoteTestHostImage})
	title := i18n.SharedFormat(lang, "desktop.remote.hostContainers.title", map[string]string{"name": b.name})
	if !h.shows(title) || !h.shows(remoteTestHostContainer) || !h.shows(row) || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.hostContainers.about")) {
		t.Fatal("the browser does not show the host's containers")
	}
	enter := i18n.Shared(lang, "desktop.remote.hostContainers.enter")
	enabled := false
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == enter && !hit.IsLabel {
			enabled = !hit.Disabled
		}
	}
	if enabled || b.containers.selectedContainer() != nil {
		t.Fatal("Enter Container is enabled with no container selected")
	}

	b.containers.user.SetText("app")
	b.containers.rows.Select(0)
	h.redraw()
	h.clickFront(enter)
	h.await("the container's folders", func() bool {
		next := r.browser
		return next != nil && next != b && !next.loading
	})
	h.settle()
	want := core.ContainerConnection{Engine: core.ContainerEngineDocker, Container: remoteTestHostContainer, User: "app"}
	var closed []string
	var requests []core.ContainerConnection
	var hosts []string
	k.set(func(k *remoteHostKernel) {
		closed, requests, hosts = slices.Clone(k.closed), slices.Clone(k.containers.requests), slices.Clone(k.containers.hosts)
	})
	if !slices.Contains(closed, session) {
		t.Fatal("entering the container does not end the browser's session")
	}
	// The harness keeps no settings, so no connection carries the preferences; that a container on
	// an SSH host is connected with them is remoteHost.overSSH's (TestRemoteHostOfAContainer).
	if len(requests) != 1 || requests[0] != want || !slices.Equal(hosts, []string{remoteTestHost}) || !r.browser.host.hosted() || !r.browser.host.overSSH() {
		t.Fatalf("asked for %d container connections; want the container on the host as the user typed", len(requests))
	}
	if h.shows(i18n.Shared(lang, "desktop.remote.hostContainers.show")) {
		t.Fatal("a container's browser offers the containers of a host")
	}

	name := i18n.SharedFormat(lang, "desktop.remote.hostContainers.name", map[string]string{"container": remoteTestHostContainer, "host": b.name})
	p := h.openBrowsedProject(t, r.browser)
	identity := entryID + "/docker:app@" + remoteTestHostContainer
	anchor, _ := h.app.remoteAnchor()
	if want := remoteplaceholder.Root(anchor, identity, remoteTestHome+"/project"); p.root != want || p.remote.connectionID != identity {
		t.Fatal("the workspace is not placed under the connection's and the container's identity")
	}
	if got, want := h.app.projectDisplayName(p), "project [Container: "+name+"]"; got != want {
		t.Fatalf("title %q, want %q", got, want)
	}
	saved := savedRemoteConnections(t, h)
	if len(saved) != 1 || len(saved[0].RecentFolders) != 0 {
		t.Fatalf("%d saved connections: opening in a container on the host remembered the folder", len(saved))
	}
	if countFailures(logger, "remote_remember_folder") != 0 {
		t.Fatal("remembering the folder was tried for a container on the host")
	}
	actions := []string{
		"remote.connections.open", "remote.connection.new", "remote.connection.save", "remote.connections.open",
		"remote.connect", "remote.browse.containers", "remote.browse.container.enter", "remote.connect", "remote.workspace.open",
	}
	if got := remoteActions(logger); !slices.Equal(got, actions) {
		t.Fatalf("performed %q, want %q", got, actions)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHostContainer, remoteTestContainerGone, remoteTestHostImage, "app@", remoteTestHome); event != "" {
		t.Fatal("logged the host, a container, its image, the user or a host path")
	}
}

// A container on the host that is gone fails with the text of a container on a host, which names
// its engine, without OpenSSH's hint or the connection's form, and Retry enters the same container
// on the host again. Back to Folders shows the host's folders.
func TestRemoteHostContainerFailureRetriesTheContainer(t *testing.T) {
	h, k, _, b := remoteHostContainersHarness(t)
	lang := h.app.language()
	r := &h.app.remote

	h.clickFront(i18n.Shared(lang, "desktop.remote.hostContainers.back"))
	h.settle()
	if b.containers != nil || !h.shows("project") {
		t.Fatal("Back to Folders does not show the host's folders")
	}
	h.clickFront(i18n.Shared(lang, "desktop.remote.hostContainers.show"))
	h.await("the host's containers", func() bool { return b.containers != nil && !b.containers.loading })
	h.settle()

	b.containers.rows.Select(1)
	h.redraw()
	h.clickFront(i18n.Shared(lang, "desktop.remote.hostContainers.enter"))
	h.await("the failed connection", func() bool { return r.steps != nil && r.steps.failed })
	h.settle()
	outcome := r.steps.outcome
	text := i18n.SharedFormat(lang, "desktop.remote.container.hostUnreachable", map[string]string{"engine": "Podman"})
	if !outcome.hosted || remoteFailureText(lang, outcome) != text || remoteFailureHint(lang, outcome) != "" {
		t.Fatal("the failure does not read as a container's on a host")
	}
	if !h.showsWrapped(text) || h.shows(i18n.Shared(lang, "desktop.remote.steps.editConnection")) {
		t.Fatal("the page does not show the failure alone, or offers the connection's form")
	}
	if address := r.steps.host.address(); !strings.HasSuffix(address, " › podman:"+remoteTestContainerGone) || !h.shows(address) {
		t.Fatal("the steps do not name the host and the container")
	}

	h.clickFront(i18n.Shared(lang, "desktop.remote.steps.retry"))
	h.await("the second failed connection", func() bool {
		return r.steps != nil && r.steps.failed && k.count(func(k *remoteHostKernel) int { return len(k.containers.requests) }) == 2
	})
	var requests []core.ContainerConnection
	var hosts []string
	k.set(func(k *remoteHostKernel) {
		requests, hosts = slices.Clone(k.containers.requests), slices.Clone(k.containers.hosts)
	})
	gone := core.ContainerConnection{Engine: core.ContainerEnginePodman, Container: remoteTestContainerGone}
	if !slices.Equal(requests, []core.ContainerConnection{gone, gone}) || !slices.Equal(hosts, []string{remoteTestHost, remoteTestHost}) {
		t.Fatalf("asked for %d container connections; Retry does not enter the same container on the host", len(requests))
	}
}

// A container on an SSH host or a WSL distribution logs in as its host does, is never a saved
// connection, and is named after its host and itself; one of this computer goes through no host.
func TestRemoteHostOfAContainer(t *testing.T) {
	ssh := core.SSHConnection{Host: remoteTestHost, User: "dev"}
	wsl := &core.WSLConnection{Distribution: "Ubuntu-24.04"}
	container := &core.ContainerConnection{Engine: core.ContainerEngineDocker, Container: remoteTestHostContainer}
	cases := []struct {
		name                   string
		host                   remoteHost
		hosted, overSSH, saved bool
	}{
		{"ssh", remoteHost{ssh: ssh}, false, true, true},
		{"wsl", remoteHost{wsl: wsl}, false, false, false},
		{"container", remoteHost{container: container}, false, false, false},
		{"ssh container", remoteHost{ssh: ssh, container: container}, true, true, false},
		{"wsl container", remoteHost{wsl: wsl, container: container}, true, false, false},
	}
	for _, tc := range cases {
		h := tc.host
		if h.hosted() != tc.hosted || h.overSSH() != tc.overSSH || h.saved() != tc.saved {
			t.Fatalf("%s: hosted %v, overSSH %v, saved %v", tc.name, h.hosted(), h.overSSH(), h.saved())
		}
		request := h.request(nil, "0.0.0-test")
		if (request.WSL != nil) != (h.wsl != nil) || (request.Container != nil) != (h.container != nil) ||
			(h.wsl == nil && request.Connection != h.ssh) || (h.wsl != nil && request.Connection != (core.SSHConnection{})) {
			t.Fatalf("%s: the request does not carry the host and the container", tc.name)
		}
		if h.hosted() && !strings.HasSuffix(h.address(), " › "+container.Identity()) {
			t.Fatalf("%s: the address does not name the container after its host", tc.name)
		}
	}
	if (remoteHost{container: container}).address() != container.Identity() {
		t.Fatal("a container of this computer is not named by its identity alone")
	}
}
