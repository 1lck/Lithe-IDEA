package workbench

import (
	"os"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the History tab (agents_history.go keeps its state): the heading with the
// host, filter and refresh buttons, the scope switch, the search field, what the last refresh
// read, the count with the order, and the sessions grouped by directory, each with its title,
// a preview of its last message and what it holds; the floating button shows or hides the
// previews.

const (
	// agentHistoryPadX is the left and right inset of the tab's rows.
	agentHistoryPadX = 12
	// agentHistoryChipHeight is the height of the chips (host, order, refresh time).
	agentHistoryChipHeight = 24
	// agentHistorySegmentHeight is the height of the scope switch's segments.
	agentHistorySegmentHeight = 28
	// agentHistoryMetaIcon is the size of the agent's icon in a session row.
	agentHistoryMetaIcon = 14
	// agentHistoryFloatSize is the size of the floating density button.
	agentHistoryFloatSize = 34
	// agentHistoryEndSpace is the blank space after the list's last row, so the row scrolls clear
	// of the floating density button.
	agentHistoryEndSpace = agentHistoryFloatSize + 2*agentHistoryFloatInset
	// agentHistoryFloatInset is how far the density button sits from the list's corner.
	agentHistoryFloatInset = 14
	// agentHistoryBadgeSize is the size of the filter button's count badge.
	agentHistoryBadgeSize = 14
	// agentPreviewLineFactor is a preview line's height over its font size.
	agentPreviewLineFactor = 1.45
	// agentPreviewPrefixGap is the gap after a preview's speaker.
	agentPreviewPrefixGap = 4
	// agentHistoryNameMin keeps the first letters of an agent's name in a narrow meta line.
	agentHistoryNameMin = 34
	// agentHistoryModelMin is the least of a session's model the meta line shows; with less room
	// the model drops out of the line, which the session's details still show.
	agentHistoryModelMin = 56
	// agentHistoryMetaGap separates the parts of the meta line.
	agentHistoryMetaGap = 5
	// agentPreviewTextAlpha dims a preview's words below a title's, above the meta line's.
	agentPreviewTextAlpha = 0.78
)

// agentsHistoryPanel declares the History tab: why there is nothing to list, a recorded
// session read in place of the list, or the list itself.
func (a *App) agentsHistoryPanel(c ui.C, p *project) {
	v := &a.agentsView
	h := &v.history
	lang := a.language()
	if len(v.readableAgents()) == 0 {
		ui.Column(c).Fill().Center().Gap(10).PadX(shellContentPad).Children(func() {
			message := i18n.Shared(lang, "desktop.agents.history.unsupported")
			if v.sessionReadingOffered() {
				message = i18n.Shared(lang, "desktop.agents.history.noConsent")
			}
			ui.Paragraph(c, message, 4).FillWidth().TextCenter().Color(a.colors.Subtle)
			if v.sessionReadingOffered() && ui.Button(c.Key("settings"), i18n.Shared(lang, "desktop.agents.history.openSettings")).Outline().Clicked() {
				c.After(func() { a.openSettingsPage(surfaceButton, settingsAgents) })
			}
		})
		return
	}
	if record := h.record; record != nil {
		if v.recordReadable(record) {
			a.agentRecordPanel(c.Part("record"), p, record)
			return
		}
		c.After(a.closeRecord)
	}
	if !h.loaded {
		h.wantsList = true
	}
	ui.Column(c).Fill().Children(func() {
		a.agentHistoryHeading(c.Part("heading"), p, lang)
		a.agentHistoryScope(c.Part("scope"), p, lang)
		a.agentHistorySearch(c.Part("search"), p, lang)
		a.agentHistoryStatus(c.Part("status"), lang)
		a.agentHistoryCount(c.Part("count"), p, lang)
		a.agentHistoryBody(c.Part("body"), p, lang)
		a.agentHistoryDensity(c.Part("density"), lang)
	})
}

// agentHistoryHeading declares the tab's title with its host, filter and refresh buttons, and
// under them what it lists; the subtitle runs the panel's width, so a longer language does not
// cut it.
func (a *App) agentHistoryHeading(c ui.C, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	metrics := a.theme.Metrics
	ui.Column(c).FillWidth().Shrink(0).PadSides(10, 8, 6, agentHistoryPadX).Children(func() {
		ui.Row(c).FillWidth().Gap(4).Items(ui.Center).Children(func() {
			ui.Text(c, i18n.Shared(lang, "desktop.agents.history.title")).FontSize(metrics.FontSizeM + 1).Weight(gfx.WeightSemibold).
				Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
			ui.Spacer(c)
			a.agentHistoryHeadingButtons(c, p, lang)
		})
		subtitle := ui.Text(c, agentHistorySubtitle(lang, h.searchOrder)).FontSize(metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
		if names := a.agentHistoryAgentNames(lang); names != "" {
			subtitle.Hit(ui.ID(c.Part("subtitle")), names).Tooltip(names)
		}
	})
}

// agentHistoryHeadingButtons declares the heading's host chip, the filter button with the count
// of the filter's choices that narrow the list, and the refresh button.
func (a *App) agentHistoryHeadingButtons(c ui.C, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	metrics := a.theme.Metrics
	ui.Row(c).Shrink(0).Gap(2).Items(ui.Center).Children(func() {
		hostLabel := agentHostLabel(lang)
		host := a.agentHistoryChip(c.Part("host"), hostLabel, &icons.Server, false, h.popup == agentPopupHost).
			Tooltip(i18n.Shared(lang, "desktop.agents.history.hostHelp"))
		if host.Clicked() {
			c.After(func() { a.agentsView.history.popup = agentPopupHost })
		}
		a.agentHistoryHostMenu(c.Part("host-menu"), host, hostLabel, lang)

		var filter ui.Box
		var filterHit bool
		ui.Row(c).Shrink(0).Children(func() {
			filter, filterHit = a.toolIconButton(c.Part("filter"), i18n.Shared(lang, "desktop.agents.history.filter"), icons.ListFilter,
				h.popup == agentPopupFilter, false)
			if n := h.filtersActive(); n > 0 {
				ui.Row(c).Absolute().Top(-3).Right(-3).Size(agentHistoryBadgeSize, agentHistoryBadgeSize).Radius(agentHistoryBadgeSize / 2).
					Background(a.colors.Text).Items(ui.Center).Justify(ui.Center).Children(func() {
					ui.Text(c, strconv.Itoa(n)).FontSize(metrics.FontSizeS - 3).Weight(gfx.WeightBold).Color(a.colors.Editor)
				})
			}
		})
		if filterHit {
			c.After(func() { a.agentsView.history.popup = agentPopupFilter })
		}
		a.agentHistoryFilter(c.Part("filter-popover"), p, filter, lang)

		if _, hit := a.toolIconButton(c.Part("refresh"), i18n.Shared(lang, "desktop.agents.history.refresh"), icons.RefreshCw, false, h.refreshing); hit {
			c.After(func() {
				a.performed("agents.history.refresh", surfaceButton)
				a.refreshAgentHistory(p)
			})
		}
	})
}

// agentHistorySubtitle says what the tab lists, the indexed history, and how a search ranks it.
func agentHistorySubtitle(lang i18n.Language, searchOrder agentHistoryOrder) string {
	return i18n.SharedFormat(lang, "desktop.agents.history.subtitle", map[string]string{
		"order": agentOrderLabel(lang, searchOrder, true),
	})
}

// agentHistoryAgentNames names the agents whose sessions the tab reads, for the subtitle's tooltip.
func (a *App) agentHistoryAgentNames(lang i18n.Language) string {
	var names []string
	for _, key := range a.agentsView.readableAgents() {
		names = append(names, a.agentDisplayName(key))
	}
	return strings.Join(names, i18n.Shared(lang, "desktop.agents.history.listSeparator"))
}

// agentHostLabel names the computer the sessions are read on.
func agentHostLabel(lang i18n.Language) string {
	switch runtime.GOOS {
	case "darwin":
		return i18n.Shared(lang, "desktop.agents.history.hostMac")
	case "windows":
		return i18n.Shared(lang, "desktop.agents.history.hostWindows")
	}
	return i18n.Shared(lang, "desktop.agents.history.hostLinux")
}

// agentHistoryHostMenu declares the hosts the sessions can be read on, under the host chip: this
// computer only, since sessions on a remote host are not read yet.
func (a *App) agentHistoryHostMenu(c ui.C, anchor ui.Box, label string, lang i18n.Language) {
	h := &a.agentsView.history
	if h.popup != agentPopupHost {
		return
	}
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		if menu.Item(label).Icon(icons.Server).Checked(true).Description(i18n.Shared(lang, "desktop.agents.history.hostHelp")).Clicked() {
			c.After(func() { a.agentsView.history.popup = agentPopupNone })
		}
		menu.Separator()
		menu.Item(i18n.Shared(lang, "desktop.agents.history.remoteUnsupported")).Disabled(true)
	})
	if !open {
		h.popup = agentPopupNone
	}
}

