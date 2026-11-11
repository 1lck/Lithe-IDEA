package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The four AI pages. Each reads the shared agentSettings state under its lock into plain
// values, then declares; button presses are queued with c.After and run Core work off the
// window thread (agent_settings.go).

// agentUnavailable is the body of an AI page when the window has no Core backend.
func (w *window) agentUnavailable(c ui.C) {
	w.pageScroll(c, w.sess.page, func() {
		ui.Wrap(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.unavailable")).FontSize(13).Color(w.pal.muted)
	})
}

// agentPicker declares the adapter radio group shared by the four pages.
func (w *window) agentPicker(c ui.C) {
	s := w.agent
	s.mu.Lock()
	pick := agentSettingsAgents[s.agent]
	s.mu.Unlock()
	w.card(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.agent"), "", func() {
		ui.Row(c).FillWidth().Gap(16).Children(func() {
			for i, id := range agentSettingsAgents {
				name := "Codex"
				if id == "claude-acp" {
					name = "Claude Code"
				}
				value := pick
				w.radio(c.KeyInt(i), &value, id, name, false)
				if value != pick {
					idx := i
					c.After(func() { s.selectAgent(idx) })
				}
			}
		})
	})
}

func (w *window) agentError(c ui.C, err error) {
	if err != nil {
		ui.Wrap(c, err.Error()).FontSize(12).Color(w.pal.danger)
	}
}

// agentsPage is the Agents page: the context limits each Agent is launched with.
func (w *window) agentsPage(c ui.C) {
	s := w.agent
	if !s.available() {
		w.agentUnavailable(c)
		return
	}
	s.loadLimits()
	w.pageScroll(c, pageAIAgents, func() {
		w.agentPicker(c)
		w.managementCard(c)
		w.customAgentsCard(c)
		s.mu.Lock()
		d := s.limitDraft
		s.mu.Unlock()
		w.generationCard(c)
		w.card(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.limits.title"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.limits.help"), func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				window, compact := d.window, d.compact
				language := w.marketLanguage()
				windowHint := i18n.Shared(language, "desktop.settings.agent.limits.notReported")
				if s.reportedContext != nil {
					if reported := s.reportedContext(s.agentID()); reported > 0 {
						windowHint = i18n.SharedFormat(language, "desktop.settings.agent.limits.reported", map[string]string{"tokens": formatLimit(reported)})
					}
				}
				ui.TextField(c.Key("window"), &window, i18n.Shared(language, "desktop.settings.agent.limits.window"), windowHint).FillWidth()
				ui.TextField(c.Key("compact"), &compact, i18n.Shared(language, "desktop.settings.agent.limits.compact"), i18n.Shared(language, "desktop.settings.agent.limits.defaultHint")).FillWidth()
				if window != d.window || compact != d.compact {
					s.mu.Lock()
					s.limitDraft.window, s.limitDraft.compact, s.limitDraft.saved = window, compact, false
					s.mu.Unlock()
				}
				if d.invalid {
					ui.Text(c, limitProblemText(w.marketLanguage(), d.invalidReason)).FontSize(12).Color(w.pal.danger)
				}
				if d.saved {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.limits.saved")).FontSize(12).Color(w.pal.muted)
				}
				ui.Row(c).Gap(8).Children(func() {
					if ui.Button(c.Key("save"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.limits.save")).Clicked() {
						c.After(s.saveLimits)
					}
					if ui.Button(c.Key("reset"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.limits.reset")).Outline().Clicked() {
						c.After(s.resetLimits)
					}
				})
			})
		})
	})
}

