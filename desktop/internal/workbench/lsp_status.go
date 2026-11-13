package workbench

import (
	"sort"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The language server's state in the status bar, and the LSP Logs tab with the log of each
// server.
//
// Core owns the session's lifecycle: stateChanged says starting, ready, failed or stopped and
// log events carry what the server and Core reported. This file keeps what the events said
// (the last state and a bounded tail of log lines per server) and shows it; it infers
// nothing from log text.
//
// As in the earlier macOS client, the log is an ordinary tab of the editor area: the status
// bar item opens it, or selects it when the project already has it, and it is selected,
// moved, split off and closed like an open file's tab. Its member in a tab group is
// lspLogMember, so a project has at most one; it shows one server at a time.

const (
	// lspLogLines bounds the log lines kept for one server.
	lspLogLines = 500
	// lspLogLineBytes cuts one line, so a server that prints a huge message costs bounded
	// memory.
	lspLogLineBytes = 600
	// lspLogMember is the member name of the LSP Logs tab in a tab group.
	lspLogMember = "lsp:log"
	// lspLogRow is the height of one log line in the tab.
	lspLogRow = 20
)

// lspLogLine is one log line of a server: the text shown, which starts with the event's
// level when it gave one, and that level in upper case for the line's color.
type lspLogLine struct {
	level string
	text  string
}

// lspLogState is the LSP Logs tab's state.
type lspLogState struct {
	// plugin is the server whose log is shown; empty selects the first.
	plugin string
	// filter keeps the lines that contain it, case-insensitively.
	filter string
	list   ui.ListState
	// shown is the server the last paint of the tab showed and seen how many lines it had
	// added by then: a new line keeps the list at its end unless the user scrolled away
	// from it, and another server starts its list afresh at its end.
	shown *pluginServer
	seen  uint64
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
		line := strings.TrimSpace(event.Message)
		if event.Detail != "" {
			line += " " + strings.TrimSpace(event.Detail)
		}
		if line == "" {
			return
		}
		if len(line) > lspLogLineBytes {
			line = line[:lspLogLineBytes]
			for len(line) > 0 && line[len(line)-1]&0xC0 == 0x80 {
				line = line[:len(line)-1]
			}
		}
		level := event.Level
		if level == "" {
			level = event.LegacyLevel
		}
		level = strings.ToUpper(strings.TrimSpace(level))
		if level != "" {
			line = "[" + level + "] " + line
		}
		if len(server.logs) >= lspLogLines {
			copy(server.logs, server.logs[len(server.logs)-lspLogLines+1:])
			server.logs = server.logs[:lspLogLines-1]
		}
		server.logs = append(server.logs, lspLogLine{level: level, text: line})
		server.logsAdded++
		a.invalidator.Invalidate()
	}
}

// lspStatusText is the status bar's reading for the selected document's language server, or
// while the LSP Logs tab is selected for the server it shows: its state, or the problems it
// reported. "" means no server serves the document.
func (a *App) lspStatusText() string {
	if total := a.pluginProblemCount(); total > 0 {
		return a.text.Status.Problems(total)
	}
	p := a.project
	if p == nil {
		return ""
	}
	d := p.selectedDocument(p.docs.group)
	server, _ := a.documentSyncServer(d)
	if server == nil && p.selectedLSPLog(p.docs.group) {
		server = lspLogServer(a.lspServers(), a.editor.lsp.plugin)
	}
	if server == nil {
		return ""
	}
	language := a.language()
	switch {
	case server.state == "failed" || server.state == "error":
		return i18n.Shared(language, "desktop.status.lspFailed")
	case server.state == "stopped":
		return i18n.Shared(language, "desktop.status.lspStopped")
	case server.isReady():
		return i18n.Shared(language, "desktop.status.lspReady")
	}
	return i18n.Shared(language, "desktop.status.lspStarting")
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
		ui.List(c, &v.list, len(lines), func(row ui.ListRow) {
			line := lines[row.Index]
			row.Element.FillWidth().Height(lspLogRow).PadX(10).Items(ui.Center).Children(func() {
				ui.Text(row.C, line.text).Mono().FontSize(12).Color(a.lspLogColor(line.level)).Ellipsis().Shrink(1)
			})
		}).Label(i18n.Shared(language, "logs.language.tabTitle")).Fill().MinHeight(0)
	})
}

// lspLogBar declares the bar over the log: the server whose log is shown, the filter, the
// server's state, and the buttons that clear the lines shown, stop the server and restart it.
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
		if ui.Button(c.Key("lspClear"), i18n.Shared(language, "native.clearLogView")).Icon(icons.Eraser).Ghost().Small().Clicked() {
			// Only the lines this tab shows go; the diagnostic log Core wrote keeps them.
			c.After(func() { shown.logs = nil })
		}
		pluginID := shown.session.PluginID
		if ui.Button(c.Key("lspStop"), i18n.Shared(language, "desktop.lsp.stopServer")).Icon(icons.Square).Ghost().Small().Clicked() {
			c.After(func() { a.stopPluginServer(pluginID) })
		}
		if ui.Button(c.Key("lspRestart"), i18n.Shared(language, "desktop.lsp.restartServer")).Icon(icons.RefreshCw).Ghost().Small().Clicked() {
			server := shown
			c.After(func() {
				workspace := ""
				if server.project != nil {
					workspace = server.project.root
				}
				a.restartSettingsPlugin(server.session.PluginID, server.session.Version, "project", workspace)
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

// lspLogColor is the color of a line of the given level: errors in the theme's danger color,
// warnings in its warning color, debug and trace lines subdued.
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

// stateName is the state the server last reported, "starting" before any.
// sharedStateName is stateName for a caller off the window thread.
func (s *pluginServer) sharedStateName() string {
	if state := s.sharedState.Load(); state != nil && *state != "" {
		return *state
	}
	return "starting"
}

func (s *pluginServer) stateName() string {
	if s.state == "" {
		return "starting"
	}
	return s.state
}
