package workbench

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
)

// remoteHostHasStatus checks the host selector's accessible state. Its visible name stays
// stable while the icon changes, and its tooltip/description keeps the full connection details.
func (h *harness) remoteHostHasStatus(r *remoteProject) bool {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == i18n.Shared(h.app.language(), "desktop.remote.status.label") && !hit.IsLabel {
			return hit.Value == remoteStatusText(h.app.language(), r) &&
				strings.Contains(hit.Description, r.host.address()) && strings.Contains(hit.Description, r.binding.RemoteRoot())
		}
	}
	return false
}

func (h *harness) openRemoteHostChoices(t *testing.T) {
	t.Helper()
	h.clickFront(i18n.Shared(h.app.language(), "desktop.remote.status.label"))
	h.await("the host dropdown's discovery", func() bool {
		r := &h.app.remote
		return r.hostsOnly && r.loaded && r.wsl.loaded && r.containers.loaded
	})
	h.settle()
}

// The selector lives before the project in the title bar and keeps exactly the same name and
// width through heartbeat failures and reconnection. Local workspaces have no host selector.
func TestRemoteHostSwitcherKeepsTheHostNameStable(t *testing.T) {
	h, _, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	label := i18n.Shared(h.app.language(), "desktop.remote.status.label")
	host := h.frontLabeled(label)
	project := h.frontLabeled(h.app.text.Title.ProjectMenu)
	if host.Y != project.Y || host.X+host.Width > project.X || host.Height != chromeIconButton {
		t.Fatalf("host %+v must be before project %+v in the title bar", host, project)
	}
	for _, link := range []remoteLink{remoteConnected, remoteUnresponsive, remoteReconnecting, remoteDisconnected} {
		p.remote.link = link
		h.redraw()
		if !h.remoteHostHasStatus(p.remote) || h.frontLabeled(label) != host || !h.shows(p.remote.name) {
			t.Fatalf("link %v changed the selector's name/bounds or lost its accessible status", link)
		}
		if h.shows(remoteStatusText(h.app.language(), p.remote)) {
			t.Fatalf("link %v appended status text to the visible host name", link)
		}
	}
	p.remote.link = remoteConnected
	h.app.closeProject()
	h.await("the remote project to close", func() bool { return h.app.project == nil })
	dir := t.TempDir()
	h.open(dir)
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == label && !hit.IsLabel {
			t.Fatal("a local workspace shows the remote host selector")
		}
	}
}

