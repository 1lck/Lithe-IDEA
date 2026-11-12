package workbench

import (
	"sort"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// The language server's state in the status bar, and a window with the log of each server.
//
// Core owns the session's lifecycle: stateChanged says starting, ready, failed or stopped and
// log events carry what the server and Core reported. This file keeps what the events said
// (the last state and a bounded tail of log lines per server) and shows it; it infers
// nothing from log text.

const (
	// lspLogLines bounds the log lines kept for one server.
	lspLogLines = 500
	// lspLogLineBytes cuts one line, so a server that prints a huge message costs bounded
	// memory.
	lspLogLineBytes = 600
)

// lspLogState is the log window's state.
type lspLogState struct {
	open bool
	// plugin is the server whose log is shown; empty selects the first.
	plugin string
	// filter keeps the lines that contain it, case-insensitively.
	filter string
	list   ui.ListState
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
		if level != "" {
			line = "[" + strings.ToUpper(level) + "] " + line
		}
		if len(server.logs) >= lspLogLines {
			copy(server.logs, server.logs[len(server.logs)-lspLogLines+1:])
			server.logs = server.logs[:lspLogLines-1]
		}
		server.logs = append(server.logs, line)
		a.invalidator.Invalidate()
	}
}

// lspStatusText is the status bar's reading for the selected document's language server: its
// state, or the problems it reported. "" means no server serves the document.
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

// lspLogPopup declares the log window while it is open: a button per server, and the lines the
// selected one reported.
func (a *App) lspLogPopup(c ui.C) {
	v := &a.editor.lsp
	if !v.open {
		return
	}
	language := a.language()
	servers := a.lspServers()
	var shown *pluginServer
	for _, server := range servers {
		if server.session.PluginID == v.plugin {
			shown = server
		}
	}
	if shown == nil && len(servers) > 0 {
		shown = servers[0]
		v.plugin = shown.session.PluginID
	}
	closed := ui.ModalWith(c, &v.open, i18n.Shared(language, "desktop.lsp.logTitle"), ui.ModalSpec{Width: 720, Height: 460}, func() {
		if shown == nil {
			ui.Paragraph(c, i18n.Shared(language, "desktop.lsp.noServers"), 3).Color(a.colors.Subtle)
			return
		}
		ui.Row(c).FillWidth().Gap(6).Shrink(0).Children(func() {
			for _, server := range servers {
				id := server.session.PluginID
				button := ui.Button(c.Key(id), id).Size(0, 28)
				if id != shown.session.PluginID {
					button = button.Outline()
				}
				if button.Clicked() {
					c.After(func() { v.plugin, v.list = id, ui.ListState{} })
				}
			}
		})
		ui.Row(c).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Children(func() {
			ui.TextField(c.Key("lspFilter"), &v.filter,
				i18n.Shared(language, "desktop.lsp.filterPlaceholder"), i18n.Shared(language, "desktop.lsp.filterPlaceholder")).Grow(1)
			pluginID := shown.session.PluginID
			if ui.Button(c.Key("lspStop"), i18n.Shared(language, "desktop.lsp.stopServer")).Outline().Clicked() {
				c.After(func() { a.stopPluginServer(pluginID) })
			}
			if ui.Button(c.Key("lspRestart"), i18n.Shared(language, "desktop.lsp.restartServer")).Outline().Clicked() {
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
		ui.Text(c, i18n.SharedFormat(language, "desktop.lsp.state", map[string]string{"state": shown.stateName()})).FontSize(12).Color(a.colors.Subtle).Shrink(0)
		lines := filterLogLines(shown.logs, v.filter)
		if len(lines) == 0 {
			if len(shown.logs) > 0 && strings.TrimSpace(v.filter) != "" {
				ui.Paragraph(c, i18n.Shared(language, "desktop.lsp.noFilteredLog"), 3).Color(a.colors.Subtle)
			} else {
				ui.Paragraph(c, i18n.Shared(language, "desktop.lsp.noLog"), 3).Color(a.colors.Subtle)
			}
			return
		}
		ui.List(c, &v.list, len(lines), func(row ui.ListRow) {
			row.Element.FillWidth().Height(20).PadX(6).Items(ui.Center).Children(func() {
				ui.Text(row.C, lines[row.Index]).Mono().FontSize(12).Color(a.colors.Text).Ellipsis().Shrink(1)
			})
		}).Label(i18n.Shared(language, "desktop.lsp.logTitle")).FillWidth().Grow(1).MinHeight(0)
	}, nil)
	if closed {
		v.open = false
	}
}

// filterLogLines keeps the log lines that contain filter, ignoring case and surrounding
// spaces. An empty filter keeps every line.
func filterLogLines(lines []string, filter string) []string {
	filter = strings.ToLower(strings.TrimSpace(filter))
	if filter == "" {
		return lines
	}
	kept := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.Contains(strings.ToLower(line), filter) {
			kept = append(kept, line)
		}
	}
	return kept
}

// stateName is the state the server last reported, "starting" before any.
func (s *pluginServer) stateName() string {
	if s.state == "" {
		return "starting"
	}
	return s.state
}