// instructionsPage edits the selected Agent's real global instruction file.
func (w *window) instructionsPage(c ui.C) {
	s := w.agent
	if !s.available() {
		w.agentUnavailable(c)
		return
	}
	s.beginInstructions(false)
	s.beginShared(false)
	w.pageScroll(c, pageAIInstructions, func() {
		w.agentPicker(c)
		s.mu.Lock()
		st := s.instructions
		s.mu.Unlock()
		w.sharedCard(c)
		w.card(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.instructions.title"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.instructions.help"), func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				if st.loading && !st.loaded {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.loading")).FontSize(12).Color(w.pal.muted)
					return
				}
				w.agentError(c, st.err)
				if !st.loaded {
					if ui.Button(c.Key("retry"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.reload")).Outline().Clicked() {
						c.After(func() { s.beginInstructions(true) })
					}
					return
				}
				ui.Text(c, i18n.SharedFormat(w.marketLanguage(), "desktop.settings.agent.instructions.path", map[string]string{"path": st.file.Path})).
					FontSize(12).Color(w.pal.muted).Ellipsis()
				if !st.file.Exists {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.instructions.missing")).FontSize(12).Color(w.pal.muted)
				}
				draft := st.draft
				ui.TextArea(c.Key("editor"), &draft, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.instructions.placeholder"), "").FillWidth().Height(280).Disabled(st.saving)
				if draft != st.draft {
					s.mu.Lock()
					s.instructions.draft, s.instructions.saved = draft, false
					s.mu.Unlock()
				}
				if st.saved {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.instructions.saved")).FontSize(12).Color(w.pal.muted)
				}
				if strings.HasSuffix(st.file.Path, "AGENTS.override.md") {
					ui.Paragraph(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.instructions.overrideActive"), 3).FontSize(12).Color(w.pal.muted)
				}
				if len(draft) > agentInstructionsLimit {
					ui.Paragraph(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.instructions.tooLarge"), 2).FontSize(12).Color(w.pal.danger)
				}
				ui.Row(c).Gap(8).Children(func() {
					if ui.Button(c.Key("save"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.instructions.save")).Disabled(!st.changed() || st.saving || len(draft) > agentInstructionsLimit).Clicked() {
						c.After(s.saveInstructions)
					}
					if ui.Button(c.Key("reload"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.reload")).Outline().Disabled(st.saving).Clicked() {
						c.After(func() {
							if st.changed() {
								s.mu.Lock()
								s.instructions.confirmReload = true
								s.mu.Unlock()
								return
							}
							s.beginInstructions(true)
						})
					}
				})
			})
		})
		w.instructionsReloadDialog(c, s)
	})
}

// agentInstructionsLimit is the largest global instructions text Core accepts (1 MiB).
const agentInstructionsLimit = 1 << 20

// instructionsReloadDialog asks before a reload throws away an edited draft.
func (w *window) instructionsReloadDialog(c ui.C, s *agentSettings) {
	s.mu.Lock()
	pending := s.instructions.confirmReload
	s.mu.Unlock()
	if !pending {
		return
	}
	lang := w.marketLanguage()
	open := true
	closed := ui.ModalWith(c, &open, i18n.Shared(lang, "desktop.settings.agent.instructions.discardTitle"), ui.ModalSpec{Description: i18n.Shared(lang, "desktop.settings.agent.instructions.discardBody"), Width: 420}, func() {}, func() {
		if ui.Button(c, i18n.Shared(lang, "desktop.settings.agent.instructions.discardCancel")).Outline().Clicked() {
			c.After(func() { s.dismissInstructionsReload() })
		}
		if ui.Button(c, i18n.Shared(lang, "desktop.settings.agent.instructions.discardConfirm")).Clicked() {
			c.After(func() {
				s.dismissInstructionsReload()
				s.beginInstructions(true)
			})
		}
	})
	if closed {
		s.dismissInstructionsReload()
	}
}

func (w *window) skillScopeLabel(scope string) string {
	switch scope {
	case "user":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.scope.user")
	case "repo":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.scope.repo")
	case "system":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.scope.system")
	case "admin":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.scope.admin")
	}
	return scope
}

// skillsPage lists the Agent's discovered skills with native enable switches, and creates
// or imports one into a chosen scope.
func (w *window) skillsPage(c ui.C) {
	s := w.agent
	if !s.available() {
		w.agentUnavailable(c)
		return
	}
	s.beginSkills(false)
	w.pageScroll(c, pageAISkills, func() {
		w.agentPicker(c)
		s.mu.Lock()
		st := s.skills
		s.mu.Unlock()
		hasProject := s.root() != ""
		w.card(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.title"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.help"), func() {
			ui.Column(c).FillWidth().Gap(6).Children(func() {
				if st.loading && !st.loaded {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.loading")).FontSize(12).Color(w.pal.muted)
				}
				w.agentError(c, st.err)
				for _, issue := range st.listing.Issues {
					ui.Wrap(c.Key("issue/"+issue), issue).FontSize(12).Color(w.pal.muted)
				}
				query := st.query
				ui.TextField(c.Key("search"), &query, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.search"), "").FillWidth()
				if query != st.query {
					s.mu.Lock()
					s.skills.query = query
					s.mu.Unlock()
				}
				folded := foldQuery(query)
				if st.loaded && len(st.listing.Skills) == 0 {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.empty")).FontSize(12).Color(w.pal.muted)
				}
				shown := 0
				for _, project := range []bool{false, true} {
					group := i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.group.global")
					if project {
						group = i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.group.project")
					}
					header := false
					for i, skill := range st.listing.Skills {
						if isProjectScope(skill.Scope) != project || !skillMatches(skill.Name, skill.Description, w.skillScopeLabel(skill.Scope), skill.Path, folded) {
							continue
						}
						if !header {
							header = true
							ui.Text(c.Key("group/"+group), group).FontSize(12).Color(w.pal.muted)
						}
						shown++
						w.skillRow(c, i, skill, st.busy)
					}
				}
				if st.loaded && len(st.listing.Skills) > 0 && shown == 0 {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.noMatch")).FontSize(12).Color(w.pal.muted)
				}
				if ui.Button(c.Key("refresh"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.refresh")).Outline().Disabled(st.loading || st.busy).Clicked() {
					c.After(func() { s.beginSkills(true) })
				}
			})
		})
		if st.viewPath != "" {
			w.skillViewer(c, st)
		}
		w.card(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.create"), "", func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				scope := st.createScope
				ui.Row(c).Gap(16).Children(func() {
					user := skillScopes[scope]
					w.radio(c.Key("user"), &user, "user", w.skillScopeLabel("user"), false)
					w.radio(c.Key("repo"), &user, "repo", w.skillScopeLabel("repo"), !hasProject)
					if user != skillScopes[scope] {
						pick := agentIndexOf(skillScopes[:], user)
						s.mu.Lock()
						s.skills.createScope = pick
						s.mu.Unlock()
					}
				})
				if !hasProject {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.noProject")).FontSize(12).Color(w.pal.muted)
				}
				name, desc, body, path := st.name, st.desc, st.body, st.importPath
				ui.TextField(c.Key("name"), &name, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.createName"), "").FillWidth()
				ui.TextField(c.Key("desc"), &desc, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.createDescription"), "").FillWidth()
				ui.TextArea(c.Key("body"), &body, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.createInstructions"), "").FillWidth().Height(120)
				ui.TextField(c.Key("import"), &path, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.importLabel"), "").FillWidth()
				if name != st.name || desc != st.desc || body != st.body || path != st.importPath {
					s.mu.Lock()
					s.skills.name, s.skills.desc, s.skills.body, s.skills.importPath = name, desc, body, path
					s.mu.Unlock()
				}
				if st.notice != "" {
					ui.Wrap(c, i18n.SharedFormat(w.marketLanguage(), "desktop.settings.agent.skills.created", map[string]string{"path": st.notice})).FontSize(12).Color(w.pal.muted)
				}
				projectOnly := skillScopes[scope] == "repo" && !hasProject
				ui.Row(c).Gap(8).Children(func() {
					if ui.Button(c.Key("create"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.create")).
						Disabled(st.busy || projectOnly || strings.TrimSpace(name) == "").Clicked() {
						c.After(s.createSkill)
					}
					if ui.Button(c.Key("pickFile"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.pickFile")).Outline().Disabled(st.busy).Clicked() {
						title := i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.pickerTitle")
						c.After(func() { s.pickImportSource(title, false) })
					}
					if ui.Button(c.Key("pickDirectory"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.pickDirectory")).Outline().Disabled(st.busy).Clicked() {
						title := i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.pickerTitle")
						c.After(func() { s.pickImportSource(title, true) })
					}
					if ui.Button(c.Key("importGo"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.skills.import")).Outline().
						Disabled(st.busy || projectOnly || strings.TrimSpace(path) == "").Clicked() {
						c.After(s.importSkill)
					}
				})
			})
		})
	})
}

func (w *window) hookEventLabel(event string) string {
	switch event {
	case "turn-end":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.event.turnEnd")
	case "after-tool":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.event.afterTool")
	case "before-tool":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.event.beforeTool")
	case "prompt":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.event.prompt")
	case "session-start":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.event.sessionStart")
	}
	return event
}

// hookMatches reports whether a Hook contains the folded search text in the fields the row
// shows; an empty query matches every Hook.
func hookMatches(hook core.AgentHook, eventLabel, query string) bool {
	if query == "" {
		return true
	}
	for _, field := range []string{hook.Name, hook.Description, hook.Command, eventLabel} {
		if strings.Contains(foldQuery(field), query) {
			return true
		}
	}
	return false
}

func (w *window) hookMatcherLabel(matcher string) string {
	switch matcher {
	case "all":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.matcher.all")
	case "shell":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.matcher.shell")
	case "edit":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.matcher.edit")
	}
	return matcher
}

// hookIssueText localizes the field and code Core's draft validation reports
// (agent.hooks.draft.<field>.<code>). Core's own vocabulary stays for a pair this client
// does not know.
func (w *window) hookIssueText(issue core.AgentHookIssue) string {
	switch issue.Field + "." + issue.Code {
	case "agents.duplicate":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.agents.duplicate")
	case "agents.required":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.agents.required")
	case "agents.unsupported":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.agents.unsupported")
	case "command.contains_nul":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.command.containsNul")
	case "command.required":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.command.required")
	case "command.too_long":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.command.tooLong")
	case "description.too_long":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.description.tooLong")
	case "id.invalid":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.id.invalid")
	case "matcher.incompatible_event":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.matcher.incompatibleEvent")
	case "name.duplicate":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.name.duplicate")
	case "name.invalid_characters":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.name.invalidCharacters")
	case "name.required":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.name.required")
	case "name.too_long":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.name.tooLong")
	case "timeout.not_integer":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.timeout.notInteger")
	case "timeout.out_of_range":
		return i18n.Shared(w.marketLanguage(), "agent.hooks.draft.timeout.outOfRange")
	}
	return issue.Field + ": " + issue.Code
}

// hooksPage manages the Hook library. Reading it executes nothing.
func (w *window) hooksPage(c ui.C) {
	s := w.agent
	if !s.available() {
		w.agentUnavailable(c)
		return
	}
	s.beginHooks(false)
	w.pageScroll(c, pageAIHooks, func() {
		s.mu.Lock()
		st := s.hooks
		s.mu.Unlock()
		w.card(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.title"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.help"), func() {
			ui.Column(c).FillWidth().Gap(6).Children(func() {
				if st.loading && !st.loaded {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.loading")).FontSize(12).Color(w.pal.muted)
				}
				w.agentError(c, st.err)
				if s.agentID() == "codex-acp" {
					ui.Paragraph(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.codexApproval"), 4).FontSize(12).Color(w.pal.muted)
				}
				if st.loaded && len(st.library.Hooks) == 0 {
					ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.empty")).FontSize(12).Color(w.pal.muted)
				}
				for _, target := range st.library.Targets {
					if target.Issue != nil {
						ui.Wrap(c.Key("target/"+target.AgentID), *target.Issue).FontSize(12).Color(w.pal.muted)
					}
				}
				needsSync := false
				language := w.marketLanguage()
				query := st.query
				ui.TextField(c.Key("hookSearch"), &query, i18n.Shared(language, "desktop.settings.agent.hooks.search"), "").FillWidth()
				if query != st.query {
					s.mu.Lock()
					s.hooks.query = query
					s.mu.Unlock()
				}
				folded := foldQuery(query)
				shown := 0
				for _, hook := range st.library.Hooks {
					hook := hook
					needsSync = needsSync || hook.NeedsSync || hook.PendingRemoval
					if !hookMatches(hook, w.hookEventLabel(hook.Event), folded) {
						continue
					}
					shown++
					ui.Row(c.Key("hook/" + hook.ID)).FillWidth().Items(ui.Center).Gap(8).Children(func() {
						ui.Column(c).Grow(1).Gap(1).Children(func() {
							ui.Text(c, hook.Name+" · "+w.hookEventLabel(hook.Event)).FontSize(13).Color(w.pal.text).Ellipsis()
							status := hook.Command
							if hook.PendingRemoval {
								status = i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.pendingRemoval")
							} else if hook.NeedsSync {
								status = i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.needsSync") + " · " + status
							}
							ui.Text(c, status).FontSize(12).Color(w.pal.muted).Ellipsis()
						})
						if ui.Button(c.Key("edit"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.edit")).Outline().Disabled(st.saving || hook.PendingRemoval).Clicked() {
							c.After(func() { s.editHook(hook) })
						}
						if ui.Button(c.Key("remove"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.remove")).Outline().Disabled(st.saving).Clicked() {
							id, name := hook.ID, hook.Name
							c.After(func() {
								s.mu.Lock()
								s.hooks.confirmRemove, s.hooks.confirmName = id, name
								s.mu.Unlock()
							})
						}
					})
				}
				if st.loaded && len(st.library.Hooks) > 0 && shown == 0 {
					ui.Text(c, i18n.Shared(language, "desktop.settings.agent.hooks.noMatch")).FontSize(12).Color(w.pal.muted)
				}
				if st.confirmRemove != "" {
					name := st.confirmName
					ui.Column(c.Key("confirmRemove")).FillWidth().Gap(4).Pad(6).Background(w.pal.hover).Children(func() {
						ui.Paragraph(c, i18n.SharedFormat(language, "desktop.settings.agent.hooks.removeConfirm", map[string]string{"name": name}), 3).Color(w.pal.text)
						ui.Row(c).Gap(8).Children(func() {
							if ui.Button(c.Key("removeYes"), i18n.Shared(language, "desktop.settings.agent.hooks.remove")).Destructive().Disabled(st.saving).Clicked() {
								c.After(func() {
									id := st.confirmRemove
									s.mu.Lock()
									s.hooks.confirmRemove, s.hooks.confirmName = "", ""
									s.mu.Unlock()
									s.removeHook(id)
								})
							}
							if ui.Button(c.Key("removeNo"), i18n.Shared(language, "desktop.settings.agent.cancel")).Outline().Clicked() {
								c.After(func() {
									s.mu.Lock()
									s.hooks.confirmRemove, s.hooks.confirmName = "", ""
									s.mu.Unlock()
								})
							}
						})
					})
				}
				ui.Row(c).Gap(8).Children(func() {
					if ui.Button(c.Key("new"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.new")).Disabled(!st.loaded || st.saving).Clicked() {
						c.After(s.newHook)
					}
					if needsSync && ui.Button(c.Key("sync"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.sync")).Outline().Disabled(st.saving).Clicked() {
						c.After(s.syncHooks)
					}
					if ui.Button(c.Key("reload"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.reload")).Outline().Disabled(st.saving || st.loading).Clicked() {
						c.After(func() { s.beginHooks(true) })
					}
				})
			})
		})
		if st.editing {
			w.hookEditor(c, st)
		}
	})
}

func (w *window) hookEditor(c ui.C, st hooksState) {
	s := w.agent
	f := st.form
	w.card(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.new"), "", func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			name, desc, command, timeout := f.name, f.description, f.command, f.timeout
			ui.TextField(c.Key("name"), &name, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.name"), "").FillWidth()
			ui.TextField(c.Key("desc"), &desc, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.description"), "").FillWidth()
			ui.TextArea(c.Key("command"), &command, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.command"), "").FillWidth().Height(80)
			ui.TextField(c.Key("timeout"), &timeout, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.timeout"), "").FillWidth()
			ui.Paragraph(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.timeoutHelp"), 2).FontSize(12).Color(w.pal.muted)
			events := make([]int, len(hookEvents))
			for i := range events {
				events[i] = i
			}
			matchers := make([]int, len(hookMatchers))
			for i := range matchers {
				matchers[i] = i
			}
			event, matcher := f.event, f.matcher
			ui.Select(c.Key("event"), &event, events, func(i int) string { return w.hookEventLabel(hookEvents[i]) }).Label(i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.title")).Height(28)
			ui.Select(c.Key("matcher"), &matcher, matchers, func(i int) string { return w.hookMatcherLabel(hookMatchers[i]) }).Label(i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.matcher.all")).Height(28)
			codex, claude, enabled := f.codex, f.claude, f.enabled
			ui.Row(c).Gap(16).Items(ui.Center).Children(func() {
				ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.agents")).FontSize(12).Color(w.pal.muted)
				ui.Checkbox(c.Key("codex"), &codex, "Codex")
				ui.Checkbox(c.Key("claude"), &claude, "Claude Code")
				ui.Checkbox(c.Key("enabled"), &enabled, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.enabled"))
			})
			next := f
			next.name, next.description, next.command, next.timeout = name, desc, command, timeout
			next.event, next.matcher, next.codex, next.claude, next.enabled = event, matcher, codex, claude, enabled
			if next != f {
				s.mu.Lock()
				s.hooks.form = next
				s.mu.Unlock()
			}
			for i, issue := range st.issues {
				ui.Wrap(c.KeyInt(i), w.hookIssueText(issue)).FontSize(12).Color(w.pal.danger)
			}
			ui.Row(c).Gap(8).Children(func() {
				if ui.Button(c.Key("save"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.hooks.save")).Disabled(st.saving).Clicked() {
					c.After(s.saveHook)
				}
				if ui.Button(c.Key("cancel"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.cancel")).Outline().Clicked() {
					c.After(s.cancelHook)
				}
			})
		})
	})
}

var _ = gfx.Color{}

// limitProblemText is the message of a broken context limit rule.
func limitProblemText(lang i18n.Language, problem limitProblem) string {
	if problem == limitCompactOverWindow {
		return i18n.Shared(lang, "desktop.settings.agent.limits.compactOverWindow")
	}
	return i18n.Shared(lang, "desktop.settings.agent.limits.range")
}