// Each host type starts the existing connection flow in one click and then asks for a folder.
// The current project/session survives both the choice and cancelling the folder window.
func TestRemoteHostSwitcherChoosesAHostBeforeItsFolder(t *testing.T) {
	for _, kind := range []string{"SSH", "WSL", "container"} {
		t.Run(kind, func(t *testing.T) {
			h, k, _, logger := remoteWorkspaceHarness(t)
			p := h.openRemoteTestProject(t)
			name := "Build account"
			var id string
			switch kind {
			case "SSH":
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				source, err := remoteconn.Read(ctx, k, h.store.Dir())
				if err != nil {
					t.Fatal(err)
				}
				_, id, _, err = source.Edit(ctx, k, core.RemoteConnectionEdit{Save: &core.RemoteConnectionSave{
					Name: name, Connection: core.SSHConnection{Host: remoteTestHost, User: "builder"},
				}})
				if err != nil {
					t.Fatal(err)
				}
			case "WSL":
				name, id = remoteTestWSL, (core.WSLConnection{Distribution: remoteTestWSL}).Identity()
				k.set(func(k *remoteHostKernel) {
					k.wsl.list = core.RemoteWSLDistributions{Available: true, Distributions: []string{name}}
				})
			case "container":
				name, id = remoteTestContainer, (core.ContainerConnection{Engine: core.ContainerEngineDocker, Container: remoteTestContainer}).Identity()
				k.set(func(k *remoteHostKernel) {
					k.containers.running = map[string][]core.RemoteContainer{
						core.ContainerEngineDocker: {{ID: strings.Repeat("a", 64), Name: name, Image: remoteTestImage}},
					}
				})
			}
			file := filepath.Join(h.store.Dir(), "remote", "connections.json")
			before, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			h.openRemoteHostChoices(t)
			if h.shows(i18n.Shared(h.app.language(), "desktop.remote.openFolder")) {
				t.Fatal("opening the dropdown also opened the connection window")
			}
			h.clickFront(name)
			h.await("the chosen host's folders", func() bool {
				r := &h.app.remote
				return !r.hostsOnly && r.browser != nil && !r.browser.loading
			})
			b := h.app.remote.browser
			if b.entryID != id || b.dir != remoteTestHome || h.app.project != p || p.remote.session != "session-1" {
				t.Fatalf("chose %q at %q; the requested host or original workspace changed", b.entryID, b.dir)
			}
			selected, _ := h.app.remote.connectTarget()
			if selected.ID != id {
				t.Fatalf("folder chooser selected host %q, want %q", selected.ID, id)
			}
			h.app.closeRemote()
			h.settle()
			if h.app.project != p || p.remote.closed || p.remote.menuOpen || p.remote.session != "session-1" {
				t.Fatal("cancelling the folder chooser closed the original workspace")
			}
			if k.count(func(k *remoteHostKernel) int {
				if slices.Contains(k.closed, b.session.ID) && !slices.Contains(k.closed, p.remote.session) {
					return 1
				}
				return 0
			}) != 1 {
				t.Fatal("cancelling did not release only the folder chooser's session")
			}
			after, err := os.ReadFile(file)
			if err != nil || string(before) != string(after) {
				t.Fatalf("choosing/cancelling changed the saved connections: %v", err)
			}
			if loggedAny(t, logger, name, remoteTestHome, "builder") != "" {
				t.Fatal("switching logged a host, user or path")
			}
			if kind == "SSH" {
				t.Cleanup(h.disposeTabs)
				h.openRemoteHostChoices(t)
				h.clickFront(name)
				h.await("the host's folder chooser again", func() bool {
					return h.app.remote.browser != nil && !h.app.remote.browser.loading
				})
				h.clickFront("project")
				h.clickFront(i18n.SharedFormat(h.app.language(), "desktop.remote.browse.open", map[string]string{"name": "project"}))
				h.await("the chosen host's project tab", func() bool {
					active := h.app.sessions.active
					return active != h.app && active.project != nil && active.project.remote != nil &&
						active.project.tree.root != nil && active.project.tree.root.listed && !active.project.remote.beating
				})
				active := h.app.sessions.active
				if active.project.remote.connectionID != id || p.remote.closed || h.app.project != p || len(h.app.sessions.list) != 2 {
					t.Fatal("opening the chosen folder did not activate the new host and preserve the previous project")
				}
			}
		})
	}
}

// A failed connection keeps the original workspace available; opening the project menu also
// dismisses the host dropdown and invalidates its in-flight discovery results.
func TestRemoteHostSwitcherKeepsTheProjectOnFailure(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	h.openRemoteHostChoices(t)
	h.app.openProjectMenu()
	h.redraw()
	if p.remote.menuOpen || h.app.remote.open || h.app.remote.hostsOnly {
		t.Fatal("opening the project menu left the host dropdown/discovery active")
	}
	h.app.title.projectOpen = false
	h.redraw()
	h.openRemoteHostChoices(t)
	k.set(func(k *remoteHostKernel) { k.refuse = core.RemoteProbeUnreachable })
	h.clickFront(p.remote.name)
	h.await("the failed connection", func() bool {
		steps := h.app.remote.steps
		return steps != nil && steps.failed && h.app.remote.connect == nil
	})
	if h.app.project != p || p.remote.closed || p.remote.session != "session-1" || h.app.remote.browser != nil {
		t.Fatal("a failed host choice replaced the project or opened a folder chooser")
	}
	h.app.closeRemote()
	h.settle()
	if slices.Contains(k.closed, "session-1") {
		t.Fatal("a failed host choice closed the original session")
	}
}

