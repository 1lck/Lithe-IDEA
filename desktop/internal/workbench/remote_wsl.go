package workbench

import (
	"context"
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

// The Remote Development window also opens the distributions of the Windows Subsystem for Linux
// installed on this computer as remote workspaces (#2231). Core lists them each time the window
// opens (remote.listWslDistributions, which answers unavailable without running anything on other
// systems), and the list shows them under their own heading after the saved connections, while no
// search is typed: a search finds saved connections only.
//
// Nothing about a distribution is saved. It connects through the system's wsl.exe as the Linux
// account typed on its page, or the distribution's default user, and asks nothing, so no
// authentication dialog opens. The rest is the SSH path: the steps, the folder chosen on the host,
// the trust decision, the workspace and its reconnection. Its folders are not remembered, since the
// saved list holds SSH connections only.
//
// Neither the distribution nor the account is logged; wsl.exe's own words are shown under a failed
// connection and never logged.

const (
	// remoteWSLHeading is the list's group of the WSL heading. No saved group can have it, since
	// Core refuses control characters in one.
	remoteWSLHeading = "\x00wsl"
	// remoteWSLTimeout bounds listing the distributions. Core bounds wsl.exe at 15 seconds, the
	// time the WSL service may take to start for the first time after Windows starts.
	remoteWSLTimeout = 20 * time.Second
	// remoteWSLPrefix starts the identity Core gives a WSL distribution (core.WSLConnection.Identity),
	// which no saved connection's id starts with.
	remoteWSLPrefix = "wsl:"
)

// remoteHost is what a session connects to: a saved SSH connection, a WSL distribution of this
// computer when wsl is set, or a running container when container is set. A container is on this
// computer when it is set alone, and on the SSH host ssh names or the WSL distribution wsl names
// otherwise (remote_host_containers.go): the session logs in there and enters it.
type remoteHost struct {
	ssh       core.SSHConnection
	wsl       *core.WSLConnection
	container *core.ContainerConnection
}

// hosted says whether the host is a container on an SSH host or a WSL distribution.
func (h remoteHost) hosted() bool {
	return h.container != nil && (h.wsl != nil || h.ssh != (core.SSHConnection{}))
}

// overSSH says whether the session logs in through OpenSSH: a saved SSH connection, or a
// container on its host. Only these read the SSH program's preferences and have the steps that
// read OpenSSH's configuration and authenticate.
func (h remoteHost) overSSH() bool {
	return h.wsl == nil && (h.container == nil || h.ssh != (core.SSHConnection{}))
}

// saved says whether the host is the saved SSH connection itself: the only kind with a form to
// edit and remembered folders.
func (h remoteHost) saved() bool {
	return h.wsl == nil && h.container == nil
}

// address is the host as the window shows it: [user@]host[:port] for SSH,
// wsl:[user@]distribution for WSL and engine:[user@]container for a container, after its host's
// address and " › " when it is on one.
func (h remoteHost) address() string {
	var host string
	switch {
	case h.wsl != nil:
		host = h.wsl.Identity()
	case h.ssh != (core.SSHConnection{}):
		host = remoteAddress(h.ssh)
	}
	switch {
	case h.container == nil:
		return host
	case host == "":
		return h.container.Identity()
	}
	return host + " › " + h.container.Identity()
}

// kind is how the host is reached, as the window title and the status bar name it: SSH, WSL or
// Container.
func (h remoteHost) kind(language i18n.Language) string {
	switch {
	case h.container != nil:
		return i18n.Shared(language, "desktop.remote.container.kind")
	case h.wsl != nil:
		return i18n.Shared(language, "desktop.remote.wsl.heading")
	}
	return i18n.Shared(language, "desktop.remote.kind.ssh")
}

// request is Core's request to connect to the host with servers, the server builds of version:
// its SSH connection or WSL distribution, followed by the container to enter there when it has
// one. A container of this computer has neither, so Core enters it here.
func (h remoteHost) request(servers []core.RemoteServerBuild, version string) core.RemoteConnectRequest {
	request := core.RemoteConnectRequest{Servers: servers, ServerVersion: version}
	if h.wsl != nil {
		wsl := *h.wsl
		request.WSL = &wsl
	} else {
		request.Connection = h.ssh
	}
	if h.container != nil {
		container := *h.container
		request.Container = &container
	}
	return request
}

// remoteWSL is the window's WSL distributions.
type remoteWSL struct {
	// list is Core's answer, once loaded.
	loaded bool
	list   core.RemoteWSLDistributions
	// selected is the distribution the page shows, "" while it shows a saved connection or none.
	selected string
	// user is the page's Linux account; empty is the distribution's default user.
	user ui.Field
}

// connection is the selected distribution as the page connects to it. The account is passed as
// typed, and Core trims it.
func (w *remoteWSL) connection() core.WSLConnection {
	return core.WSLConnection{Distribution: w.selected, User: w.user.Text()}
}

// wslShown says whether the list shows the WSL distributions: Core found some, and no search is
// typed.
func (r *remoteState) wslShown() bool {
	return r.found == nil && r.wsl.list.Available && len(r.wsl.list.Distributions) > 0
}

// loadRemoteWSL asks Core for the WSL distributions in the background and lists them.
func (a *App) loadRemoteWSL() {
	r := &a.remote
	generation, kernel := r.generation, a.kernel
	cancel := a.background(nil, remoteWSLTimeout, func(ctx context.Context) func(*App) {
		list, err := kernel.RemoteListWSLDistributions(ctx)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation {
				// log-exempt: 用户取消：窗口关闭后不再应用发行版列表。
				return
			}
			r.wsl.loaded = true
			if err != nil {
				// The list only lacks its WSL distributions; nothing else depends on them.
				a.backgroundFailed("remote_wsl_list", remoteLogError(err))
				return
			}
			r.wsl.list = list
			r.buildRows()
			r.syncListSelection()
		}
	})
	if r.hostsOnly {
		r.hostReads = append(r.hostReads, cancel)
	}
}

