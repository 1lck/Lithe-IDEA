package settingswindow

import (
	"errors"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// trustedLocationsPage lists the folders whose every project opens trusted, as Core read them
// from the machine catalog. Opening it only reads; adding or removing a folder is a draft that
// Core checks at once and the footer's Apply writes with the other Build drafts.
func (w *window) trustedLocationsPage(c ui.C) {
	l := w.toolchains.locations
	remote := w.toolchains.remote
	language := w.marketLanguage()
	l.ensureLoaded()
	remote.ensureLoaded()
	w.pageScroll(c, pageTrustedLocations, func() {
		if l.available() {
			w.card(c, i18n.Shared(language, "desktop.trustedLocations.folders"), i18n.Shared(language, "desktop.trustedLocations.foldersHelp"), func() {
				w.trustedLocationsList(c.Part("list"), language, l)
			})
			w.trustedLocationsNotices(c, language, l)
		}
		if remote.available() {
			w.card(c.Part("remote"), i18n.Shared(language, "desktop.trustedLocations.remote"), i18n.Shared(language, "desktop.trustedLocations.remoteHelp"), func() {
				w.remoteTrustList(c.Part("remote-list"), language, remote)
			})
			w.remoteTrustNotices(c, language, remote)
		}
	})
}

// remoteTrustList is each connection's records under its name and host: the folders trusted,
// kept in safe mode and trusted as locations, each with the button that removes it, marked when a
// draft removes it. Nothing here adds a record: a remote folder is decided on when it opens.
func (w *window) remoteTrustList(c ui.C, language i18n.Language, r *remoteTrustState) {
	p := &w.pal
	if !r.loaded {
		if r.readFailed == nil {
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Children(func() {
				ui.Text(c, i18n.Shared(language, "desktop.toolchains.loading")).FontSize(12).Color(p.muted)
			})
		}
		return
	}
	busy := r.busy()
	groups := r.groups()
	if len(groups) == 0 {
		ui.Row(c).FillWidth().MinHeight(28).PadY(4).Items(ui.Center).Children(func() {
			ui.Wrap(c, i18n.Shared(language, "desktop.trustedLocations.remoteEmpty")).FontSize(12).Color(p.muted).Grow(1).Shrink(1).MinWidth(0)
		})
		return
	}
	for index, group := range groups {
		g := c.Key(string(group.target.Target))
		if index > 0 {
			ui.Row(g.Part("gap")).FillWidth().Height(1).Shrink(0).Background(p.line)
		}
		place := group.target.Place()
		name := group.target.Label
		if name == "" {
			name, place = place, ""
		}
		if name == "" {
			name = i18n.Shared(language, "desktop.trustedLocations.remoteUnnamed")
		}
		ui.Row(g.Part("head")).FillWidth().MinWidth(0).Height(28).Gap(8).Items(ui.Center).Children(func() {
			ui.Icon(c, icons.Server).Size(14, 14).Color(p.muted).Shrink(0)
			ui.Text(c, name).FontSize(12).Weight(gfx.WeightSemibold).Color(p.text).Shrink(1).MinWidth(0).Ellipsis()
			if place != "" {
				ui.Text(c, place).FontSize(12).Mono().Color(p.muted).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
			}
		})
		for _, entry := range group.entries {
			k := g.Key(entry.list + "\x00" + entry.path)
			ui.Row(k).FillWidth().MinWidth(0).Height(28).PadLeft(22).Gap(8).Items(ui.Center).Children(func() {
				words := p.text
				if entry.revoked {
					words = p.subtle
				}
				switch entry.list {
				case core.RemoteTrustDistrustedWorkspaces:
					w.tag(k.Part("kind"), tagWarn, i18n.Shared(language, "desktop.trustedLocations.remoteDistrusted"))
				case core.RemoteTrustTrustedLocations:
					w.tag(k.Part("kind"), tagBlue, i18n.Shared(language, "desktop.trustedLocations.remoteLocation"))
				default:
					w.tag(k.Part("kind"), tagGreen, i18n.Shared(language, "desktop.trustedLocations.remoteTrusted"))
				}
				// The tooltip shows a path the row's width cuts; it needs an element with an identity.
				path := k.Part("path")
				ui.Row(path).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).
					HitWith(ui.ID(path), entry.path, gfx.HitOptions{Role: gfx.RoleGroup}).Tooltip(entry.path).Children(func() {
					ui.Text(path, entry.path).FontSize(12).Mono().Color(words).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
				})
				if entry.revoked {
					w.tag(k.Part("mark"), tagErr, i18n.Shared(language, "desktop.trustedLocations.pendingRemove"))
					if w.button(k.Part("undo"), buttonLinkSmall, i18n.Shared(language, "desktop.buildSettings.undoChange"), busy) {
						r.toggle(group.target, entry.list, entry.path)
					}
					return
				}
				if w.iconButton(k.Part("remove"), icons.X, i18n.Shared(language, "desktop.trustedLocations.remoteRemove"), busy) {
					r.toggle(group.target, entry.list, entry.path)
				}
			})
		}
	}
}

