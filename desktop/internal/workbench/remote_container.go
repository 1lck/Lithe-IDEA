package workbench

import (
	"context"
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Remote Development window also opens the running Docker and Podman containers of this
// computer as remote workspaces (#2231, the first step of Dev Containers). Core lists them each
// time the window opens (remote.listContainers, once per engine, which answers unavailable
// without the engine's CLI), and the list shows them under their own heading after the WSL
// distributions, while no search is typed: a search finds saved connections only.
//
// Nothing about a container is saved. It connects through the engine's exec, as the user typed on
// its page or the image's default user, and asks nothing, so no authentication dialog opens. Core
// only enters the running container: it never starts, creates or changes it, mounts no folder and
// asks for no more rights than the engine CLI has (S32). The rest is the SSH path: the steps, the
// folder chosen in the container, the trust decision, which names the container, the workspace
// and its reconnection, which enters the container of the same name again. Its folders are not
// remembered, since the saved list holds SSH connections only.
//
// Neither the container, its image nor the user is logged; the engine's own words are shown under
// a failed connection and never logged.

const (
	// remoteContainerHeading is the list's group of the containers' heading. No saved group can
	// have it, since Core refuses control characters in one.
	remoteContainerHeading = "\x00containers"
	// remoteContainerTimeout bounds listing the containers of both engines. Core bounds each
	// engine's CLI at 15 seconds, the time a first call may take to start the engine's service.
	remoteContainerTimeout = 110 * time.Second
)

// remoteContainerEngines are the engines the window lists, in the list's order.
var remoteContainerEngines = []string{core.ContainerEngineDocker, core.ContainerEnginePodman}

// remoteListedContainer is a running container of engine on this computer.
type remoteListedContainer struct {
	runtime *core.ContainerRuntimeTarget
	engine  string
	core.RemoteContainer
}

// key tells the containers apart in the list: their engine and full id.
func (c remoteListedContainer) key() string {
	if c.runtime != nil {
		return c.engine + ":" + c.runtime.WSL + ":" + c.runtime.Context + ":" + c.ID
	}
	return c.engine + ":" + c.ID
}

// remoteContainers is the window's running containers.
type remoteContainers struct {
	// loaded is set once Core answered for every engine; list is what it found, Docker's
	// containers before Podman's.
	loaded      bool
	discovering bool
	discovered  bool
	cancel      context.CancelFunc
	loads       uint64
	runtimes    core.ContainerRuntimes
	list        []remoteListedContainer
	// selected is the container the page shows, nil while it shows anything else.
	selected *remoteListedContainer
	// user is the page's user inside the container; empty is the image's default user.
	user ui.Field
}

// connection is the selected container as the page connects to it: by name, so that a container
// created again under the same name is entered again. The user is passed as typed, and Core trims
// it.
func (c *remoteContainers) connection() core.ContainerConnection {
	connection := core.ContainerConnection{Engine: c.selected.engine, Container: c.selected.Name, User: c.user.Text()}
	if c.selected.runtime != nil {
		connection.Context = c.selected.runtime.Context
	}
	return connection
}

// remoteContainerEngineName is engine as the window names it: Docker or Podman.
func remoteContainerEngineName(language i18n.Language, engine string) string {
	if engine == core.ContainerEnginePodman {
		return i18n.Shared(language, "desktop.remote.container.podman")
	}
	return i18n.Shared(language, "desktop.remote.container.docker")
}

// containersShown says whether the list shows the containers: Core found some, and no search is
// typed.
func (r *remoteState) containersShown() bool {
	return r.found == nil && len(r.containers.list) > 0
}

// loadRemoteContainers asks Core for the running containers of each engine in the background and
// lists them. An engine without its CLI, or whose service does not answer, adds none.
func (a *App) loadRemoteContainers() {
	r := &a.remote
	if r.containers.cancel != nil {
		r.containers.cancel()
	}
	r.containers.loads++
	load := r.containers.loads
	r.containers.discovering = true
	generation, kernel := r.generation, a.kernel
	cancel := a.background(nil, remoteContainerTimeout, func(ctx context.Context) func(*App) {
		var listed []remoteListedContainer
		var failures []error
		runtimes, discoveryErr := kernel.RemoteContainerRuntimes(ctx)
		if discoveryErr != nil {
			failures = append(failures, discoveryErr)
		}
		a.post(func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.containers.loads != load {
				// log-exempt: 用户取消：刷新或关闭窗口已取代本次发现。
				return
			}
			r.containers.runtimes, r.containers.discovering, r.containers.discovered = runtimes, false, true
			a.recordRemoteContainerRuntimes(runtimes)
			if d := r.devcontainer; d != nil && d.detecting && d.detectCancel == nil {
				d.detecting = false
				a.applyRemoteDevcontainerRuntimes(d, runtimes)
				if discoveryErr != nil {
					d.err = i18n.SharedFormat(a.language(), "desktop.remote.devcontainer.detectFailed", map[string]string{"reason": remoteLogError(discoveryErr).Error()})
				}
			}
		})
		if len(runtimes.Runtimes) > 0 {
			for _, runtime := range runtimes.Runtimes {
				if ctx.Err() != nil {
					failures = append(failures, ctx.Err())
					break
				}
				if !runtime.Available {
					continue
				}
				list, err := kernel.RemoteRuntimeContainers(ctx, runtime.ContainerRuntimeTarget)
				if err != nil {
					failures = append(failures, err)
					continue
				}
				if list.Diagnostics != "" {
					failures = append(failures, errors.New("container engine did not list running containers"))
				}
				for _, container := range list.Containers {
					target := runtime.ContainerRuntimeTarget
					listed = append(listed, remoteListedContainer{engine: target.Engine, runtime: &target, RemoteContainer: container})
				}
			}
		} else {
			for _, engine := range remoteContainerEngines {
				list, err := kernel.RemoteListContainers(ctx, engine, "")
				if err != nil {
					failures = append(failures, err)
					continue
				}
				if list.Diagnostics != "" {
					failures = append(failures, errors.New("container engine did not list running containers"))
				}
				for _, container := range list.Containers {
					listed = append(listed, remoteListedContainer{engine: engine, RemoteContainer: container})
				}
			}
		}
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.containers.loads != load {
				// log-exempt: 用户取消：窗口关闭后不再应用容器列表。
				return
			}
			r.containers.loaded = true
			r.containers.runtimes = runtimes
			for _, failure := range failures {
				// The list only lacks that engine's containers; nothing else depends on them.
				a.backgroundFailed("remote_containers_list", remoteLogError(failure))
			}
			r.containers.list = listed
			// The page of a listed container shows its image and state as listed now, such as the
			// container a dev container's build just started.
			if shown := r.containers.selected; shown != nil {
				if at := slices.IndexFunc(listed, func(c remoteListedContainer) bool { return c.key() == shown.key() }); at >= 0 {
					container := listed[at]
					r.containers.selected = &container
				}
			}
			r.buildRows()
			r.syncListSelection()
		}
	})
	r.containers.cancel = cancel
	if r.hostsOnly {
		r.hostReads = append(r.hostReads, cancel)
	}
}