// wslRows are the list's rows of the WSL distributions: their heading, and the distributions
// unless the heading is folded.
func (r *remoteState) wslRows() []remoteListRow {
	if !r.wslShown() {
		return nil
	}
	rows := []remoteListRow{{heading: true, group: remoteWSLHeading, count: len(r.wsl.list.Distributions)}}
	if r.collapsed[remoteWSLHeading] {
		return rows
	}
	for _, name := range r.wsl.list.Distributions {
		rows = append(rows, remoteListRow{wsl: name})
	}
	return rows
}

// wslRow is the list row of the distribution name, -1 when the list has none.
func (r *remoteState) wslRow(name string) int {
	return slices.IndexFunc(r.rows, func(row remoteListRow) bool { return row.wsl == name })
}

// selectRemoteWSL shows the page of the distribution name, as its default user, dropping what the
// form held, the last test and its errors.
func (r *remoteState) selectRemoteWSL(name string) {
	r.resetEditing()
	r.selected, r.editing = "", false
	r.form.clear()
	r.wsl.selected = name
	r.wsl.user.SetText("")
	r.syncListSelection()
}

// remoteWSLWindows counts the workspaces open over the distribution name, as any account.
func (a *App) remoteWSLWindows(name string) int {
	return a.remoteWindowsWhere(func(id string) bool {
		rest, ok := strings.CutPrefix(id, remoteWSLPrefix)
		if !ok {
			return false
		}
		if _, distribution, ok := strings.Cut(rest, "@"); ok {
			rest = distribution
		}
		return rest == name
	})
}

// remoteWSLRefusalText is the window's text for a WSL field Core refused.
func remoteWSLRefusalText(language i18n.Language, refusal remoteFieldRefusal) string {
	switch {
	case refusal.field == "user" && refusal.reason == "tooLong":
		return i18n.Shared(language, "desktop.remote.wsl.userTooLong")
	case refusal.field == "user":
		return i18n.Shared(language, "desktop.remote.wsl.userInvalid")
	}
	return i18n.Shared(language, "desktop.remote.wsl.distributionInvalid")
}

