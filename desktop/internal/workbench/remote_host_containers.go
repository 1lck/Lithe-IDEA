package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// While a folder is chosen on an SSH host or a WSL distribution, the browser also lists the
// Docker and Podman containers running there and opens one as a remote workspace (#2231, R2).
// Core lists them over the browser's session (remote.listContainers with its id, once per engine),
// in the server's environment, which is the one entering a container then uses: what is listed can
// be entered. A host without an engine's CLI lists none of its containers.
//
// Entering a container ends the browser's session and connects again, to the host and on into the
// container through its engine's exec, as the user typed or the image's default user: the steps
// are the host's, OpenSSH asks again what it asks, and the folder is then chosen in the container.
// As for a container of this computer, Core never starts, creates or changes it, mounts no folder
// and asks for no more rights than the engine CLI has there (S32), and the trust decision names
// the host and the container. Nothing is saved for it: the workspace's identity is the host's and
// the container's, and its folders are not remembered.
//
// Neither the container, its image nor the user is logged; the engines' own words are shown and
// never logged.

// remoteBrowserContainers is the running containers of the host a folder is chosen on, which the
// browser lists in place of the host's folders while it is set.
type remoteBrowserContainers struct {
	loading bool
	// list is what Core found, Docker's containers before Podman's; engines counts the engines
	// whose CLI ran on the host.
	list    []remoteListedContainer
	engines int
	// diagnostics are what an engine printed when it ran and failed, such as that its service is
	// not running: upstream text, shown and never logged.
	diagnostics []string
	// err is why the containers could not be listed for another reason.
	err  string
	rows ui.ListState
	// user is the user to enter the selected container as; empty is the image's default user.
	user ui.Field
}

// hostsContainers says whether the browser's host can list containers to enter: an SSH host or a
// WSL distribution, not a container.
func (b *remoteBrowser) hostsContainers() bool {
	return b.host.container == nil
}

// selectedContainer is the container the list selects, nil when it selects none.
func (l *remoteBrowserContainers) selectedContainer() *remoteListedContainer {
	if at := l.rows.Selected(); at >= 0 && at < len(l.list) {
		return &l.list[at]
	}
	return nil
}

// showRemoteHostContainers lists the running containers of the browser's host in place of its
// folders.
func (a *App) showRemoteHostContainers() {
	r := &a.remote
	b := r.browser
	if b == nil || b.opening || !b.hostsContainers() {
		return
	}
	a.performed("remote.browse.containers", surfaceButton)
	list := &remoteBrowserContainers{loading: true}
	b.containers = list
	generation, kernel, session := r.generation, a.kernel, b.session.ID
	a.background(nil, remoteContainerTimeout, func(ctx context.Context) func(*App) {
		var found []remoteListedContainer
		var diagnostics []string
		engines := 0
		var failure error
		for _, engine := range remoteContainerEngines {
			listed, err := kernel.RemoteListContainers(ctx, engine, session)
			if err != nil {
				failure = err
				if remoteConnectionClosed(err) {
					break
				}
				continue
			}
			if listed.Available {
				engines++
			}
			if listed.Diagnostics != "" {
				diagnostics = append(diagnostics, listed.Diagnostics)
			}
			for _, container := range listed.Containers {
				found = append(found, remoteListedContainer{engine: engine, RemoteContainer: container})
			}
		}
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.browser != b || b.containers != list {
				// log-exempt: 用户取消：已回到文件夹、返回或关闭窗口，不再应用容器列表。
				return
			}
			list.loading = false
			list.list, list.engines, list.diagnostics = found, engines, diagnostics
			if failure != nil {
				a.operationFailed("remote_host_containers_list", remoteLogError(failure))
				if remoteConnectionClosed(failure) {
					// The session is gone: choosing over it cannot go on.
					a.leaveRemoteBrowser()
					r.err = i18n.Shared(a.language(), "desktop.remote.browse.lost")
					return
				}
				list.err = i18n.SharedFormat(a.language(), "desktop.remote.hostContainers.failed", map[string]string{"reason": remoteLogError(failure).Error()})
			}
		}
	})
}

// hideRemoteHostContainers shows the host's folders again.
func (a *App) hideRemoteHostContainers() {
	b := a.remote.browser
	if b == nil || b.containers == nil {
		return
	}
	a.performed("remote.browse.folders", surfaceButton)
	b.containers = nil
}

// remoteHostContainerTarget is the selected container of b's host as Connect connects to it: by
// name, as the user typed, after b's SSH connection or WSL distribution, named after both, with
// an identity no saved connection, WSL distribution or container of this computer has.
func remoteHostContainerTarget(language i18n.Language, b *remoteBrowser, container remoteListedContainer) (core.SavedRemoteConnection, remoteHost) {
	connection := core.ContainerConnection{Engine: container.engine, Container: container.Name, User: b.containers.user.Text()}
	host := remoteHost{ssh: b.host.ssh, wsl: b.host.wsl, container: &connection}
	name := i18n.SharedFormat(language, "desktop.remote.hostContainers.name", map[string]string{"container": container.Name, "host": b.name})
	return core.SavedRemoteConnection{ID: b.entryID + "/" + connection.Identity(), Name: name}, host
}