// containerRows are the list's rows of the containers: their heading, and the containers unless
// the heading is folded.
func (r *remoteState) containerRows() []remoteListRow {
	if !r.containersShown() {
		return nil
	}
	rows := []remoteListRow{{heading: true, group: remoteContainerHeading, count: len(r.containers.list)}}
	if r.collapsed[remoteContainerHeading] {
		return rows
	}
	for i := range r.containers.list {
		rows = append(rows, remoteListRow{container: &r.containers.list[i]})
	}
	return rows
}

// containerRow is the list row of the container key names, -1 when the list has none.
func (r *remoteState) containerRow(key string) int {
	return slices.IndexFunc(r.rows, func(row remoteListRow) bool { return row.container != nil && row.container.key() == key })
}

// selectRemoteContainer shows the page of container, as the image's default user, dropping what
// the form held, the last test and its errors.
func (r *remoteState) selectRemoteContainer(container remoteListedContainer) {
	r.resetEditing()
	r.selected, r.editing = "", false
	r.form.clear()
	r.containers.selected = &container
	r.containers.user.SetText("")
	r.syncListSelection()
}

// remoteContainerWindows counts the workspaces open in the container name of engine, as any user.
func (a *App) remoteContainerWindows(engine, name string, targets ...*core.ContainerRuntimeTarget) int {
	prefix := engine
	if len(targets) > 0 && targets[0] != nil {
		target := targets[0]
		if target.Context != "" {
			prefix += "[" + target.Context + "]"
		}
		if target.WSL != "" {
			prefix = (core.WSLConnection{Distribution: target.WSL}).Identity() + "/" + prefix
		}
	}
	return a.remoteWindowsWhere(func(id string) bool {
		rest, ok := strings.CutPrefix(id, prefix+":")
		if !ok {
			return false
		}
		if _, container, ok := strings.Cut(rest, "@"); ok {
			rest = container
		}
		return rest == name
	})
}

// remoteContainerRefusalText is the window's text for a container field Core refused.
func remoteContainerRefusalText(language i18n.Language, refusal remoteFieldRefusal) string {
	if refusal.field == "user" {
		return i18n.Shared(language, "desktop.remote.container.userInvalid")
	}
	return i18n.Shared(language, "desktop.remote.container.nameInvalid")
}

// remoteContainerEnvironment shows the upstream environment label beside the engine's containers.
func (a *App) remoteContainerEnvironment(language i18n.Language, container remoteListedContainer) string {
	if container.runtime != nil {
		for _, runtime := range a.remote.containers.runtimes.Runtimes {
			if runtime.ContainerRuntimeTarget == *container.runtime {
				return remoteDevcontainerRuntimeLabel(language, runtime)
			}
		}
	}
	return remoteContainerEngineName(language, container.engine)
}