// agentHistoryFilter declares the filter's popover under its button: the agents listed and how
// recent their sessions are.
func (a *App) agentHistoryFilter(c ui.C, p *project, anchor ui.Box, lang i18n.Language) {
	v := &a.agentsView
	h := &v.history
	if h.popup != agentPopupFilter {
		return
	}
	small := a.theme.Metrics.FontSizeS
	open := true
	spec := ui.PopoverSpec{
		Align: ui.End, Offset: chromeMenuOffset, Width: 248, ConsumeOutsidePress: true,
		Title: i18n.Shared(lang, "desktop.agents.history.filterTitle"),
	}
	ui.Popover(c, anchor, &open, spec, func() {
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			ui.Text(c, i18n.Shared(lang, "desktop.agents.history.filterAgents")).FontSize(small).Color(a.colors.Subtle)
			for i, key := range v.readableAgents() {
				shown := !h.hidden[key]
				if ui.Checkbox(c.KeyInt(i), &shown, a.agentDisplayName(key)).Changed() {
					c.After(func() {
						h := &a.agentsView.history
						if h.hidden == nil {
							h.hidden = map[string]bool{}
						}
						if shown {
							delete(h.hidden, key)
						} else {
							h.hidden[key] = true
						}
						a.loadAgentHistory(p)
					})
				}
			}
			ui.Divider(c)
			ui.Text(c, i18n.Shared(lang, "desktop.agents.history.filterTime")).FontSize(small).Color(a.colors.Subtle)
			since := h.since
			ui.RadioGroup(c.Part("since")).FillWidth().Gap(2).Items(ui.Start).Children(func() {
				for _, option := range []agentHistorySince{agentSinceAny, agentSinceToday, agentSinceWeek, agentSinceMonth} {
					if ui.Radio(c.KeyInt(int(option)), &since, option, agentSinceLabel(lang, option)).Changed() {
						c.After(func() {
							a.agentsView.history.since = since
							a.loadAgentHistory(p)
						})
					}
				}
			})
			ui.Row(c).FillWidth().Justify(ui.End).Children(func() {
				if ui.Button(c.Key("reset"), i18n.Shared(lang, "desktop.agents.history.filterReset")).Outline().Disabled(h.filtersActive() == 0).Clicked() {
					c.After(func() {
						h := &a.agentsView.history
						h.hidden, h.since = nil, agentSinceAny
						a.loadAgentHistory(p)
					})
				}
			})
		})
	})
	if !open {
		h.popup = agentPopupNone
	}
}

// agentSinceLabel names a choice of how recent the sessions listed are.
func agentSinceLabel(lang i18n.Language, since agentHistorySince) string {
	switch since {
	case agentSinceToday:
		return i18n.Shared(lang, "desktop.agents.history.sinceToday")
	case agentSinceWeek:
		return i18n.Shared(lang, "desktop.agents.history.sinceWeek")
	case agentSinceMonth:
		return i18n.Shared(lang, "desktop.agents.history.sinceMonth")
	}
	return i18n.Shared(lang, "desktop.agents.history.sinceAny")
}

// agentHistoryChip declares a small borderless button with an icon (or none) and a label, a
// chevron after it when it opens a menu, and reports it so the caller takes its click.
func (a *App) agentHistoryChip(c ui.C, label string, icon *gfx.Icon, chevron, open bool) ui.Box {
	metrics := a.theme.Metrics
	focused := components.ButtonRecipe(a.theme, components.ButtonGhost, gfx.State{FocusVisible: true})
	chip := ui.ButtonBase(c, label).Height(agentHistoryChipHeight).Shrink(0).PadX(6).Gap(4).Radius(6).Items(ui.Center).
		Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active)).
		Focus(ui.Look{}.Ring(focused.RingWidth, focused.Ring))
	if open {
		chip = chip.Background(a.colors.Active)
	}
	chip.Children(func() {
		if icon != nil {
			ui.Icon(c, *icon).Size(14, 14).Color(a.colors.Subtle).Shrink(0)
		}
		ui.Text(c, label).FontSize(metrics.FontSizeS).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
		if chevron {
			ui.Icon(c, icons.ChevronDown).Size(12, 12).Color(a.colors.Subtle).Shrink(0)
		}
	})
	return chip
}

