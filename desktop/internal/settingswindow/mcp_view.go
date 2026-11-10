package settingswindow

import (
	"context"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

func (w *window) mcpIssue(issue core.McpDraftIssue) string { return w.text.MCP.Issue(issue.Code) }

func (w *window) mcpRejection(r *core.McpBatchRejection) string { return w.text.MCP.Rejection(r.Code) }

func (w *window) mcpAgentName(agent string) string {
	if agent == "claude" {
		return w.text.MCP.Claude
	}
	return w.text.MCP.Codex
}

// mcpTransportName is the words of a transport.
func (w *window) mcpTransportName(transport string) string {
	switch transport {
	case "http":
		return w.text.MCP.Http
	case "sse":
		return w.text.MCP.Sse
	}
	return w.text.MCP.Stdio
}

// mcpPage is the MCP Configuration page: the servers of the real Codex and Claude Code files,
// an editor, and discovery from the featured catalog and the official registry.
func (w *window) mcpPage(c ui.C) {
	s := w.mcp
	s.begin()
	p := &w.pal
	w.pageScroll(c, pageMCP, func() {
		ui.Wrap(c, w.text.MCP.Intro).FontSize(12).Color(p.muted)
		w.card(c, w.text.MCP.Servers, w.text.MCP.Help, func() { w.mcpServers(c) })
		w.card(c, w.text.MCP.Registry, "", func() { w.mcpDiscovery(c) })
	})
	if s.editor.open {
		w.mcpEditorDialog(c)
	}
	if s.confirmDelete != "" {
		w.mcpDeleteDialog(c)
	}
	if s.confirmProbe != "" {
		w.mcpProbeDialog(c)
	}
}

func (w *window) mcpServers(c ui.C) {
	s, p := w.mcp, &w.pal
	ui.Column(c).FillWidth().Gap(6).Children(func() {
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			if ui.Button(c, w.text.MCP.Add).Disabled(s.working() || !s.loaded).Clicked() {
				s.openEditor(nil, nil, "", func(command string, args []string) string { return w.mcpLine(command, args) })
			}
			if ui.Button(c, w.text.MCP.Reload).Outline().Disabled(s.working()).Clicked() {
				s.reload()
			}
			if s.working() {
				ui.Text(c, w.text.MCP.Working).FontSize(12).Color(p.muted)
			}
		})
		for _, failure := range s.library.ReadFailures {
			ui.Wrap(c.Key("rf"+failure.File), w.text.MCP.FileUnreadable(failure.Path)).FontSize(12).Color(p.danger)
		}
		for _, failure := range s.library.Snapshot.Failures {
			ui.Wrap(c.Key("pf"+failure.File), w.text.MCP.ParseFailed(failure.File)).FontSize(12).Color(p.danger)
		}
		if s.load.err != nil {
			ui.Wrap(c, w.text.MCP.LoadFailed(s.load.err.Error())).FontSize(12).Color(p.danger)
		}
		if s.writeErr != nil {
			ui.Wrap(c, w.text.MCP.WriteFailed(s.writeErr.Error())).FontSize(12).Color(p.danger)
		} else if s.outcome != nil && s.outcome.Status == "ready" {
			ui.Text(c, w.text.MCP.Saved).FontSize(12).Color(p.muted)
		} else if s.outcome != nil && s.outcome.Status == "rejected" && s.outcome.Rejection != nil && !s.editor.open {
			ui.Wrap(c, w.mcpRejection(s.outcome.Rejection)).FontSize(12).Color(p.danger)
		}
		if !s.loaded {
			ui.Text(c, w.text.MCP.Loading).FontSize(12).Color(p.muted)
			return
		}
		if len(s.library.Snapshot.Rows) == 0 {
			ui.Text(c, w.text.MCP.Empty).FontSize(12).Color(p.muted)
		}
		for i := range s.library.Snapshot.Rows {
			w.mcpRow(c, &s.library.Snapshot.Rows[i])
		}
	})
}

func (w *window) mcpRow(c ui.C, row *core.McpLibraryRow) {
	s, p := w.mcp, &w.pal
	ui.Column(c.Key(row.ID)).FillWidth().Gap(4).PadY(6).Children(func() {
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			ui.Text(c, row.Definition.Name).FontSize(13).Weight(gfx.WeightSemibold).Color(p.text).Ellipsis().Shrink(1)
			for _, agent := range mcpAgents {
				if enabledFor(*row, agent) {
					ui.Text(c.Key(agent), w.mcpAgentName(agent)).FontSize(11).Color(p.muted).Shrink(0)
				}
			}
			if row.ProjectOnly {
				ui.Text(c, w.text.MCP.ProjectOnly).FontSize(11).Color(p.muted).Shrink(0)
			}
			ui.Spacer(c)
			global := len(globalFiles(*row)) > 0
			if ui.Button(c, w.text.MCP.Detect).Outline().Disabled(s.probe.busy || !global).Clicked() {
				w.mcpDetect(row)
			}
			if ui.Button(c, w.text.MCP.Edit).Outline().Disabled(s.working() || !global).Clicked() {
				s.openEditor(row, nil, "", func(command string, args []string) string { return w.mcpLine(command, args) })
			}
			if ui.Button(c, w.text.MCP.Delete).Outline().Disabled(s.working() || !global).Clicked() {
				s.confirmDelete = row.ID
			}
		})
		ui.Text(c, summary(row.Definition)).FontSize(12).Color(p.muted).Ellipsis()
		if row.HasDefinitionConflict {
			ui.Wrap(c, w.text.MCP.ConflictNote).FontSize(11).Color(p.muted)
		}
		w.mcpTools(c, row)
	})
}