// remoteContainerRow declares a container in the list: its mark, its name over its engine and
// image, and on the right whether a window has it open.
func (a *App) remoteContainerRow(row ui.ListRow, language i18n.Language, container remoteListedContainer) {
	r := &a.remote
	rc := row.C
	small := a.theme.Metrics.FontSizeS
	row.Element.Height(remoteRowHeight).Items(ui.Center).Gap(9).PadSides(0, 12, 0, 0).Radius(6)
	if selected := r.containers.selected; selected != nil && selected.key() == container.key() {
		row.Element.Background(a.colors.Selection)
	}
	// The stripe's room keeps the rows aligned with the saved connections'.
	ui.Row(rc.Part("stripe")).Width(3).Height(remoteRowHeight - 14).Shrink(0)
	a.remoteTile(rc.Part("tile"), "", container.Name, "", 26, 10)
	ui.Column(rc).Grow(1).Basis(0).MinWidth(0).Gap(2).Children(func() {
		ui.Text(rc, container.Name).Weight(gfx.WeightMedium).Ellipsis().MinWidth(0)
		line := i18n.SharedFormat(language, "desktop.remote.container.row", map[string]string{
			"engine": a.remoteContainerEnvironment(language, container), "image": container.Image,
		})
		ui.Text(rc, line).FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
	})
	if a.remoteContainerWindows(container.engine, container.Name, container.runtime) > 0 {
		ui.Row(rc.Part("live")).Shrink(0).Items(ui.Center).Gap(5).Children(func() {
			a.remoteDot(rc.Part("dot"), a.colors.Success, 6)
			ui.Text(rc, i18n.Shared(language, "desktop.remote.connectedNow")).FontSize(small).Color(a.colors.Success)
		})
	}
}

// remoteContainerPage declares the selected container's page: its name, image and state, that it
// opens through its engine on this computer without being changed, the user it opens as, and
// Open Folder.
func (a *App) remoteContainerPage(c ui.C, language i18n.Language) {
	r := &a.remote
	container := *r.containers.selected
	engine := remoteContainerEngineName(language, container.engine)
	small := a.theme.Metrics.FontSizeS
	ui.Scroll(c.Part("container")).Scrollbars().Fill().Children(func() {
		ui.Column(c).FillWidth().Gap(22).PadSides(20, 24, 24, 24).Children(func() {
			a.remoteNotices(c)
			h := c.Part("hero")
			ui.Row(h).FillWidth().Items(ui.Center).Gap(14).Children(func() {
				a.remoteTile(h.Part("tile"), "", container.Name, "", remoteHeroTile, 15)
				ui.Column(h).Grow(1).Basis(0).MinWidth(0).Gap(5).Children(func() {
					ui.Row(h).FillWidth().Items(ui.Center).Gap(8).Children(func() {
						ui.Text(h, container.Name).FontSize(16).Weight(gfx.WeightSemibold).Ellipsis().Shrink(1).MinWidth(0)
						a.remotePill(h.Part("kind"), engine, a.colors.Subtle)
						if windows := a.remoteContainerWindows(container.engine, container.Name, container.runtime); windows > 0 {
							a.remoteStatusPill(h.Part("live"), i18n.SharedFormat(language, "desktop.remote.connectedWindows", map[string]string{"count": strconv.Itoa(windows)}), a.colors.Success)
						}
					})
					connection := r.containers.connection()
					ui.Text(h, connection.Identity()).Mono().FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
					state := i18n.SharedFormat(language, "desktop.remote.container.state", map[string]string{"image": container.Image, "status": container.Status})
					ui.Text(h, state).FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
				})
				if ui.Button(h.Part("open"), i18n.Shared(language, "desktop.remote.openFolder")).Icon(icons.FolderOpen).Shrink(0).Disabled(!r.connectable()).Clicked() {
					c.After(func() { a.connectRemote("") })
				}
			})
			ui.Paragraph(c, i18n.SharedFormat(language, "desktop.remote.container.about", map[string]string{"engine": engine}), 5).FontSize(small).Color(a.colors.Subtle)
			label := i18n.Shared(language, "desktop.remote.container.user")
			a.remoteSection(c.Part("account"), label, i18n.Shared(language, "desktop.remote.container.userHelp"), nil, func() {
				ui.TextField(c.Part("user"), &r.containers.user, label, i18n.Shared(language, "desktop.remote.container.userPlaceholder")).
					Width(260).Disabled(r.connect != nil || r.browser != nil)
			})
		})
	})
}

// remoteContainerFooter declares the buttons under a container's page: Close, and Connect, which
// lists its folders to choose one.
func (a *App) remoteContainerFooter(c ui.C, language i18n.Language) {
	r := &a.remote
	ui.Spacer(c)
	if ui.Button(c.Part("close"), i18n.Shared(language, "desktop.remote.close")).Outline().Clicked() {
		c.After(a.closeRemote)
	}
	if ui.Button(c.Part("connect"), i18n.Shared(language, "desktop.remote.connect")).Disabled(!r.connectable()).Clicked() {
		c.After(func() { a.connectRemote("") })
	}
}