// agentHistoryScope declares the switch of the directories listed: the open folder, its
// repository with every worktree, or all of them.
func (a *App) agentHistoryScope(c ui.C, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	metrics := a.theme.Metrics
	focused := components.ButtonRecipe(a.theme, components.ButtonGhost, gfx.State{FocusVisible: true})
	scopes := []struct {
		scope       agentHistoryScope
		label, help string
	}{
		{agentScopeWorkspace, i18n.Shared(lang, "desktop.agents.history.scopeWorkspace"), i18n.Shared(lang, "desktop.agents.history.scopeWorkspaceHelp")},
		{agentScopeProject, i18n.Shared(lang, "desktop.agents.history.scopeProject"), i18n.Shared(lang, "desktop.agents.history.scopeProjectHelp")},
		{agentScopeAll, i18n.Shared(lang, "desktop.agents.history.scopeAll"), i18n.Shared(lang, "desktop.agents.history.scopeAllHelp")},
	}
	ui.Row(c).FillWidth().Shrink(0).PadSides(0, agentHistoryPadX, 8, agentHistoryPadX).Children(func() {
		ui.Row(c).FillWidth().Pad(2).Gap(2).Radius(8).Border(1, a.colors.Line).Children(func() {
			for _, option := range scopes {
				label := option.label
				chosen := h.scope == option.scope
				segment := ui.ButtonBase(c.KeyInt(int(option.scope)), label).Grow(1).Shrink(1).MinWidth(0).Height(agentHistorySegmentHeight).
					Radius(6).Items(ui.Center).Justify(ui.Center).PadX(6).Tooltip(option.help).
					Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active)).
					Focus(ui.Look{}.Ring(focused.RingWidth, focused.Ring))
				weight := float32(gfx.WeightRegular)
				if chosen {
					segment = segment.Background(a.colors.Active).Border(1, a.colors.Line)
					weight = gfx.WeightMedium
				}
				segment.Children(func() {
					ui.Text(c, label).FontSize(metrics.FontSizeS + 1).Weight(weight).Color(a.colors.Text).Ellipsis()
				})
				if segment.Clicked() && !chosen {
					scope := option.scope
					c.After(func() {
						a.performed("agents.history.scope", surfaceButton)
						a.agentsView.history.scope = scope
						a.loadAgentHistory(p)
					})
				}
			}
		})
	})
}

// agentHistorySearch declares the search field: Return searches, clearing it lists the
// sessions again.
func (a *App) agentHistorySearch(c ui.C, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	ui.Row(c).FillWidth().Shrink(0).PadSides(0, agentHistoryPadX, 6, agentHistoryPadX).Children(func() {
		field := ui.TextField(c.Key("query"), &h.query, i18n.Shared(lang, "desktop.agents.history.search"),
			i18n.Shared(lang, "desktop.agents.history.searchPlaceholder")).Icon(icons.Search).FillWidth().Shrink(1).MinWidth(0)
		if h.query != "" {
			field = field.Action(icons.X, i18n.Shared(lang, "native.clearSearch"))
		}
		switch {
		case field.ActionClicked():
			c.After(func() {
				a.agentsView.history.query = ""
				a.loadAgentHistory(p)
			})
		case field.Submitted():
			c.After(func() {
				a.performed("agents.history.search", surfaceShortcut)
				a.loadAgentHistory(p)
			})
		case field.Changed() && strings.TrimSpace(h.query) == "" && h.searching():
			c.After(func() { a.loadAgentHistory(p) })
		}
	})
}

// agentHistoryStatus declares what the last refresh did, and, opened from its time, what it
// read of each agent.
func (a *App) agentHistoryStatus(c ui.C, lang i18n.Language) {
	h := &a.agentsView.history
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Shrink(0).Children(func() {
		ui.Row(c).FillWidth().Height(30).PadX(agentHistoryPadX).Gap(6).Items(ui.Center).Children(func() {
			switch {
			case h.refreshing:
				ui.Spinner(c).Size(12, 12)
				ui.Text(c, i18n.Shared(lang, "desktop.agents.history.refreshing")).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1)
			case h.refreshedAt.IsZero():
				ui.Icon(c, icons.Clock).Size(14, 14).Color(a.colors.Subtle).Shrink(0)
				ui.Text(c, i18n.Shared(lang, "desktop.agents.history.cached")).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1)
			case h.refreshFailed():
				ui.Icon(c, icons.CircleAlert).Size(14, 14).Color(a.colors.Warning).Shrink(0)
				ui.Text(c, i18n.Shared(lang, "desktop.agents.history.refreshPartial")).FontSize(small).Color(a.colors.Text).Ellipsis().Shrink(1)
			default:
				ui.Icon(c, icons.Check).Size(14, 14).Color(a.colors.Subtle).Shrink(0)
				ui.Text(c, i18n.Shared(lang, "desktop.agents.history.refreshed")).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1)
			}
			ui.Spacer(c)
			if !h.refreshedAt.IsZero() && !h.refreshing {
				label := agentRelativeTime(lang, time.Now(), h.refreshedAt)
				when := a.agentHistoryChip(c.Part("when"), label, nil, true, h.statusOpen).
					Tooltip(i18n.Shared(lang, "desktop.agents.history.refreshDetails"))
				if when.Clicked() {
					c.After(func() { a.agentsView.history.statusOpen = !a.agentsView.history.statusOpen })
				}
			}
		})
		if h.statusOpen && !h.refreshing {
			ui.Column(c).FillWidth().PadSides(0, agentHistoryPadX, 6, agentHistoryPadX+20).Gap(3).Children(func() {
				for _, result := range h.syncs {
					line := i18n.SharedFormat(lang, "desktop.agents.history.refreshAgent", map[string]string{
						"agent": result.agent, "listed": strconv.Itoa(result.report.FilesListed), "read": strconv.Itoa(result.report.FilesRead),
					})
					color := a.colors.Subtle
					if result.failure != "" {
						line = i18n.SharedFormat(lang, "desktop.agents.history.refreshAgentFailed", map[string]string{"agent": result.agent, "reason": result.failure})
						color = a.colors.Warning
					}
					ui.Wrap(c, line).FontSize(small).Color(color)
				}
			})
		}
		ui.Divider(c)
	})
}