// remoteWSLRow declares a distribution in the list: its mark, its name over how it is reached, and
// on the right whether a window has it open.
func (a *App) remoteWSLRow(row ui.ListRow, language i18n.Language, name string) {
	r := &a.remote
	rc := row.C
	small := a.theme.Metrics.FontSizeS
	row.Element.Height(remoteRowHeight).Items(ui.Center).Gap(9).PadSides(0, 12, 0, 0).Radius(6)
	if name == r.wsl.selected {
		row.Element.Background(a.colors.Selection)
	}
	// The stripe's room keeps the rows aligned with the saved connections'.
	ui.Row(rc.Part("stripe")).Width(3).Height(remoteRowHeight - 14).Shrink(0)
	a.remoteTile(rc.Part("tile"), "", name, "", 26, 10)
	ui.Column(rc).Grow(1).Basis(0).MinWidth(0).Gap(2).Children(func() {
		ui.Text(rc, name).Weight(gfx.WeightMedium).Ellipsis().MinWidth(0)
		ui.Text(rc, i18n.Shared(language, "desktop.remote.wsl.kind")).FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
	})
	if a.remoteWSLWindows(name) > 0 {
		ui.Row(rc.Part("live")).Shrink(0).Items(ui.Center).Gap(5).Children(func() {
			a.remoteDot(rc.Part("dot"), a.colors.Success, 6)
			ui.Text(rc, i18n.Shared(language, "desktop.remote.connectedNow")).FontSize(small).Color(a.colors.Success)
		})
	}
}

// remoteWSLPage declares the selected distribution's page: its name, that it opens through
// wsl.exe on this computer, the account it opens as, and Open Folder.
func (a *App) remoteWSLPage(c ui.C, language i18n.Language) {
	r := &a.remote
	name := r.wsl.selected
	small := a.theme.Metrics.FontSizeS
	ui.Scroll(c.Part("wsl")).Fill().Children(func() {
		ui.Column(c).FillWidth().Gap(22).PadSides(20, 24, 24, 24).Children(func() {
			a.remoteNotices(c)
			h := c.Part("hero")
			ui.Row(h).FillWidth().Items(ui.Center).Gap(14).Children(func() {
				a.remoteTile(h.Part("tile"), "", name, "", remoteHeroTile, 15)
				ui.Column(h).Grow(1).Basis(0).MinWidth(0).Gap(5).Children(func() {
					ui.Row(h).FillWidth().Items(ui.Center).Gap(8).Children(func() {
						ui.Text(h, name).FontSize(16).Weight(gfx.WeightSemibold).Ellipsis().Shrink(1).MinWidth(0)
						a.remotePill(h.Part("kind"), i18n.Shared(language, "desktop.remote.wsl.heading"), a.colors.Subtle)
						if windows := a.remoteWSLWindows(name); windows > 0 {
							a.remoteStatusPill(h.Part("live"), i18n.SharedFormat(language, "desktop.remote.connectedWindows", map[string]string{"count": strconv.Itoa(windows)}), a.colors.Success)
						}
					})
					wsl := r.wsl.connection()
					ui.Text(h, wsl.Identity()).Mono().FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
				})
				if ui.Button(h.Part("open"), i18n.Shared(language, "desktop.remote.openFolder")).Icon(icons.FolderOpen).Shrink(0).Disabled(!r.connectable()).Clicked() {
					c.After(func() { a.connectRemote("") })
				}
			})
			ui.Paragraph(c, i18n.Shared(language, "desktop.remote.wsl.about"), 4).FontSize(small).Color(a.colors.Subtle)
			label := i18n.Shared(language, "desktop.remote.wsl.user")
			a.remoteSection(c.Part("account"), label, i18n.Shared(language, "desktop.remote.wsl.userHelp"), nil, func() {
				ui.TextField(c.Part("user"), &r.wsl.user, label, i18n.Shared(language, "desktop.remote.wsl.userPlaceholder")).
					Width(260).Disabled(r.connect != nil || r.browser != nil)
			})
		})
	})
}

// remoteWSLFooter declares the buttons under a distribution's page: Close, and Connect, which lists
// its folders to choose one.
func (a *App) remoteWSLFooter(c ui.C, language i18n.Language) {
	r := &a.remote
	ui.Spacer(c)
	if ui.Button(c.Part("close"), i18n.Shared(language, "desktop.remote.close")).Outline().Clicked() {
		c.After(a.closeRemote)
	}
	if ui.Button(c.Part("connect"), i18n.Shared(language, "desktop.remote.connect")).Disabled(!r.connectable()).Clicked() {
		c.After(func() { a.connectRemote("") })
	}
}