// mcpLine formats a command line through Core. The call is a short pure text operation.
func (w *window) mcpLine(command string, args []string) string {
	line, err := w.mcp.loader.CommandLine(context.Background(), command, args)
	if err != nil {
		return command
	}
	return line
}

// mcpDetect starts detection. A local command needs the user's confirmation first.
func (w *window) mcpDetect(row *core.McpLibraryRow) {
	s := w.mcp
	if row.Definition.Transport == "sse" {
		s.probeErr[row.ID] = errSSE
		return
	}
	if row.Definition.Transport == "stdio" {
		s.confirmProbe = row.ID
		return
	}
	w.mcpRunProbe(row.ID)
}

func (w *window) mcpRunProbe(id string) {
	s := w.mcp
	var row *core.McpLibraryRow
	for i := range s.library.Snapshot.Rows {
		if s.library.Snapshot.Rows[i].ID == id {
			row = &s.library.Snapshot.Rows[i]
		}
	}
	if row == nil {
		return
	}
	definition, agents, name := row.Definition, []string{}, row.Definition.Name
	for _, agent := range mcpAgents {
		if enabledFor(*row, agent) {
			agents = append(agents, agent)
		}
	}
	loader := s.loader
	s.probe.start(func(ctx context.Context) (mcpProbed, error) {
		tools, err := loader.Probe(ctx, definition)
		if err != nil {
			return mcpProbed{}, err
		}
		names := make([]string, len(tools))
		for i, tool := range tools {
			names[i] = tool.Name
		}
		result := mcpProbed{row: id, tools: tools, policies: map[string]core.McpToolPolicy{}, failed: map[string]error{}}
		for _, agent := range agents {
			policy, err := loader.ToolPolicy(ctx, agent, name, names)
			if err != nil {
				result.failed[agent] = err
				continue
			}
			result.policies[agent] = policy
		}
		return result, nil
	})
	s.probeRow = id
}

type mcpError string

func (e mcpError) Error() string { return string(e) }

const errSSE = mcpError("sse")

func (w *window) mcpTools(c ui.C, row *core.McpLibraryRow) {
	s, p := w.mcp, &w.pal
	if s.probe.busy && s.probeRow == row.ID {
		ui.Text(c, w.text.MCP.Detecting).FontSize(12).Color(p.muted)
	}
	if err := s.probeErr[row.ID]; err != nil {
		if err == errSSE {
			ui.Text(c, w.text.MCP.SseUnsupported).FontSize(12).Color(p.muted)
		} else {
			ui.Wrap(c, w.text.MCP.DetectFailed(err.Error())).FontSize(12).Color(p.danger)
		}
	}
	if s.probe.err != nil && s.probeRow == row.ID && !s.probe.busy {
		ui.Wrap(c, w.text.MCP.DetectFailed(s.probe.err.Error())).FontSize(12).Color(p.danger)
	}
	probed, ok := s.probed[row.ID]
	if !ok {
		return
	}
	if len(probed.tools) == 0 {
		ui.Text(c, w.text.MCP.NoTools).FontSize(12).Color(p.muted)
		return
	}
	ui.Text(c, w.text.MCP.Tools).FontSize(11).Weight(gfx.WeightSemibold).Color(p.muted)
	names := make([]string, len(probed.tools))
	for i, tool := range probed.tools {
		names[i] = tool.Name
	}
	for _, tool := range probed.tools {
		ui.Row(c.Key("tool/" + tool.Name)).FillWidth().Gap(10).Items(ui.Center).Children(func() {
			ui.Text(c, tool.Name).FontSize(12).Color(p.text).Ellipsis().Shrink(1)
			for _, agent := range mcpAgents {
				policy, has := probed.policies[agent]
				if !has {
					continue
				}
				enabled, editable := true, false
				for _, state := range policy.Tools {
					if state.Name == tool.Name {
						enabled, editable = state.Enabled, state.Editable
					}
				}
				on := enabled
				box := ui.Checkbox(c.Key(agent+"/"+tool.Name), &on, w.mcpAgentName(agent)).Disabled(!editable || s.toolSet.busy)
				if box.Changed() {
					w.mcpSetTool(row, agent, names, tool.Name, on)
				}
				if !editable {
					box.Tooltip(w.text.MCP.ToolLocked)
				}
			}
		})
	}
	if s.toolError != nil {
		ui.Wrap(c, w.text.MCP.ToolFailed(s.toolError.Error())).FontSize(12).Color(p.danger)
	}
}