// agentHistoryCount declares how many sessions or results the tab lists, and the order chooser.
func (a *App) agentHistoryCount(c ui.C, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	metrics := a.theme.Metrics
	ui.Column(c).FillWidth().Shrink(0).Children(func() {
		ui.Row(c).FillWidth().Height(34).PadX(agentHistoryPadX).Gap(6).Items(ui.Center).Children(func() {
			count := "…"
			if h.loaded {
				count = agentHistoryCountLabel(lang, h.searching(), h.total)
			}
			ui.Text(c, count).FontSize(metrics.FontSizeM).Weight(gfx.WeightSemibold).Color(a.colors.Text).Ellipsis().Shrink(1)
			if h.loading {
				ui.Spinner(c).Size(12, 12)
			}
			ui.Spacer(c)
			order := a.agentHistoryChip(c.Part("order"), agentOrderLabel(lang, h.shownOrder(), h.searching()), nil, true, h.popup == agentPopupOrder).
				Tooltip(i18n.Shared(lang, "desktop.agents.history.orderHelp"))
			if order.Clicked() {
				c.After(func() { a.agentsView.history.popup = agentPopupOrder })
			}
			a.agentHistoryOrderMenu(c.Part("order-menu"), p, order, lang)
		})
		ui.Row(c).FillWidth().Height(2).Background(a.colors.Line)
	})
}

// agentHistoryCountLabel is the count of the sessions or search results listed.
func agentHistoryCountLabel(lang i18n.Language, searching bool, count uint64) string {
	n := strconv.FormatUint(count, 10)
	switch {
	case searching && count == 1:
		return i18n.SharedFormat(lang, "desktop.agents.history.resultsOne", map[string]string{"count": n})
	case searching:
		return i18n.SharedFormat(lang, "desktop.agents.history.results", map[string]string{"count": n})
	case count == 1:
		return i18n.SharedFormat(lang, "desktop.agents.history.sessionsOne", map[string]string{"count": n})
	}
	return i18n.SharedFormat(lang, "desktop.agents.history.sessions", map[string]string{"count": n})
}

// agentOrderLabel names an order: the latest is the latest activity in the list and the newest
// match in search results.
func agentOrderLabel(lang i18n.Language, order agentHistoryOrder, searching bool) string {
	switch {
	case order == agentOrderStarted:
		return i18n.Shared(lang, "desktop.agents.history.orderStarted")
	case order == agentOrderLatest && searching:
		return i18n.Shared(lang, "desktop.agents.history.orderMatched")
	}
	return i18n.Shared(lang, "desktop.agents.history.orderUpdated")
}

// agentHistoryOrderMenu declares the orders offered under the order chooser: search results
// add their newest match.
func (a *App) agentHistoryOrderMenu(c ui.C, p *project, anchor ui.Box, lang i18n.Language) {
	h := &a.agentsView.history
	if h.popup != agentPopupOrder {
		return
	}
	orders := []agentHistoryOrder{agentOrderLatest, agentOrderStarted}
	if h.searching() {
		orders = []agentHistoryOrder{agentOrderLatest, agentOrderUpdated, agentOrderStarted}
	}
	shown := h.shownOrder()
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		for _, order := range orders {
			if menu.Item(agentOrderLabel(lang, order, h.searching())).Checked(order == shown).Clicked() {
				c.After(func() {
					a.agentsView.history.popup = agentPopupNone
					a.chooseAgentHistoryOrder(p, order)
				})
			}
		}
	})
	if !open {
		h.popup = agentPopupNone
	}
}

// agentHistoryBody declares the list, or why it shows nothing.
func (a *App) agentHistoryBody(c ui.C, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	switch {
	case h.failure != "":
		a.panelMessage(c.Part("failure"), i18n.SharedFormat(lang, "desktop.agents.history.failed", map[string]string{"reason": h.failure}), a.colors.Warning)
	case !h.loaded:
		a.panelMessage(c.Part("loading"), i18n.Shared(lang, "desktop.agents.history.loading"), a.colors.Subtle)
	case len(h.sessions) == 0 && len(h.hidden) > 0 && len(h.hidden) >= len(a.agentsView.readableAgents()):
		a.panelMessage(c.Part("none"), i18n.Shared(lang, "desktop.agents.history.allHidden"), a.colors.Subtle)
	case len(h.sessions) == 0:
		a.panelMessage(c.Part("none"), i18n.Shared(lang, "desktop.agents.history.none"), a.colors.Subtle)
	default:
		a.agentHistoryList(c.Part("list"), p, lang)
	}
}

// agentHistoryList declares the rows: each directory's heading, which collapses it, and its
// sessions, which open their record on a click or Return.
func (a *App) agentHistoryList(c ui.C, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	rows := h.rows
	home, _ := os.UserHomeDir()
	if h.list.Header == nil {
		h.list.Header = h.isEndSpace
	}
	ui.List(c, &h.list, len(rows)+1, func(row ui.ListRow) {
		if row.Index >= len(rows) {
			row.Element.FillWidth().Height(agentHistoryEndSpace)
			return
		}
		switch item := rows[row.Index]; item.kind {
		case agentRowGroup:
			a.agentHistoryGroupRow(row, item, home, lang)
		case agentRowSession:
			a.agentHistorySessionRow(row, p, h.sessions[item.session], lang)
		default:
			a.agentHistoryMoreRow(row, p, lang)
		}
	}).Label(i18n.Shared(lang, "desktop.agents.history")).Scrollbars().Grow(1).Shrink(1).MinHeight(0).FillWidth()
	if index, ok := h.list.Submitted(); ok && index < len(rows) {
		switch item := rows[index]; item.kind {
		case agentRowGroup:
			cwd := item.cwd
			c.After(func() { a.agentsView.history.toggleGroup(cwd) })
		case agentRowSession:
			session := h.sessions[item.session]
			c.After(func() { a.openHistorySession(p, session) })
		}
	}
}

