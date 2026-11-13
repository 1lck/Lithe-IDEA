package workbench

import (
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The language server's state in the status bar, the menu that item opens, and the LSP Logs
// tab with the log of each server.
//
// Core owns the session's lifecycle: stateChanged says starting, ready, failed or stopped and
// log events carry what the server and Core reported. This file keeps what the events said
// (the last state and a bounded tail of log lines per server) and shows it; it infers
// nothing from log text.
//
// As in the earlier macOS client, the status bar item opens a menu of the running servers:
// each one's log, restart and stop, the same for all of them, and the plugin page. The log is
// an ordinary tab of the editor area that the menu opens, or selects when the project already
// has it; it is selected, moved, split off and closed like an open file's tab. Its member in a
// tab group is lspLogMember, so a project has at most one; it shows one server at a time.

const (
	// lspLogLines bounds the log lines kept for one server.
	lspLogLines = 500
	// lspLogLineBytes cuts one line, so a server that prints a huge message costs bounded
	// memory; a cut line ends in lspLogCut.
	lspLogLineBytes = 4096
	lspLogCut       = "…"
	// lspLogMember is the member name of the LSP Logs tab in a tab group.
	lspLogMember = "lsp:log"
	// lspLogRow is the height of one log line in the tab, lspLogFont the size of its
	// monospaced text, lspLogPadX the room on either side of a line and lspLogGap the room
	// between a line's level and its message.
	lspLogRow  = 20
	lspLogFont = 12
	lspLogPadX = 10
	lspLogGap  = 6
	// lspLogTab is how many spaces stand for a tab in a log line.
	lspLogTab = "    "
)

// lspLogLine is one line of a server's log. An event whose message has several lines adds
// one lspLogLine for each.
type lspLogLine struct {
	// level is the event's level in upper case, "" when it gave none; it colors the line.
	level string
	// text is the line shown. On the first line of an event that gave a level it starts with
	// that level in brackets, tag bytes long, then a space; tag is 0 on other lines.
	text string
	tag  int
	// width is how wide the line is drawn in the log's font, its level and message apart,
	// measured by the first paint that shows the line; 0 until then.
	width float32
}

// parts splits the line into its level in brackets, "" when it has none, and its message.
func (l lspLogLine) parts() (tag, message string) {
	if l.tag <= 0 || l.tag > len(l.text) {
		return "", l.text
	}
	return l.text[:l.tag], strings.TrimPrefix(l.text[l.tag:], " ")
}

// lspLogState is the state of the LSP Logs tab and of the status bar's server menu.
type lspLogState struct {
	// plugin is the server whose log is shown; empty selects the first.
	plugin string
	// filter keeps the lines that contain it, case-insensitively.
	filter string
	// wrap breaks long lines to the tab's width; otherwise each line stays one row and the
	// rows scroll sideways.
	wrap bool
	list ui.ListState
	// shown is the server the last paint of the tab showed and seen how many lines it had
	// added by then: a new line keeps the list at its end unless the user scrolled away
	// from it, and another server starts its list afresh at its end.
	shown *pluginServer
	seen  uint64
	// menu says the status bar item's menu is open.
	menu bool
}

// recordServerEvent keeps what one session event says about the server, on the window thread.
func (a *App) recordServerEvent(server *pluginServer, event core.BackendEvent) {
	if server == nil || !a.isCurrentPluginServer(server.session.PluginID, server) {
		return
	}
	switch event.Type {
	case "stateChanged":
		if event.State != "" {
			server.state = event.State
			state := event.State
			server.sharedState.Store(&state)
			a.invalidator.Invalidate()
		}
	case "log":
		message := strings.TrimSpace(event.Message)
		if detail := strings.TrimSpace(event.Detail); detail != "" {
			if message != "" {
				message += " "
			}
			message += detail
		}
		if message == "" {
			return
		}
		level := event.Level
		if level == "" {
			level = event.LegacyLevel
		}
		level = strings.ToUpper(strings.TrimSpace(level))
		first := true
		for text := range strings.SplitSeq(message, "\n") {
			text = strings.TrimRight(strings.ReplaceAll(text, "\t", lspLogTab), " \r")
			if text == "" {
				continue
			}
			line := lspLogLine{level: level, text: cutLogLine(text)}
			if first && level != "" {
				line.text, line.tag = "["+level+"] "+line.text, len(level)+2
			}
			first = false
			server.appendLog(line)
		}
		a.invalidator.Invalidate()
	}
}

// cutLogLine cuts text to lspLogLineBytes on a character's boundary and marks the cut.
func cutLogLine(text string) string {
	if len(text) <= lspLogLineBytes {
		return text
	}
	cut := lspLogLineBytes
	for cut > 0 && !utf8.RuneStart(text[cut]) {
		cut--
	}
	return text[:cut] + lspLogCut
}

// appendLog adds a line to the server's log, dropping the oldest past lspLogLines.
func (s *pluginServer) appendLog(line lspLogLine) {
	if len(s.logs) >= lspLogLines {
		copy(s.logs, s.logs[len(s.logs)-lspLogLines+1:])
		s.logs = s.logs[:lspLogLines-1]
	}
	s.logs = append(s.logs, line)
	s.logsAdded++
}

// lspStatusServer is the server the status bar item reads: the selected document's, or while
// the LSP Logs tab is selected the one it shows; nil when none.
func (a *App) lspStatusServer() *pluginServer {
	p := a.project
	if p == nil {
		return nil
	}
	server, _ := a.documentSyncServer(p.selectedDocument(p.docs.group))
	if server == nil && p.selectedLSPLog(p.docs.group) {
		server = lspLogServer(a.lspServers(), a.editor.lsp.plugin)
	}
	return server
}

// lspStatusText is the status bar's reading for the server of lspStatusServer: its state, or
// the problems the servers reported. "" means no server serves the document.
func (a *App) lspStatusText() string {
	if total := a.pluginProblemCount(); total > 0 {
		return a.text.Status.Problems(total)
	}
	server := a.lspStatusServer()
	if server == nil {
		return ""
	}
	return a.lspPhaseText(server)
}

// lspPhase is what a server is doing, as the status bar and its menu say it.
type lspPhase uint8

const (
	lspStarting lspPhase = iota
	lspReady
	lspFailed
	lspStopped
)

// phase is the server's phase from the state Core last reported.
func (s *pluginServer) phase() lspPhase {
	switch {
	case s.state == "failed" || s.state == "error":
		return lspFailed
	case s.state == "stopped":
		return lspStopped
	case s.isReady():
		return lspReady
	}
	return lspStarting
}

// lspPhaseText names the server's phase.
func (a *App) lspPhaseText(server *pluginServer) string {
	language := a.language()
	switch server.phase() {
	case lspReady:
		return i18n.Shared(language, "desktop.status.lspReady")
	case lspFailed:
		return i18n.Shared(language, "desktop.status.lspFailed")
	case lspStopped:
		return i18n.Shared(language, "desktop.status.lspStopped")
	}
	return i18n.Shared(language, "desktop.status.lspStarting")
}

// lspPhaseIcon marks the server's phase in the menu, whose icons take no color, by its shape.
func lspPhaseIcon(server *pluginServer) gfx.Icon {
	switch server.phase() {
	case lspReady:
		return icons.CircleCheck
	case lspFailed:
		return icons.CircleX
	case lspStopped:
		return icons.CircleSlash
	}
	return icons.LoaderCircle
}

// lspStatusColor is the color of the status bar item's dot: the success color for a ready
// server, the warning color while it starts, the danger color when it failed and subdued when
// it stopped or no server serves the document.
func (a *App) lspStatusColor() gfx.Color {
	server := a.lspStatusServer()
	if server == nil {
		return a.colors.Subtle
	}
	switch server.phase() {
	case lspReady:
		return a.colors.Success
	case lspFailed:
		return a.theme.Danger
	case lspStopped:
		return a.colors.Subtle
	}
	return a.colors.Warning
}

// lspServers lists the language servers the window runs, by plugin.
func (a *App) lspServers() []*pluginServer {
	a.pluginServerMu.Lock()
	defer a.pluginServerMu.Unlock()
	servers := make([]*pluginServer, 0, len(a.pluginServers))
	for _, server := range a.pluginServers {
		if server != nil && server.session != nil {
			servers = append(servers, server)
		}
	}
	sort.Slice(servers, func(i, j int) bool { return servers[i].session.PluginID < servers[j].session.PluginID })
	return servers
}

// lspLogServer is the server of servers the LSP Logs tab shows: the one whose plugin is
// plugin, else the first; nil while none runs.
func lspLogServer(servers []*pluginServer, plugin string) *pluginServer {
	for _, server := range servers {
		if server.session.PluginID == plugin {
			return server
		}
	}
	if len(servers) > 0 {
		return servers[0]
	}
	return nil
}

// lspStatusMenu declares the menu the status bar's language server item opens, over the item:
// each running server with its state and version, whose submenu opens its log, restarts it or
// stops it; then the log of the server the item reads, restarting or stopping every server,
// and the plugin page, where language server plugins are installed and set up.
func (a *App) lspStatusMenu(c ui.C, anchor ui.Box) {
	v := &a.editor.lsp
	if !v.menu {
		return
	}
	p := a.project
	if p == nil {
		v.menu = false
		return
	}
	language := a.language()
	viewLogs := i18n.Shared(language, "native.inline.viewLogs")
	servers := a.lspServers()
	ui.Menu(c, anchor, &v.menu, func(menu *ui.MenuItems) {
		menu.Above()
		menu.WidthRange(240, 380)
		menu.Label(i18n.Shared(language, "native.languageServices"))
		if len(servers) == 0 {
			menu.Item(i18n.Shared(language, "native.noRegisteredLanguageServers")).Disabled(true)
		}
		for _, server := range servers {
			id := server.session.PluginID
			description := a.lspPhaseText(server)
			if version := server.session.Version; version != "" {
				description += " · " + version
			}
			menu.Sub(id, func(sub *ui.MenuItems) {
				if sub.Item(viewLogs).Icon(icons.FileText).Clicked() {
					c.After(func() { a.showLSPLog(p, id) })
				}
				if sub.Item(i18n.Shared(language, "desktop.lsp.restartServer")).Icon(icons.RefreshCw).Clicked() {
					c.After(func() {
						a.performed("lsp.server.restart", surfaceMenu)
						a.restartLSPServer(server)
					})
				}
				if sub.Item(i18n.Shared(language, "desktop.lsp.stopServer")).Icon(icons.Square).Clicked() {
					c.After(func() {
						a.performed("lsp.server.stop", surfaceMenu)
						a.stopPluginServer(id)
					})
				}
			}).Icon(lspPhaseIcon(server)).Description(description)
		}
		if len(servers) > 0 {
			menu.Separator()
			if menu.Item(viewLogs).Icon(icons.FileText).Clicked() {
				plugin := ""
				if server := a.lspStatusServer(); server != nil {
					plugin = server.session.PluginID
				}
				c.After(func() { a.showLSPLog(p, plugin) })
			}
			if menu.Item(i18n.Shared(language, "native.restartAllServers")).Icon(icons.RefreshCw).Clicked() {
				c.After(func() {
					a.performed("lsp.servers.restartAll", surfaceMenu)
					for _, server := range servers {
						a.restartLSPServer(server)
					}
				})
			}
			if menu.Item(i18n.Shared(language, "native.stopAllServers")).Icon(icons.Square).Clicked() {
				c.After(func() {
					a.performed("lsp.servers.stopAll", surfaceMenu)
					for _, server := range servers {
						a.stopPluginServer(server.session.PluginID)
					}
				})
			}
		}
		menu.Separator()
		if menu.Item(i18n.Shared(language, "desktop.lsp.managePlugins")).Icon(icons.Settings).Clicked() {
			c.After(func() { a.openPluginSettings(surfaceMenu) })
		}
	})
}

// showLSPLog opens the LSP Logs tab of project p on the server of plugin, or on the one it
// showed last when plugin is empty.
func (a *App) showLSPLog(p *project, plugin string) {
	if a.project != p {
		return
	}
	if plugin != "" {
		a.editor.lsp.plugin = plugin
	}
	a.performed("lsp.log.open", surfaceMenu)
	a.openLSPLog(p)
}

// restartLSPServer stops the server and starts it again for the workspace it serves.
func (a *App) restartLSPServer(server *pluginServer) {
	workspace := ""
	if server.project != nil {
		workspace = server.project.root
	}
	a.restartSettingsPlugin(server.session.PluginID, server.session.Version, "project", workspace)
}

// openLSPLog shows the LSP Logs tab: the project's own when it has one, else a new one in
// the group a file opens in.
func (a *App) openLSPLog(p *project) {
	if p.terms.bench.GroupOf(lspLogMember) == nil {
		if _, ok := a.placeEditorMember(p, lspLogMember); !ok {
			return
		}
	}
	a.selectLSPLog(p)
}

// selectLSPLog shows the LSP Logs tab in its group; files open in its group after it.
func (a *App) selectLSPLog(p *project) {
	g := p.terms.bench.GroupOf(lspLogMember)
	if g == nil {
		return
	}
	if g.Selected != lspLogMember && !a.reduceTerminals(p, p.terms.bench, core.ActivateEditor(g.ID, lspLogMember)) {
		return
	}
	p.docs.group = g.ID
	a.focus = focusTarget{}
}

// closeLSPLog closes the LSP Logs tab; its group shows the neighbouring tab. The servers keep
// their lines, so the tab opened again shows them.
func (a *App) closeLSPLog(p *project) {
	g := p.terms.bench.GroupOf(lspLogMember)
	if g == nil {
		return
	}
	group := g.ID
	if !a.reduceTerminals(p, p.terms.bench, core.CloseEditor(group, lspLogMember, emptyPolicy(group), core.SelectAdjacent)) {
		return
	}
	a.editor.lsp.shown, a.editor.lsp.seen = nil, 0
	a.focusSelected(p, group)
}

// selectedLSPLog says group shows the LSP Logs tab.
func (p *project) selectedLSPLog(group string) bool {
	g := p.terms.bench.Group(group)
	return g != nil && g.Selected == lspLogMember
}

// lspLogView is the LSP Logs tab's body: a bar with the server shown, the filter, the
// server's state and what can be done with it, over the server's lines, newest last.
func (a *App) lspLogView(c ui.C) {
	v := &a.editor.lsp
	language := a.language()
	servers := a.lspServers()
	shown := lspLogServer(servers, v.plugin)
	if shown != nil {
		v.plugin = shown.session.PluginID
	}
	ui.Column(c.Key("lsp-log")).Fill().Background(a.colors.Panel).Children(func() {
		if shown == nil {
			v.shown, v.seen = nil, 0
			a.lspLogMessage(c, i18n.Shared(language, "desktop.lsp.noServers"))
			return
		}
		a.lspLogBar(c, servers, shown)
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		measureLogLines(c.Canvas(), shown.logs)
		lines := filterLogLines(shown.logs, v.filter)
		if v.shown != shown {
			v.shown, v.seen, v.list = shown, 0, ui.ListState{}
		}
		if len(lines) == 0 {
			// The list is not declared, so the lines that come next start it at its end.
			v.seen, v.list = 0, ui.ListState{}
			if len(shown.logs) > 0 && strings.TrimSpace(v.filter) != "" {
				a.lspLogMessage(c, i18n.Shared(language, "desktop.lsp.noFilteredLog"))
			} else {
				a.lspLogMessage(c, i18n.Shared(language, "desktop.lsp.noLog"))
			}
			return
		}
		if v.seen != shown.logsAdded {
			if v.seen == 0 || v.list.AtEnd() {
				v.list.ScrollToEnd()
			}
			v.seen = shown.logsAdded
		}
		// Unwrapped, every row is as wide as the widest line, so the list scrolls sideways
		// to the end of it; wrapped, the rows fit the tab.
		v.list.RowWidth = 0
		if !v.wrap {
			widest := float32(0)
			for _, line := range lines {
				widest = max(widest, line.width)
			}
			v.list.RowWidth = widest + 2*lspLogPadX
		}
		wrap := v.wrap
		ui.List(c, &v.list, len(lines), func(row ui.ListRow) {
			a.lspLogRow(row, lines[row.Index], wrap)
		}).Label(i18n.Shared(language, "logs.language.tabTitle")).Fill().MinHeight(0)
	})
}

// lspLogRow declares one log line: its level in the level's color, then its message, broken
// to the row's width when wrap is set and on one line otherwise.
func (a *App) lspLogRow(row ui.ListRow, line lspLogLine, wrap bool) {
	tag, message := line.parts()
	item := row.Element.FillWidth().PadX(lspLogPadX).Gap(lspLogGap)
	if wrap {
		item = item.MinHeight(lspLogRow).PadY(2).Items(ui.Start)
	} else {
		item = item.Height(lspLogRow).Items(ui.Center)
	}
	color := a.lspLogColor(line.level)
	item.Children(func() {
		if tag != "" {
			ui.Text(row.C, tag).Mono().FontSize(lspLogFont).Color(a.lspLevelColor(line.level)).Shrink(0)
		}
		if wrap {
			ui.Wrap(row.C, message).Mono().FontSize(lspLogFont).Color(color).Grow(1).Shrink(1).MinWidth(0)
		} else {
			ui.Text(row.C, message).Mono().FontSize(lspLogFont).Color(color).Shrink(0)
		}
	})
}

// measureLogLines measures the lines not measured yet in the log's font.
func measureLogLines(canvas *gfx.Canvas, lines []lspLogLine) {
	if canvas == nil {
		return
	}
	style := gfx.TextStyle{Size: lspLogFont, Weight: gfx.WeightRegular, Mono: true}
	for i := range lines {
		if lines[i].width > 0 {
			continue
		}
		tag, message := lines[i].parts()
		width := canvas.TextWidthStyle(message, style)
		if tag != "" {
			width += canvas.TextWidthStyle(tag, style) + lspLogGap
		}
		lines[i].width = width
	}
}

// lspLogBar declares the bar over the log: the server whose log is shown, the filter, the
// server's state, and the buttons that wrap long lines, clear the lines shown, stop the server
// and restart it.
func (a *App) lspLogBar(c ui.C, servers []*pluginServer, shown *pluginServer) {
	v := &a.editor.lsp
	language := a.language()
	ui.Row(c).FillWidth().Height(36).Shrink(0).PadX(10).Gap(8).Items(ui.Center).Children(func() {
		ids := make([]string, len(servers))
		for i, server := range servers {
			ids[i] = server.session.PluginID
		}
		ui.Select(c.Key("lspServer"), &v.plugin, ids, func(id string) string { return id }).
			Label(i18n.Shared(language, "native.languageServer")).Width(240).Height(26).Shrink(1).MinWidth(120)
		ui.TextField(c.Key("lspFilter"), &v.filter,
			i18n.Shared(language, "desktop.lsp.filterPlaceholder"), i18n.Shared(language, "desktop.lsp.filterPlaceholder")).
			Height(26).Grow(1).MinWidth(120)
		ui.Text(c, i18n.SharedFormat(language, "desktop.lsp.state", map[string]string{"state": shown.stateName()})).
			FontSize(12).Color(a.colors.Subtle).Shrink(0)
		wrap := ui.Button(c.Key("lspWrap"), i18n.Shared(language, "native.softWraps")).Icon(icons.WrapText).Ghost().Small()
		if v.wrap {
			wrap = wrap.Background(a.colors.Active)
		}
		if wrap.Clicked() {
			c.After(func() {
				a.performed("lsp.log.wrap", surfaceButton)
				v.wrap = !v.wrap
				v.list.ScrollToX(0)
			})
		}
		if ui.Button(c.Key("lspClear"), i18n.Shared(language, "native.clearLogView")).Icon(icons.Eraser).Ghost().Small().Clicked() {
			// Only the lines this tab shows go; the diagnostic log Core wrote keeps them.
			c.After(func() { shown.logs = nil })
		}
		pluginID := shown.session.PluginID
		if ui.Button(c.Key("lspStop"), i18n.Shared(language, "desktop.lsp.stopServer")).Icon(icons.Square).Ghost().Small().Clicked() {
			c.After(func() {
				a.performed("lsp.server.stop", surfaceButton)
				a.stopPluginServer(pluginID)
			})
		}
		if ui.Button(c.Key("lspRestart"), i18n.Shared(language, "desktop.lsp.restartServer")).Icon(icons.RefreshCw).Ghost().Small().Clicked() {
			server := shown
			c.After(func() {
				a.performed("lsp.server.restart", surfaceButton)
				a.restartLSPServer(server)
			})
		}
	})
}

// lspLogMessage declares a message in place of the log.
func (a *App) lspLogMessage(c ui.C, text string) {
	ui.Row(c).Fill().Center().Pad(20).Children(func() {
		ui.Paragraph(c, text, 3).Color(a.colors.Subtle)
	})
}

// lspLogColor is the color of the message of a line of the given level: errors in the theme's
// danger color, warnings in its warning color, debug and trace lines subdued.
func (a *App) lspLogColor(level string) gfx.Color {
	switch level {
	case "ERROR", "FATAL", "CRITICAL":
		return a.theme.Danger
	case "WARN", "WARNING":
		return a.colors.Warning
	case "DEBUG", "TRACE":
		return a.colors.Subtle
	}
	return a.colors.Text
}

// lspLevelColor is the color of a line's level in brackets, which stands out from the message:
// errors and warnings as their messages, information in the accent color and debug and trace
// subdued; a level Lithe does not know takes the accent color too.
func (a *App) lspLevelColor(level string) gfx.Color {
	switch level {
	case "ERROR", "FATAL", "CRITICAL", "WARN", "WARNING", "DEBUG", "TRACE":
		return a.lspLogColor(level)
	}
	return a.colors.Accent
}

// filterLogLines keeps the log lines that contain filter, ignoring case and surrounding
// spaces. An empty filter keeps every line.
func filterLogLines(lines []lspLogLine, filter string) []lspLogLine {
	filter = strings.ToLower(strings.TrimSpace(filter))
	if filter == "" {
		return lines
	}
	kept := make([]lspLogLine, 0, len(lines))
	for _, line := range lines {
		if strings.Contains(strings.ToLower(line.text), filter) {
			kept = append(kept, line)
		}
	}
	return kept
}

// sharedStateName is stateName for a caller off the window thread.
func (s *pluginServer) sharedStateName() string {
	if state := s.sharedState.Load(); state != nil && *state != "" {
		return *state
	}
	return "starting"
}

// stateName is the state the server last reported, "starting" before any.
func (s *pluginServer) stateName() string {
	if s.state == "" {
		return "starting"
	}
	return s.state
}
