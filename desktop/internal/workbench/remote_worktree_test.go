package workbench

import (
	"context"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

// remoteTestFeature is the host folder of the host repository's linked worktree.
const remoteTestFeature = remoteTestHome + "/project-feature"

// remoteWorktreeCreation is one worktree Core was asked to create on the host: the session the
// request carried, the repository's path and the creation.
type remoteWorktreeCreation struct {
	session  string
	root     string
	creation core.GitWorktreeCreation
}

// hostWorktrees lists the host repository's worktrees as Core names them in the workspace whose
// local root is root: the repository's folder (remoteTestFolder) first, then the linked ones.
func (k *remoteHostKernel) hostWorktrees(ctx context.Context, root string, counted bool) []core.GitWorktree {
	remoteRoot := core.RemoteWorkspaceOf(ctx).RemoteRoot()
	k.mu.Lock()
	hosts := append([]string{remoteTestFolder}, k.git.worktrees...)
	k.mu.Unlock()
	list := make([]core.GitWorktree, 0, len(hosts))
	for i, host := range hosts {
		local, ok := remoteplaceholder.LocalPath(root, remoteRoot, host)
		if !ok {
			continue
		}
		w := core.GitWorktree{Path: local, Head: "0123456789abcdef", Branch: "refs/heads/" + filepath.Base(host), IsPrimary: i == 0, IsCurrent: host == remoteRoot, Status: core.GitWorktreeAvailable}
		if w.IsCurrent {
			w.Status = core.GitWorktreeCurrent
		}
		if counted {
			none := 0
			w.Changes = &none
		}
		w.Actions.Remove.Allowed = !w.IsPrimary && !w.IsCurrent
		w.Actions.Lock.Allowed = !w.IsPrimary
		list = append(list, w)
	}
	return list
}

func (k *remoteHostKernel) GitWorktrees(ctx context.Context, root string) ([]core.GitWorktree, error) {
	return onHost(ctx, k, "git.worktrees", func() ([]core.GitWorktree, error) { return k.Client.GitWorktrees(ctx, root) },
		func(string) ([]core.GitWorktree, error) { return k.hostWorktrees(ctx, root, false), nil })
}

func (k *remoteHostKernel) GitWorktreesWithChanges(ctx context.Context, root string) ([]core.GitWorktree, error) {
	return onHost(ctx, k, "git.worktrees", func() ([]core.GitWorktree, error) { return k.Client.GitWorktreesWithChanges(ctx, root) },
		func(string) ([]core.GitWorktree, error) { return k.hostWorktrees(ctx, root, true), nil })
}

// GitCreateWorktree records the creation and lists the checkout from then on at the host path
// its destination names, as Core maps it.
func (k *remoteHostKernel) GitCreateWorktree(ctx context.Context, root string, creation core.GitWorktreeCreation) error {
	_, err := onHost(ctx, k, "git.write", func() (struct{}, error) { return struct{}{}, k.Client.GitCreateWorktree(ctx, root, creation) },
		func(string) (struct{}, error) {
			binding := core.RemoteWorkspaceOf(ctx)
			k.mu.Lock()
			defer k.mu.Unlock()
			k.git.creations = append(k.git.creations, remoteWorktreeCreation{session: binding.SessionID(), root: root, creation: creation})
			if host, ok := remoteplaceholder.HostPath(root, binding.RemoteRoot(), creation.Destination); ok {
				k.git.worktrees = append(k.git.worktrees, host)
			}
			return struct{}{}, nil
		})
	return err
}

// worktreeCreations is a copy of the creations Core was asked for.
func (k *remoteHostKernel) worktreeCreations() []remoteWorktreeCreation {
	k.mu.Lock()
	defer k.mu.Unlock()
	return slices.Clone(k.git.creations)
}

// openRemoteWorktrees opens the trusted remote test project with a linked worktree on the host
// and shows the Worktrees tab of the Git tool window until its worktrees were read.
func (h *harness) openRemoteWorktrees(t *testing.T, k *remoteHostKernel) (*project, *worktreeState) {
	t.Helper()
	k.trustAtHost(core.WorkspaceTrusted, ".")
	k.set(func(k *remoteHostKernel) {
		k.git.trust[remoteTestFeature] = core.WorkspaceDistrusted
		k.git.worktrees = []string{remoteTestFeature}
		k.git.references = core.GitReferences{References: []core.GitReference{{FullName: "refs/heads/main", ShortName: "main", Kind: "local", IsCurrent: true}}}
	})
	p := h.openRemoteTestProject(t)
	h.awaitRemoteGit(p)
	h.app.layout.gitTab = gitTabWorktrees
	h.app.invalidator.Invalidate()
	h.settle()
	w := &p.worktrees
	if !w.started {
		h.click(center(h.button(itemGit)))
		h.settle()
	}
	h.await("the host's worktrees", func() bool { return w.loaded && w.countsKnown && len(w.list) == 2 })
	return p, w
}

// A remote workspace lists the host repository's worktrees by their host paths, and opening the
// linked one connects again over the workspace's connection and opens its folder in a tab of its
// own over the new session. Opening it again shows that tab without connecting. Neither the host
// nor its paths are logged.
func TestRemoteWorktreeOpensOverASessionOfItsOwn(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	t.Cleanup(h.disposeTabs)
	p, _ := h.openRemoteWorktrees(t, k)
	linked, _ := remoteplaceholder.LocalPath(p.root, remoteTestFolder, remoteTestFeature)
	h.selectWorktreeAt(t, linked)
	if !h.shows(remoteTestFeature) {
		t.Fatal("the worktree's details do not show its host folder")
	}

	h.app.openWorktree(linked)
	var second *App
	h.await("the worktree's tab", func() bool {
		second = h.app.sessions.active
		q := second.project
		return second != h.app && q != nil && q.remote != nil && !q.remote.beating && q.tree.root != nil && q.tree.root.listed
	})
	h.settleTabs()
	entry := savedRemoteConnections(t, h)[0]
	anchor, _ := h.app.remoteAnchor()
	q := second.project
	if q.root != remoteplaceholder.Root(anchor, entry.ID, remoteTestFeature) || q.remote.session != "session-2" || p.remote.session != "session-1" {
		t.Fatalf("the worktree opened over session %q, want its folder over a session of its own", q.remote.session)
	}
	if got := k.count(func(k *remoteHostKernel) int { return k.connects }); got != 2 || h.app.remote.open {
		t.Fatalf("connected %d times, window open = %v; want one connection for the worktree", got, h.app.remote.open)
	}

	h.app.sessions.activate(h.app)
	h.app.openWorktree(linked)
	h.settleTabs()
	if h.app.sessions.active != second || h.app.remote.open || k.count(func(k *remoteHostKernel) int { return k.connects }) != 2 {
		t.Fatal("opening the open worktree again did not show its tab")
	}
	if got := remoteActions(logger); len(got) == 0 || got[len(got)-1] != "remote.connect" || slices.Index(got, "remote.connect") == len(got)-1 {
		t.Fatalf("performed %q, want the worktree's connection after the workspace's", got)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A worktree whose connection was deleted since the workspace opened is not opened: the
// connection window says why. A path that names no host folder reads the list again.
func TestRemoteWorktreeOfADeletedConnectionSaysSo(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemoteTestProject(t)

	h.app.openWorktree(filepath.Dir(p.root))
	h.settle()
	if !rejected(logger, "git_worktree_open", "not_host_path") || h.app.remote.open {
		t.Fatal("a path that names no host folder was not refused")
	}

	linked, _ := remoteplaceholder.LocalPath(p.root, remoteTestFolder, remoteTestFeature)
	p.remote.connectionID = "deleted"
	h.app.openWorktree(linked)
	removed := i18n.Shared(lang, "desktop.remote.worktree.connectionRemoved")
	h.await("the connection window's list", func() bool { return h.app.remote.open && h.app.remote.loaded })
	h.settle()
	if h.app.remote.err != removed || !h.showsWrapped(removed) {
		t.Fatal("the connection window does not say the connection was deleted")
	}
	if !rejected(logger, "git_worktree_open", "connection_removed") || k.count(func(k *remoteHostKernel) int { return k.connects }) != 1 {
		t.Fatal("the worktree of a deleted connection was connected to")
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// Reopening a container folder preserves every transport hop, including the outer SSH or WSL
// host. The saved SSH entry's composite container identity is not itself a saved entry.
func TestRemoteWorktreePreservesContainerHops(t *testing.T) {
	for _, via := range []string{"local", "ssh", "wsl", "ssh-removed"} {
		t.Run(via, func(t *testing.T) {
			h, k, _, _ := remoteWorkspaceHarness(t)
			t.Cleanup(h.disposeTabs)
			p := h.openRemoteTestProject(t)
			k.set(func(k *remoteHostKernel) { k.git.trust[remoteTestFeature] = core.WorkspaceDistrusted })
			container := &core.ContainerConnection{Engine: core.ContainerEngineDocker, Container: remoteTestContainer, User: "app"}
			host := remoteHost{container: container}
			switch via {
			case "ssh", "ssh-removed":
				host.ssh = p.remote.host.ssh
				container.Container = remoteTestHostContainer
			case "wsl":
				host.wsl = &core.WSLConnection{Distribution: "Ubuntu", User: "dev"}
				container.Container = remoteTestHostContainer
			}
			p.remote.host = host
			switch via {
			case "ssh", "ssh-removed":
				p.remote.connectionID += "/" + container.Identity()
			case "wsl":
				p.remote.connectionID = host.wsl.Identity() + "/" + container.Identity()
			default:
				p.remote.connectionID = container.Identity()
			}
			if via == "ssh-removed" {
				p.remote.connectionID = "deleted/" + container.Identity()
			}
			h.app.openRemoteHostFolder(p, remoteTestFeature)
			if via == "ssh-removed" {
				h.await("the connection window's list", func() bool { return h.app.remote.open && h.app.remote.loaded })
				h.settle()
				if h.app.remote.err != i18n.Shared(h.app.language(), "desktop.remote.worktree.connectionRemoved") || len(k.containers.requests) != 0 {
					t.Fatal("reopening used a container's deleted SSH connection")
				}
				return
			}
			h.await("the container worktree's tab", func() bool {
				active := h.app.sessions.active
				return active != h.app && active.project != nil && active.project.remote != nil
			})
			k.mu.Lock()
			defer k.mu.Unlock()
			if len(k.containers.requests) != 1 || k.containers.requests[0] != *container {
				t.Fatal("reopening did not enter the original container")
			}
			want := ""
			if via == "ssh" {
				want = remoteTestHost
			} else if via == "wsl" {
				want = "wsl:Ubuntu"
			}
			if k.containers.hosts[0] != want {
				t.Fatal("reopening discarded the container's outer host")
			}
		})
	}
}

// The create dialog of a remote workspace shows Core's suggestion beside the repository as a host
// path and says the path is the host's. A host path typed elsewhere stays as typed, and Create
// sends the path that names it over the workspace's session, then selects the new worktree.
func TestRemoteWorktreeCreatesTheHostFolder(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p, w := h.openRemoteWorktrees(t, k)
	text := &h.app.text.Worktrees

	h.clickNamed(text.New)
	h.await("the host's references", func() bool { return w.create.refsLoaded })
	w.create.name.SetText("topic")
	h.app.invalidator.Invalidate()
	h.settle()
	if got, want := w.create.destination.Text(), remoteTestHome+"/project-topic"; got != want || w.create.suggested != want {
		t.Fatalf("destination = %q, want the host folder beside the repository %q", got, want)
	}
	if !h.showsWrapped(i18n.Shared(lang, "desktop.remote.worktree.destination")) {
		t.Fatal("the dialog does not say the path is the host's")
	}

	typed := "/srv/checkouts/topic/"
	w.create.destination.SetText(typed)
	h.app.invalidator.Invalidate()
	h.settle()
	if got := w.create.destination.Text(); got != typed || !w.create.result.Ready {
		t.Fatalf("destination = %q, ready = %v; want the typed host path kept", got, w.create.result.Ready)
	}
	h.clickNamed(text.Create)
	h.awaitWorktreeWrite("the creation", w, func() bool { return len(w.list) == 3 })
	named, _ := remoteplaceholder.HostNamedPath(p.root, "/srv/checkouts/topic")
	created := k.worktreeCreations()
	if len(created) != 1 || created[0].session != "session-1" || created[0].root != p.root || created[0].creation.Destination != named || created[0].creation.Name != "topic" {
		t.Fatalf("%d creations, want the named host folder over the workspace's session", len(created))
	}
	if local, _ := remoteplaceholder.LocalPath(p.root, remoteTestFolder, "/srv/checkouts/topic"); w.selected != local {
		t.Fatal("the new worktree is not selected")
	}
	if got := k.count(func(k *remoteHostKernel) int { return k.connects }); got != 1 {
		t.Fatalf("connected %d times; staying in the workspace connects no more", got)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome, "/srv/checkouts"); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}