// agentHistoryGroupRow declares a directory's heading: a chevron, its last two path components and
// how many sessions it has; a click collapses or expands it.
func (a *App) agentHistoryGroupRow(row ui.ListRow, item agentHistoryRow, home string, lang i18n.Language) {
	h := &a.agentsView.history
	metrics := a.theme.Metrics
	collapsed := h.collapsed[item.cwd]
	chevron := icons.ChevronDown
	if collapsed {
		chevron = icons.ChevronRight
	}
	tooltip := agentHomePath(item.cwd, home)
	if tooltip == "" {
		tooltip = i18n.Shared(lang, "desktop.agents.history.noDirectory")
	}
	row.Element.FillWidth().PadSides(10, agentHistoryPadX, 6, agentHistoryPadX-4).Gap(4).Items(ui.Center).Tooltip(tooltip).Children(func() {
		ui.Icon(row.C, chevron).Size(14, 14).Color(a.colors.Subtle).Shrink(0)
		ui.Text(row.C, agentGroupLabel(lang, item.cwd, home)).FontSize(metrics.FontSizeM).Weight(gfx.WeightSemibold).
			Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
		ui.Spacer(row.C)
		ui.Row(row.C).Shrink(0).Height(18).PadX(7).Radius(9).Border(1, a.colors.Line).Background(a.colors.Editor).Items(ui.Center).Children(func() {
			ui.Text(row.C, strconv.FormatUint(h.groupCount(item), 10)).FontSize(metrics.FontSizeS - 1).Color(a.colors.Subtle)
		})
	})
	if row.Element.Clicked() {
		cwd := item.cwd
		row.C.After(func() { a.agentsView.history.toggleGroup(cwd) })
	}
}

// agentHistorySessionRow declares a session: its title with the details and menu buttons, a
// preview of its last message (or of the match a search found), and its agent, size, age and
// model; a click opens its record.
func (a *App) agentHistorySessionRow(row ui.ListRow, p *project, session agents.RecordedSession, lang i18n.Language) {
	h := &a.agentsView.history
	metrics := a.theme.Metrics
	key := agentSessionKey(session.Agent, session.SessionID)
	expanded := h.expanded[key]
	title := session.Title
	if title == "" {
		title = session.SessionID
	}
	line := a.colors.Line
	row.Element.FillWidth().PadSides(9, agentHistoryPadX-4, 10, agentHistoryPadX).DrawOver(func(ctx *ui.DrawContext) {
		r := ctx.Rect
		ctx.Canvas.Fill(gfx.Rect{X: r.X, Y: r.Y + r.Height - 1, Width: r.Width, Height: 1}, line)
	}).Children(func() {
		ui.Column(row.C).Grow(1).Shrink(1).MinWidth(0).Gap(4).Children(func() {
			ui.Row(row.C).FillWidth().Gap(2).Items(ui.Center).Children(func() {
				ui.Text(row.C, title).FontSize(metrics.FontSizeM).Weight(gfx.WeightSemibold).Color(a.colors.Text).
					Ellipsis().Grow(1).Shrink(1).MinWidth(0)
				expandLabel, expandIcon := i18n.Shared(lang, "desktop.agents.history.showDetails"), icons.ChevronDown
				if expanded {
					expandLabel, expandIcon = i18n.Shared(lang, "desktop.agents.history.hideDetails"), icons.ChevronUp
				}
				if ui.Button(row.C.Key("details"), expandLabel).Icon(expandIcon).IconOnly().Ghost().Size(20, 20).Tooltip(expandLabel).Clicked() {
					row.C.After(func() { a.agentsView.history.toggleExpanded(key) })
				}
				more := ui.Button(row.C.Key("more"), i18n.Shared(lang, "desktop.agents.history.moreActions")).Icon(icons.Ellipsis).IconOnly().Ghost().
					Size(20, 20).Tooltip(i18n.Shared(lang, "desktop.agents.history.moreActions"))
				if h.menu == key {
					more = more.Background(a.colors.Active)
				}
				if more.Clicked() {
					row.C.After(func() { a.agentsView.history.menu = key })
				}
				a.agentHistorySessionMenu(row.C.Part("menu"), p, more, session, lang)
			})
			if !h.compact {
				a.agentHistoryPreview(row.C.Part("preview"), session, lang)
			}
			a.agentHistoryMeta(row.C.Part("meta"), session, lang)
			if expanded {
				a.agentHistoryDetails(row.C.Part("expanded"), p, session, lang)
			}
		})
	})
	if row.Element.Clicked() {
		row.C.After(func() { a.openHistorySession(p, session) })
	}
}

// openHistorySession opens a row's record: at the match a search found in it, else from its end.
func (a *App) openHistorySession(p *project, session agents.RecordedSession) {
	h := &a.agentsView.history
	if hit, ok := h.hits[agentSessionKey(session.Agent, session.SessionID)]; ok && h.searching() {
		a.openRecordedHit(p, hit)
		return
	}
	a.openRecordedSession(p, session)
}

// agentHistorySessionMenu declares a session's menu under its ⋯ button, while it is open.
func (a *App) agentHistorySessionMenu(c ui.C, p *project, anchor ui.Box, session agents.RecordedSession, lang i18n.Language) {
	h := &a.agentsView.history
	if h.menu != agentSessionKey(session.Agent, session.SessionID) {
		return
	}
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		if menu.Item(i18n.Shared(lang, "desktop.agents.history.openRecord")).Icon(icons.Eye).Clicked() {
			c.After(func() {
				a.agentsView.history.menu = ""
				a.openHistorySession(p, session)
			})
		}
		if menu.Item(i18n.Shared(lang, "desktop.agents.history.resume")).Icon(icons.Play).Disabled(!a.canResume(session.PluginID, session.AgentID)).Clicked() {
			c.After(func() {
				a.agentsView.history.menu = ""
				a.resumeRecorded(p, session.PluginID, session.AgentID, session.SessionID)
			})
		}
		menu.Separator()
		if menu.Item(i18n.Shared(lang, "desktop.agents.history.copySessionID")).Icon(icons.Copy).Clicked() {
			c.After(func() {
				a.agentsView.history.menu = ""
				a.copyAgentHistoryText(session.SessionID)
			})
		}
		if menu.Item(i18n.Shared(lang, "desktop.agents.history.copyDirectory")).Icon(icons.Folder).Disabled(session.Cwd == "").Clicked() {
			c.After(func() {
				a.agentsView.history.menu = ""
				a.copyAgentHistoryText(session.Cwd)
			})
		}
	})
	if !open {
		h.menu = ""
	}
}