func (w *window) mcpSetTool(row *core.McpLibraryRow, agent string, names []string, tool string, enabled bool) {
	s, loader, id, server := w.mcp, w.mcp.loader, row.ID, row.Definition.Name
	s.toolSet.start(func(ctx context.Context) (mcpToolSet, error) {
		policy, err := loader.SetTool(ctx, agent, server, names, tool, enabled)
		return mcpToolSet{row: id, agent: agent, policy: policy}, err
	})
}

// mcpEditorDialog is the add/edit dialog. Saving asks Core to validate and plan; nothing is
// written when the plan is invalid or refused.
func (w *window) mcpEditorDialog(c ui.C) {
	s, p := w.mcp, &w.pal
	e := &s.editor
	title := w.text.MCP.AddTitle
	if e.original != nil {
		title = w.text.MCP.EditTitle
	}
	open := true
	closed := ui.ModalWith(c, &open, title, ui.ModalSpec{Width: 520}, func() {
		ui.Scroll(c).FillWidth().MaxHeight(420).Children(func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				ui.TextField(c.Part("name"), &e.name, w.text.MCP.Name, w.text.MCP.Name).FillWidth()
				ui.Row(c).FillWidth().Gap(12).Items(ui.Center).Children(func() {
					for _, t := range []string{"stdio", "http", "sse"} {
						w.radio(c.Key("t"+t), &e.transport, t, w.mcpTransportName(t), false)
					}
				})
				if e.transport == "stdio" {
					ui.TextField(c.Part("command"), &e.command, w.text.MCP.Command, w.text.MCP.CommandHelp).FillWidth()
				} else {
					ui.TextField(c.Part("url"), &e.url, w.text.MCP.Url, "https://").FillWidth()
				}
				if e.transport == "stdio" {
					ui.TextArea(c.Part("env"), &e.env, w.text.MCP.Env, w.text.MCP.Env).FillWidth().Height(70)
				} else {
					ui.TextArea(c.Part("headers"), &e.headers, w.text.MCP.Headers, w.text.MCP.Headers).FillWidth().Height(70)
				}
				ui.Text(c, w.text.MCP.SecretsHint).FontSize(11).Color(p.muted)
				ui.Text(c, w.text.MCP.Agents).FontSize(12).Weight(gfx.WeightSemibold).Color(p.muted)
				ui.Row(c).FillWidth().Gap(12).Children(func() {
					for _, agent := range mcpAgents {
						on := e.agents[agent]
						if ui.Checkbox(c.Key("a"+agent), &on, w.mcpAgentName(agent)).Changed() {
							e.agents[agent] = on
						}
					}
				})
				for _, issue := range e.issues {
					ui.Wrap(c.Key(issue.Field+issue.Code), w.mcpIssue(issue)).FontSize(12).Color(p.danger)
				}
				if e.rejection != nil {
					ui.Wrap(c, w.mcpRejection(e.rejection)).FontSize(12).Color(p.danger)
				}
				if s.writeErr != nil {
					ui.Wrap(c, w.text.MCP.WriteFailed(s.writeErr.Error())).FontSize(12).Color(p.danger)
				}
			})
		})
	}, func() {
		if ui.Button(c, w.text.MCP.Cancel).Outline().Clicked() {
			e.open = false
		}
		if ui.Button(c, w.text.MCP.Save).Disabled(s.working()).Clicked() {
			w.mcpSave()
		}
	})
	if closed {
		e.open = false
	}
}

func (w *window) mcpSave() {
	s := w.mcp
	e := &s.editor
	e.issues, e.rejection = nil, nil
	input, loader := e.input(), s.loader
	s.apply.start(func(ctx context.Context) (mcpApplied, error) {
		intent, invalid := input.intent(ctx, loader)
		if invalid != nil {
			return mcpApplied{plan: *invalid}, nil
		}
		plan, err := loader.Apply(ctx, intent)
		return mcpApplied{plan: plan}, err
	})
}

func (w *window) mcpDeleteDialog(c ui.C) {
	s := w.mcp
	id := s.confirmDelete
	open := true
	closed := ui.ModalWith(c, &open, w.text.MCP.DeleteTitle, ui.ModalSpec{Description: w.text.MCP.DeleteBody, Width: 420}, func() {}, func() {
		if ui.Button(c, w.text.MCP.Cancel).Outline().Clicked() {
			s.confirmDelete = ""
		}
		if ui.Button(c, w.text.MCP.Delete).Clicked() {
			s.confirmDelete = ""
			w.mcpDelete(id)
		}
	})
	if closed {
		s.confirmDelete = ""
	}
}