// heldRemoteConnections delays only the saved-list read; the real Core still reads and parses
// it once released. Discovery may finish first, as it can on a slow preference volume.
type heldRemoteConnections struct {
	Kernel
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

func (k *heldRemoteConnections) RemoteConnections(ctx context.Context, document *string) (core.RemoteConnectionsState, error) {
	k.once.Do(func() { close(k.started) })
	select {
	case <-k.release:
		return k.Kernel.RemoteConnections(ctx, document)
	case <-ctx.Done():
		return core.RemoteConnectionsState{}, ctx.Err()
	}
}

// Discovery finishes, a WSL host is chosen, and only then the saved SSH list arrives. That late
// answer must not select the first SSH entry and cancel or relabel the chosen host's connection.
func TestRemoteHostSwitcherPreservesAChoiceDuringLoading(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	p := h.openRemoteTestProject(t)
	k.set(func(k *remoteHostKernel) {
		k.wsl.list = core.RemoteWSLDistributions{Available: true, Distributions: []string{remoteTestWSL}}
	})
	held := &heldRemoteConnections{Kernel: k, started: make(chan struct{}), release: make(chan struct{})}
	h.app.kernel = held
	var released sync.Once
	release := func() { released.Do(func() { close(held.release) }) }
	t.Cleanup(release)
	h.app.openRemoteHostMenu()
	select {
	case <-held.started:
	case <-time.After(2 * time.Second):
		t.Fatal("the saved-list read did not start")
	}
	h.await("discovery before the saved-list read completes", func() bool { return h.app.remote.wsl.loaded })
	point := center(h.frontLabeled(remoteTestWSL))
	if err := h.driver.Click(point.X, point.Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		t.Fatal(err)
	}
	release()
	h.await("the delayed saved-list read", func() bool { return h.app.remote.loaded })
	h.settle()
	h.settle()
	b := h.app.remote.browser
	if b == nil || b.host.wsl == nil || b.host.wsl.Distribution != remoteTestWSL || h.app.remote.wsl.selected != remoteTestWSL {
		t.Fatal("the late SSH list replaced or cancelled the chosen WSL host")
	}
	if h.app.project != p || p.remote.closed || p.remote.session != "session-1" {
		t.Fatal("loading the chosen host changed the original workspace")
	}
	h.app.closeRemote()
	h.settle()
}

// heldRemoteDiscovery keeps discovery in flight until its owner cancels it. The release
// channel also lets teardown finish both calls after an assertion failure.
type heldRemoteDiscovery struct {
	Kernel
	started, done       chan struct{}
	wslStarted, wslDone chan struct{}
	release             chan struct{}
	holdWSL             bool
}

func (k *heldRemoteDiscovery) RemoteContainerRuntimes(ctx context.Context) (core.ContainerRuntimes, error) {
	close(k.started)
	defer close(k.done)
	select {
	case <-ctx.Done():
		return core.ContainerRuntimes{}, ctx.Err()
	case <-k.release:
		return core.ContainerRuntimes{}, nil
	}
}

func (k *heldRemoteDiscovery) RemoteListWSLDistributions(ctx context.Context) (core.RemoteWSLDistributions, error) {
	if !k.holdWSL {
		return k.Kernel.RemoteListWSLDistributions(ctx)
	}
	close(k.wslStarted)
	defer close(k.wslDone)
	select {
	case <-ctx.Done():
		return core.RemoteWSLDistributions{}, ctx.Err()
	case <-k.release:
		return core.RemoteWSLDistributions{}, nil
	}
}

// Both the full window's container refresh and the host menu's discovery need an owner.
// Closing either surface cancels its work without closing the existing remote workspace.
func TestRemoteHostSwitcherCancelsRuntimeDiscovery(t *testing.T) {
	for _, hostsOnly := range []bool{false, true} {
		name := "window"
		if hostsOnly {
			name = "host-menu"
		}
		t.Run(name, func(t *testing.T) {
			h, k, _, _ := remoteWorkspaceHarness(t)
			p := h.openRemoteTestProject(t)
			held := &heldRemoteDiscovery{
				Kernel: k, started: make(chan struct{}), done: make(chan struct{}),
				wslStarted: make(chan struct{}), wslDone: make(chan struct{}),
				release: make(chan struct{}), holdWSL: hostsOnly,
			}
			t.Cleanup(func() { close(held.release) })
			h.app.kernel = held
			awaitSignal := func(signal <-chan struct{}, what string) {
				t.Helper()
				select {
				case <-signal:
				case <-time.After(2 * time.Second):
					t.Fatalf("%s did not finish", what)
				}
			}
			if hostsOnly {
				h.app.openRemoteHostMenu()
			} else {
				h.app.openRemote(surfaceMenu)
			}
			awaitSignal(held.started, "starting runtime discovery")
			if hostsOnly {
				awaitSignal(held.wslStarted, "starting WSL discovery")
				h.app.closeRemoteHostMenu()
			} else {
				h.app.closeRemote()
			}
			awaitSignal(held.done, "cancelling runtime discovery")
			if hostsOnly {
				awaitSignal(held.wslDone, "cancelling WSL discovery")
			}
			h.settle()
			if h.app.remote.open || h.app.remote.containers.discovered || h.app.project != p || p.remote.closed {
				t.Fatal("closing discovery applied a stale result or changed the existing workspace")
			}
		})
	}
}