// copyAgentHistoryText puts a session's ID or directory on the clipboard.
func (a *App) copyAgentHistoryText(text string) {
	if err := app.SetClipboardText(text); err != nil {
		a.operationFailed("clipboard_copy", err)
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.agents.history.copyFailed", map[string]string{"reason": err.Error()}))
		return
	}
	a.performed("agents.history.copy", surfaceButton)
}

// agentHistoryPreview declares two lines of a session's preview, its speaker in bold first, the
// search's query marked in it; the lines stay empty while the preview is read.
func (a *App) agentHistoryPreview(c ui.C, session agents.RecordedSession, lang i18n.Language) {
	h := &a.agentsView.history
	key, ok := h.previewKeyOf(session)
	if !ok {
		return
	}
	preview, done := h.previews.lookup(key)
	if !done {
		h.previews.want(key)
	} else if preview.text == "" {
		return
	}
	size := a.theme.Metrics.FontSizeS + 1
	lineHeight := agentPreviewLineHeight(size)
	prefix := ""
	if done {
		prefix = i18n.SharedFormat(lang, "desktop.agents.history.previewPrefix", map[string]string{
			"role": agentRecordRole(lang, agents.RecordedMessage{Role: preview.role, ToolName: preview.toolName}),
		})
	}
	query := ""
	if h.searching() {
		query = h.searched
	}
	text, strong, plain, mark := preview.text, a.colors.Text, a.colors.Text.WithAlpha(agentPreviewTextAlpha), a.colors.Selection
	ui.Row(c).FillWidth().Height(2 * lineHeight).Label(strings.TrimSpace(prefix + " " + preview.text)).Draw(func(ctx *ui.DrawContext) {
		if text == "" {
			return
		}
		canvas, r := ctx.Canvas, ctx.Rect
		bold := gfx.TextStyle{Size: size, Weight: gfx.WeightSemibold, Color: strong}
		regular := gfx.TextStyle{Size: size, Weight: gfx.WeightRegular, Color: plain}
		prefixWidth := canvas.TextWidthWeight(prefix, size, bold.Weight) + agentPreviewPrefixGap
		first, rest := agentPreviewLines(canvas, prefixWidth, r.Width, text, size)
		top := gfx.Rect{X: r.X, Y: r.Y, Width: r.Width, Height: lineHeight}
		canvas.Label(prefix, top, bold)
		top.X, top.Width = top.X+prefixWidth, max(0, top.Width-prefixWidth)
		if query != "" {
			canvas.LabelHighlighted(first, top, regular, gfx.AlignLeft, query, mark)
		} else {
			canvas.Label(first, top, regular)
		}
		if rest != "" {
			canvas.LabelEllipsis(rest, gfx.Rect{X: r.X, Y: r.Y + lineHeight, Width: r.Width, Height: lineHeight}, regular)
		}
	})
}

// agentPreviewLineHeight is the height of a preview line in a font size.
func agentPreviewLineHeight(size float32) float32 {
	return float32(int(size*agentPreviewLineFactor + 0.99))
}

// agentTextMeasure measures a line of text, as gfx.Canvas does.
type agentTextMeasure interface {
	TextWidthWeight(value string, size, weight float32) float32
	TextOffsetAt(value string, size, weight, x float32) int
}

// agentPreviewLines splits a preview into its first line, after a speaker prefixWidth wide, and
// the rest, which the second line shows cut with an ellipsis. The first line breaks after the
// last space that fits when the cut would split a word of a script that spaces its words, and
// anywhere in one that does not (Chinese, Japanese).
func agentPreviewLines(measure agentTextMeasure, prefixWidth, width float32, text string, size float32) (string, string) {
	room := width - prefixWidth
	if room <= 0 {
		return "", text
	}
	if measure.TextWidthWeight(text, size, gfx.WeightRegular) <= room {
		return text, ""
	}
	cut := measure.TextOffsetAt(text, size, gfx.WeightRegular, room)
	for cut > 0 && measure.TextWidthWeight(text[:cut], size, gfx.WeightRegular) > room {
		_, n := utf8.DecodeLastRuneInString(text[:cut])
		cut -= n
	}
	if cut <= 0 {
		return "", text
	}
	before, _ := utf8.DecodeLastRuneInString(text[:cut])
	after, _ := utf8.DecodeRuneInString(text[cut:])
	if agentWordRune(before) && agentWordRune(after) {
		if space := strings.LastIndexByte(text[:cut], ' '); space > 0 {
			cut = space
		}
	}
	return strings.TrimRight(text[:cut], " "), strings.TrimLeft(text[cut:], " ")
}

// agentWordRune reports whether r belongs to a word that spaces separate: a letter or digit of
// a script other than Han, Hiragana, Katakana and Hangul, which break between any characters.
func agentWordRune(r rune) bool {
	if !unicode.IsLetter(r) && !unicode.IsDigit(r) {
		return false
	}
	return !unicode.In(r, unicode.Han, unicode.Hiragana, unicode.Katakana, unicode.Hangul)
}

// agentHistoryMeta declares a session's agent with its icon, and how many messages and subagent
// threads it holds, how long ago it was last active and its model. The line draws its words
// itself so a narrow panel takes their room in a fixed order (agentMetaWidths); a part it cuts
// shows in full under the pointer.
func (a *App) agentHistoryMeta(c ui.C, session agents.RecordedSession, lang i18n.Language) {
	small := a.theme.Metrics.FontSizeS
	name, stats, model := a.agentDisplayName(session.Agent), agentSessionStats(lang, session, time.Now()), ""
	if session.Model != "" {
		model = "· " + session.Model
	}
	label := strings.Join(slices.DeleteFunc([]string{name, stats, session.Model}, func(s string) bool { return s == "" }), " · ")
	strong, plain := a.colors.Text, a.colors.Subtle
	ui.Row(c).FillWidth().Gap(agentHistoryMetaGap).Items(ui.Center).Children(func() {
		ui.Icon(c, a.agentIcon(session.Agent)).Size(agentHistoryMetaIcon, agentHistoryMetaIcon).Color(a.colors.Subtle).Shrink(0)
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Height(agentPreviewLineHeight(small)).Label(label).Draw(func(ctx *ui.DrawContext) {
			canvas, r := ctx.Canvas, ctx.Rect
			styles := [3]gfx.TextStyle{
				{Size: small, Weight: gfx.WeightMedium, Color: strong},
				{Size: small, Weight: gfx.WeightRegular, Color: plain},
				{Size: small, Weight: gfx.WeightRegular, Color: plain},
			}
			parts := [3]string{name, stats, model}
			var natural [3]float32
			for i, part := range parts {
				if part != "" {
					natural[i] = canvas.TextWidthWeight(part, small, styles[i].Weight)
				}
			}
			widths := agentMetaWidths(r.Width, agentHistoryMetaGap, agentHistoryNameMin, agentHistoryModelMin, natural)
			// A part drawn cut ends at its ellipsis: the next starts a gap after it, and may use
			// the room the cut left.
			x, slack := r.X, float32(0)
			for i, part := range parts {
				if widths[i] <= 0 {
					continue
				}
				width := min(natural[i], widths[i]+slack)
				canvas.LabelEllipsis(part, gfx.Rect{X: x, Y: r.Y, Width: width, Height: r.Height}, styles[i])
				used := canvas.TextWidthWeight(canvas.FitLine(part, small, styles[i].Weight, width), small, styles[i].Weight)
				x, slack = x+used+agentHistoryMetaGap, max(0, width-used)
			}
		})
	})
}