// enterRemoteHostContainer ends the browser's session and connects to the selected container on
// its host, listing the container's folders to choose one.
func (a *App) enterRemoteHostContainer() {
	r := &a.remote
	b := r.browser
	if b == nil || b.opening || b.containers == nil {
		return
	}
	container := b.containers.selectedContainer()
	if container == nil {
		return
	}
	a.performed("remote.browse.container.enter", surfaceButton)
	entry, host := remoteHostContainerTarget(a.language(), b, *container)
	a.leaveRemoteBrowser()
	a.connectRemoteTo(entry, host, "")
}

// remoteHostContainersView declares the host's containers in place of its folders: the user to
// enter as, the list, and the engines' words when listing failed.
func (a *App) remoteHostContainersView(c ui.C, language i18n.Language, list *remoteBrowserContainers) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Gap(12).Children(func() {
		ui.Paragraph(c, i18n.Shared(language, "desktop.remote.hostContainers.about"), 4).FontSize(small).Color(a.colors.Subtle)
		label := i18n.Shared(language, "desktop.remote.container.user")
		ui.Row(c.Part("account")).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			ui.Text(c, label).FontSize(small).Shrink(0)
			ui.TextField(c.Part("user"), &list.user, label, i18n.Shared(language, "desktop.remote.container.userPlaceholder")).Width(260)
		})
		if list.err != "" {
			a.remoteNotice(c.Part("error"), icons.CircleAlert, a.theme.Danger, list.err)
		}
		ui.Column(c.Part("rows")).FillWidth().Grow(1).Shrink(1).MinHeight(0).
			Border(1, a.colors.Line).Radius(a.theme.Metrics.RadiusItem()).Clip().Children(func() {
			if list.loading || len(list.list) == 0 {
				text := i18n.Shared(language, "desktop.remote.hostContainers.empty")
				switch {
				case list.loading:
					text = i18n.Shared(language, "native.loading")
				case list.engines == 0 && list.err == "":
					text = i18n.Shared(language, "desktop.remote.hostContainers.noEngine")
				}
				ui.Column(c.Part("empty")).FillWidth().Pad(12).Gap(8).Children(func() {
					ui.Paragraph(c, text, 3).FontSize(small).Color(a.colors.Subtle)
					for _, words := range list.diagnostics {
						ui.Paragraph(c, words, 6).Mono().FontSize(small).Color(a.colors.Subtle)
					}
				})
				return
			}
			list.rows.Label = func(row int) string {
				if row >= 0 && row < len(list.list) {
					return list.list[row].Name
				}
				return ""
			}
			ui.List(c.Part("list"), &list.rows, len(list.list), func(row ui.ListRow) {
				rc := row.C
				container := list.list[row.Index]
				row.Element.Height(remoteRowHeight).PadX(12).Gap(10).Items(ui.Center)
				if row.Selected() {
					row.Element.Background(a.colors.Selection)
				} else {
					row.Element.Hover(ui.Look{}.Background(a.colors.Hover))
				}
				row.Element.Children(func() {
					a.remoteTile(rc.Part("tile"), "", container.Name, "", 26, 10)
					ui.Column(rc).Grow(1).Basis(0).MinWidth(0).Gap(2).Children(func() {
						ui.Text(rc, container.Name).Weight(gfx.WeightMedium).Ellipsis().MinWidth(0)
						line := i18n.SharedFormat(language, "desktop.remote.container.row", map[string]string{
							"engine": remoteContainerEngineName(language, container.engine), "image": container.Image,
						})
						ui.Text(rc, line).FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
					})
					ui.Text(rc, container.Status).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				})
			}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(i18n.Shared(language, "desktop.remote.container.heading"))
			if _, ok := list.rows.Submitted(); ok {
				c.After(a.enterRemoteHostContainer)
			}
		})
	})
}

// remoteHostContainersFooter declares the buttons under the host's containers: back to its
// folders, and Enter Container, which connects to the selected one.
func (a *App) remoteHostContainersFooter(c ui.C, language i18n.Language, list *remoteBrowserContainers) {
	ui.Spacer(c)
	if ui.Button(c.Part("folders"), i18n.Shared(language, "desktop.remote.hostContainers.back")).Outline().Clicked() {
		c.After(a.hideRemoteHostContainers)
	}
	if ui.Button(c.Part("enter"), i18n.Shared(language, "desktop.remote.hostContainers.enter")).Disabled(list.selectedContainer() == nil).Clicked() {
		c.After(a.enterRemoteHostContainer)
	}
}
