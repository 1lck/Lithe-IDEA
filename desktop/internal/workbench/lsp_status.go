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
		ui.Text(c, i18n.SharedFormat(language, "desktop.lsp.state", map[string]string{"state": shown.stateName()})).FontSize(12).Color(a.colors.Subtle).Shrink(0)
		lines := shown.logs
		if len(lines) == 0 {
			ui.Paragraph(c, i18n.Shared(language, "desktop.lsp.noLog"), 3).Color(a.colors.Subtle)
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

// stateName is the state the server last reported, "starting" before any.
func (s *pluginServer) stateName() string {
	if s.state == "" {
		return "starting"
	}
	return s.state
}