// agentMetaWidths shares room among a meta line's agent name, counts and age, and model, given
// their natural widths and gap apart (a part with no width is left out). A line too narrow for
// all of them takes the name down to nameMin first, then the model, which drops out rather
// than show less than modelMin, then the counts and age, and last the rest of the name.
func agentMetaWidths(room, gap, nameMin, modelMin float32, natural [3]float32) [3]float32 {
	w := natural
	var used, parts float32
	for _, width := range w {
		if width > 0 {
			used += width
			parts++
		}
	}
	if parts > 1 {
		used += gap * (parts - 1)
	}
	over := used - room
	if over <= 0 {
		return w
	}
	cut := min(over, max(0, w[0]-nameMin))
	w[0], over = w[0]-cut, over-cut
	if over > 0 && w[2] > 0 {
		if w[2]-over >= modelMin {
			w[2], over = w[2]-over, 0
		} else {
			w[2], over = 0, over-w[2]-gap
		}
	}
	if over > 0 {
		cut = min(over, w[1])
		w[1], over = w[1]-cut, over-cut
	}
	if over > 0 {
		w[0] = max(0, w[0]-over)
	}
	return w
}

// agentSessionStats is a session's message and subagent counts and how long ago it was active.
func agentSessionStats(lang i18n.Language, session agents.RecordedSession, now time.Time) string {
	var parts []string
	if session.MessageCount > 0 {
		parts = append(parts, agentCount(lang, agentCountMessages, session.MessageCount))
	}
	if session.SubagentCount > 0 {
		parts = append(parts, agentCount(lang, agentCountSubagents, session.SubagentCount))
	}
	if session.UpdatedAtMs > 0 {
		parts = append(parts, agentRelativeTime(lang, now, time.UnixMilli(session.UpdatedAtMs)))
	}
	return strings.Join(parts, " · ")
}

// agentCounted is what a count in the history counts.
type agentCounted uint8

const (
	agentCountMessages agentCounted = iota
	agentCountSubagents
	agentCountMinutesAgo
	agentCountHoursAgo
	agentCountDaysAgo
)

// agentCount says a count of what, in the singular for exactly one.
func agentCount(lang i18n.Language, what agentCounted, count uint64) string {
	n, one := strconv.FormatUint(count, 10), count == 1
	switch {
	case what == agentCountMessages && one:
		return i18n.SharedFormat(lang, "desktop.agents.history.messagesOne", map[string]string{"count": n})
	case what == agentCountMessages:
		return i18n.SharedFormat(lang, "desktop.agents.history.messages", map[string]string{"count": n})
	case what == agentCountSubagents && one:
		return i18n.SharedFormat(lang, "desktop.agents.history.subagentsOne", map[string]string{"count": n})
	case what == agentCountSubagents:
		return i18n.SharedFormat(lang, "desktop.agents.history.subagents", map[string]string{"count": n})
	case what == agentCountMinutesAgo && one:
		return i18n.SharedFormat(lang, "desktop.agents.history.minutesAgoOne", map[string]string{"count": n})
	case what == agentCountMinutesAgo:
		return i18n.SharedFormat(lang, "desktop.agents.history.minutesAgo", map[string]string{"count": n})
	case what == agentCountHoursAgo && one:
		return i18n.SharedFormat(lang, "desktop.agents.history.hoursAgoOne", map[string]string{"count": n})
	case what == agentCountHoursAgo:
		return i18n.SharedFormat(lang, "desktop.agents.history.hoursAgo", map[string]string{"count": n})
	case one:
		return i18n.SharedFormat(lang, "desktop.agents.history.daysAgoOne", map[string]string{"count": n})
	}
	return i18n.SharedFormat(lang, "desktop.agents.history.daysAgo", map[string]string{"count": n})
}

// agentHistoryDetails declares a session's details, opened from its chevron: where it ran, its
// ID, when it started and was last active, and the buttons that open and resume it.
func (a *App) agentHistoryDetails(c ui.C, p *project, session agents.RecordedSession, lang i18n.Language) {
	small := a.theme.Metrics.FontSizeS
	home, _ := os.UserHomeDir()
	ui.Column(c).FillWidth().Gap(3).PadSides(4, 0, 0, 0).Children(func() {
		detail := func(label, value string, mono bool) {
			if value == "" {
				return
			}
			ui.Row(c).FillWidth().Gap(8).Items(ui.Start).Children(func() {
				ui.Text(c, label).FontSize(small).Color(a.colors.Subtle).Width(72).Shrink(0).Ellipsis()
				text := ui.Text(c, value).FontSize(small).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
				if mono {
					text.Mono()
				}
			})
		}
		detail(i18n.Shared(lang, "desktop.agents.history.detailAgent"), a.agentDisplayName(session.Agent), false)
		detail(i18n.Shared(lang, "desktop.agents.history.detailModel"), session.Model, false)
		detail(i18n.Shared(lang, "desktop.agents.history.detailDirectory"), agentHomePath(session.Cwd, home), false)
		detail(i18n.Shared(lang, "desktop.agents.history.detailSession"), session.SessionID, true)
		detail(i18n.Shared(lang, "desktop.agents.history.detailStarted"), agentHistoryTime(session.StartedAtMs), false)
		detail(i18n.Shared(lang, "desktop.agents.history.detailUpdated"), agentHistoryTime(session.UpdatedAtMs), false)
		detail(i18n.Shared(lang, "desktop.agents.history.detailVersion"), session.AgentVersion, false)
		ui.Row(c).FillWidth().Gap(6).PadSides(4, 0, 0, 0).Children(func() {
			if ui.Button(c.Key("open"), i18n.Shared(lang, "desktop.agents.history.openRecord")).Icon(icons.Eye).Outline().Clicked() {
				c.After(func() { a.openHistorySession(p, session) })
			}
			if ui.Button(c.Key("resume"), i18n.Shared(lang, "desktop.agents.history.resume")).Icon(icons.Play).Outline().
				Disabled(!a.canResume(session.PluginID, session.AgentID)).Clicked() {
				c.After(func() { a.resumeRecorded(p, session.PluginID, session.AgentID, session.SessionID) })
			}
		})
	})
}