// remoteTrustNotices are the read's and the write's failures, and the write that is out.
func (w *window) remoteTrustNotices(c ui.C, language i18n.Language, r *remoteTrustState) {
	if r.readFailed == nil && r.failed == nil && !r.saving {
		return
	}
	ui.Column(c.Part("remote-notices")).FillWidth().Shrink(0).Gap(8).Children(func() {
		if r.readFailed != nil {
			message := remoteTrustFailureMessage(language, r.readFailed)
			w.box(c.Part("load-failed"), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
				if w.button(c.Part("load-retry"), buttonSmall, i18n.Shared(language, "desktop.toolchains.reload"), r.busy()) {
					r.reload()
				}
			})
		}
		if r.failed != nil {
			message := remoteTrustFailureMessage(language, r.failed)
			w.box(c.Part("failed"), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
			})
		}
		if r.saving {
			w.box(c.Part("busy"), boxInfo, func(words gfx.Color) {
				boxIcon(c, icons.Clock, words)
				boxText(c, i18n.Shared(language, "desktop.toolchains.saving"), words)
			})
		}
	})
}

// trustedLocationsList is one row per folder, marked when a draft adds or removes it, then
// the button that adds one.
func (w *window) trustedLocationsList(c ui.C, language i18n.Language, l *trustedLocationsState) {
	p := &w.pal
	if !l.loaded {
		if l.readFailed == nil {
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Children(func() {
				ui.Text(c, i18n.Shared(language, "desktop.toolchains.loading")).FontSize(12).Color(p.muted)
			})
		}
		return
	}
	busy := w.toolchains.busy()
	rows := l.rows()
	if len(rows) == 0 {
		ui.Row(c).FillWidth().MinHeight(28).PadY(4).Items(ui.Center).Children(func() {
			ui.Wrap(c, i18n.Shared(language, "desktop.trustedLocations.empty")).FontSize(12).Color(p.muted).Grow(1).Shrink(1).MinWidth(0)
		})
	}
	for _, row := range rows {
		k := c.Key(row.folder)
		shown := filepath.FromSlash(row.folder)
		ui.Row(k).FillWidth().MinWidth(0).Height(28).Gap(8).Items(ui.Center).Children(func() {
			words := p.text
			if row.mark == locationRemoved {
				words = p.subtle
			}
			ui.Icon(c, icons.Folder).Size(14, 14).Color(p.muted).Shrink(0)
			// The tooltip shows a path the row's width cuts; it needs an element with an identity.
			path := k.Part("path")
			ui.Row(path).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).
				HitWith(ui.ID(path), shown, gfx.HitOptions{Role: gfx.RoleGroup}).Tooltip(shown).Children(func() {
				ui.Text(path, shown).FontSize(12).Mono().Color(words).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
			})
			switch row.mark {
			case locationAdded:
				w.tag(k.Part("mark"), tagGreen, i18n.Shared(language, "desktop.trustedLocations.pendingAdd"))
				if w.button(k.Part("undo"), buttonLinkSmall, i18n.Shared(language, "desktop.buildSettings.undoChange"), busy) {
					l.undo(row.folder)
				}
			case locationRemoved:
				w.tag(k.Part("mark"), tagErr, i18n.Shared(language, "desktop.trustedLocations.pendingRemove"))
				if w.button(k.Part("undo"), buttonLinkSmall, i18n.Shared(language, "desktop.buildSettings.undoChange"), busy) {
					l.undo(row.folder)
				}
			default:
				if w.iconButton(k.Part("remove"), icons.X, i18n.Shared(language, "desktop.trustedLocations.remove"), busy) {
					l.change(row.folder, false)
				}
			}
		})
	}
	ui.Row(c).FillWidth().Height(1).Shrink(0).Background(p.line)
	ui.Row(c).FillWidth().PadTop(6).PadBottom(2).Items(ui.Center).Children(func() {
		if w.button(c.Part("add"), buttonSmall, i18n.Shared(language, "desktop.trustedLocations.add"), busy) {
			// The native picker runs a modal message loop on Windows, so it must run after paint.
			c.After(func() { w.pickTrustedLocation(language) })
		}
	})
}

// trustedLocationsNotices are the read's, the check's and the write's failures, and the write
// that is out.
func (w *window) trustedLocationsNotices(c ui.C, language i18n.Language, l *trustedLocationsState) {
	if l.readFailed == nil && l.refused == nil && l.failed == nil && !l.saving {
		return
	}
	ui.Column(c.Part("notices")).FillWidth().Shrink(0).Gap(8).Children(func() {
		if l.readFailed != nil {
			message := toolchainFailureMessage(language, l.readFailed)
			w.box(c.Part("load-failed"), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
				if w.button(c.Part("load-retry"), buttonSmall, i18n.Shared(language, "desktop.toolchains.reload"), w.toolchains.busy()) {
					l.reload()
				}
			})
		}
		for _, failure := range []struct {
			key string
			err error
		}{{"refused", l.refused}, {"failed", l.failed}} {
			if failure.err == nil {
				continue
			}
			message := toolchainFailureMessage(language, failure.err)
			w.box(c.Part(failure.key), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
			})
		}
		if l.saving {
			w.box(c.Part("busy"), boxInfo, func(words gfx.Color) {
				boxIcon(c, icons.Clock, words)
				boxText(c, i18n.Shared(language, "desktop.toolchains.saving"), words)
			})
		}
	})
}

// pickTrustedLocation asks for a folder and adds it as a draft once Core accepts it.
func (w *window) pickTrustedLocation(language i18n.Language) {
	defer w.inv.Invalidate()
	path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: i18n.Shared(language, "desktop.trustedLocations.chooseFolder")})
	// log-exempt: 用户取消：关闭目录选择器不修改可信位置草稿。
	if errors.Is(err, app.ErrCanceled) {
		return
	}
	l := w.toolchains.locations
	if err != nil {
		l.failed = err
		if w.ctrl.opts.MarketplaceError != nil {
			w.ctrl.opts.MarketplaceError(err)
		}
		return
	}
	l.change(path, true)
}