func (w *window) mcpDelete(id string) {
	s := w.mcp
	for i := range s.library.Snapshot.Rows {
		row := s.library.Snapshot.Rows[i]
		if row.ID != id {
			continue
		}
		intent := core.McpBatchIntent{Kind: "delete", Name: row.Definition.Name, Files: globalFiles(row)}
		loader := s.loader
		s.apply.start(func(ctx context.Context) (mcpApplied, error) {
			plan, err := loader.Apply(ctx, intent)
			return mcpApplied{plan: plan}, err
		})
		return
	}
}

func (w *window) mcpProbeDialog(c ui.C) {
	s := w.mcp
	id := s.confirmProbe
	open := true
	closed := ui.ModalWith(c, &open, w.text.MCP.DetectConfirmTitle, ui.ModalSpec{Description: w.text.MCP.DetectConfirmBody, Width: 420}, func() {}, func() {
		if ui.Button(c, w.text.MCP.Cancel).Outline().Clicked() {
			s.confirmProbe = ""
		}
		if ui.Button(c, w.text.MCP.DetectContinue).Clicked() {
			s.confirmProbe = ""
			w.mcpRunProbe(id)
		}
	})
	if closed {
		s.confirmProbe = ""
	}
}

// mcpDiscovery lists the featured catalog, and the registry's answer after an explicit search.
func (w *window) mcpDiscovery(c ui.C) {
	s, p := w.mcp, &w.pal
	ui.Column(c).FillWidth().Gap(6).Children(func() {
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			field := ui.TextField(c.Part("q"), &s.query, w.text.MCP.SearchPlaceholder, w.text.MCP.SearchPlaceholder).Icon(icons.Search).Grow(1).MinWidth(0).Height(30)
			enter := field.Submitted()
			if (ui.Button(c, w.text.MCP.Search).Disabled(s.search.busy).Clicked() || enter) && !s.search.busy {
				w.mcpSearch("", false)
			}
		})
		page, title := s.featuredPage, w.text.MCP.Featured
		if s.searched {
			page, title = s.searchPage, w.text.MCP.Search
		}
		ui.Text(c, title).FontSize(11).Weight(gfx.WeightSemibold).Color(p.muted)
		if s.search.busy {
			ui.Text(c, w.text.MCP.Searching).FontSize(12).Color(p.muted)
		}
		if s.search.err != nil {
			ui.Wrap(c, w.text.MCP.SearchFailed(s.search.err.Error())).FontSize(12).Color(p.danger)
		}
		if s.searched && len(page.Entries) == 0 && !s.search.busy && s.search.err == nil {
			ui.Text(c, w.text.MCP.NoResults).FontSize(12).Color(p.muted)
		}
		for i := range page.Entries {
			w.mcpRegistryRow(c, &page.Entries[i])
		}
		if s.searched && page.NextCursor != nil && !s.search.busy {
			if ui.Button(c, w.text.MCP.More).Outline().Clicked() {
				w.mcpSearch(*page.NextCursor, true)
			}
		}
	})
}

func (w *window) mcpSearch(cursor string, more bool) {
	s := w.mcp
	query, loader := strings.TrimSpace(s.query.Text()), s.loader
	if !more {
		s.searchedQuery = query
		s.searched = true
	} else {
		query = s.searchedQuery
	}
	s.search.start(func(ctx context.Context) (mcpSearched, error) {
		page, err := loader.Search(ctx, query, cursor)
		return mcpSearched{page: page, append: more}, err
	})
}

func (w *window) mcpRegistryRow(c ui.C, entry *core.McpRegistryEntry) {
	s, p := w.mcp, &w.pal
	ui.Column(c.Key(entry.ID)).FillWidth().Gap(2).PadY(4).Children(func() {
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			ui.Text(c, entry.Title).FontSize(13).Weight(gfx.WeightSemibold).Color(p.text).Ellipsis().Shrink(1)
			ui.Spacer(c)
			if entry.Draft == nil {
				ui.Text(c, w.text.MCP.DocsOnly).FontSize(11).Color(p.muted)
				return
			}
			if ui.Button(c, w.text.MCP.AddFromRegistry).Outline().Disabled(s.working() || !s.loaded).Clicked() {
				draft := *entry.Draft
				s.openEditor(nil, &draft, entry.Setup, func(command string, args []string) string { return w.mcpLine(command, args) })
			}
		})
		if entry.Summary != "" {
			ui.Paragraph(c, entry.Summary, 2).FontSize(12).Color(p.muted)
		}
	})
}