// agentHistoryTime is a session time in local time, empty when it is not recorded.
func agentHistoryTime(atMs int64) string {
	if atMs <= 0 {
		return ""
	}
	return time.UnixMilli(atMs).Local().Format("2006-01-02 15:04")
}

// agentHistoryMoreRow declares the row after the loaded sessions: it reads the next page as it
// comes into view, and offers to try again when that failed.
func (a *App) agentHistoryMoreRow(row ui.ListRow, p *project, lang i18n.Language) {
	h := &a.agentsView.history
	small := a.theme.Metrics.FontSizeS
	row.Element.FillWidth().PadY(10).Gap(6).Items(ui.Center).Justify(ui.Center).Children(func() {
		if h.moreFailed {
			ui.Text(row.C, i18n.Shared(lang, "desktop.agents.history.moreFailed")).FontSize(small).Color(a.colors.Warning)
			if ui.Button(row.C.Key("retry"), i18n.Shared(lang, "desktop.agents.history.retry")).Outline().Clicked() {
				row.C.After(func() {
					a.agentsView.history.moreFailed = false
					a.loadMoreAgentHistory(p)
				})
			}
			return
		}
		ui.Spinner(row.C).Size(12, 12)
		ui.Text(row.C, i18n.Shared(lang, "desktop.agents.history.loadingMore")).FontSize(small).Color(a.colors.Subtle)
	})
	h.wantsMore = true
}

// agentHistoryDensity declares the floating button at the list's corner that shows or hides
// the previews.
func (a *App) agentHistoryDensity(c ui.C, lang i18n.Language) {
	h := &a.agentsView.history
	if !h.loaded || len(h.sessions) == 0 {
		return
	}
	label := i18n.Shared(lang, "desktop.agents.history.hidePreviews")
	if h.compact {
		label = i18n.Shared(lang, "desktop.agents.history.showPreviews")
	}
	focused := components.ButtonRecipe(a.theme, components.ButtonGhost, gfx.State{FocusVisible: true})
	button := ui.ButtonBase(c, label).Absolute().Right(agentHistoryFloatInset).Bottom(agentHistoryFloatInset).Size(agentHistoryFloatSize, agentHistoryFloatSize).Radius(10).
		Background(a.colors.Editor).Border(1, a.colors.Line).Shadow(gfx.ShadowSM).Items(ui.Center).Justify(ui.Center).
		Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active)).
		Focus(ui.Look{}.Ring(focused.RingWidth, focused.Ring)).Tooltip(label)
	button.Children(func() {
		ui.Icon(c, icons.PanelsTopLeft).Size(16, 16).Color(a.colors.Text)
	})
	if button.Clicked() {
		c.After(func() {
			a.performed("agents.history.density", surfaceButton)
			a.agentsView.history.compact = !a.agentsView.history.compact
		})
	}
}

// agentIcon is an agent's icon: the package icon its manifest declares, read when its plugin was
// configured, else the host icon it names, else the generic agent icon. A package icon's own
// colors stay; the tint paints only what has none.
func (a *App) agentIcon(key string) gfx.Icon {
	v := &a.agentsView
	for _, agent := range v.catalog {
		if agent.Key() != key {
			continue
		}
		for _, plugin := range v.plugins {
			if plugin.PluginID != agent.PluginID {
				continue
			}
			if declaration, ok := plugin.Icons[agent.AgentID]; ok {
				if found, ok := a.pluginIcons.Lookup(plugin.PluginID, declaration); ok {
					return found.For(a.colors.Dark)
				}
			}
		}
		if agent.Icon != nil && agent.Icon.Host != "" {
			return *pluginToolIcon(agent.Icon.Host)
		}
		break
	}
	return icons.Bot
}

// agentRelativeTime says how long before now at was: just now, minutes, hours or days ago, or
// its date when that is a month or more.
func agentRelativeTime(lang i18n.Language, now, at time.Time) string {
	elapsed := now.Sub(at)
	switch {
	case elapsed < time.Minute:
		return i18n.Shared(lang, "desktop.agents.history.justNow")
	case elapsed < time.Hour:
		return agentCount(lang, agentCountMinutesAgo, uint64(elapsed/time.Minute))
	case elapsed < 24*time.Hour:
		return agentCount(lang, agentCountHoursAgo, uint64(elapsed/time.Hour))
	case elapsed < 30*24*time.Hour:
		return agentCount(lang, agentCountDaysAgo, uint64(elapsed/(24*time.Hour)))
	}
	return at.Local().Format("2006-01-02")
}

// agentGroupLabel names a directory heading by its last two path components, ~ for the home
// directory itself.
func agentGroupLabel(lang i18n.Language, cwd, home string) string {
	if cwd == "" {
		return i18n.Shared(lang, "desktop.agents.history.noDirectory")
	}
	if home != "" && strings.TrimRight(cwd, `/\`) == strings.TrimRight(home, `/\`) {
		return "~"
	}
	parts := strings.FieldsFunc(cwd, func(r rune) bool { return r == '/' || r == '\\' })
	switch len(parts) {
	case 0:
		return cwd
	case 1:
		return parts[0]
	}
	return parts[len(parts)-2] + "/" + parts[len(parts)-1]
}

// agentHomePath writes a directory under the home directory from ~, so a tooltip does not show
// the user's name.
func agentHomePath(cwd, home string) string {
	home = strings.TrimRight(home, `/\`)
	if home == "" || cwd == "" {
		return cwd
	}
	if cwd == home {
		return "~"
	}
	if strings.HasPrefix(cwd, home) && strings.ContainsRune(`/\`, rune(cwd[len(home)])) {
		return "~" + cwd[len(home):]
	}
	return cwd
}
