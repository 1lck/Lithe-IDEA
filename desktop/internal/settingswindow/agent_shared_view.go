package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// sharedCard is the shared instruction section of the Instructions page: one editor for the
// shared text and a switch per Agent that says whether its native file carries the block.
func (w *window) sharedCard(c ui.C) {
	s := w.agent
	s.mu.Lock()
	st := s.shared
	s.mu.Unlock()
	language := w.marketLanguage()
	w.card(c, i18n.Shared(language, "desktop.settings.agent.shared.title"), i18n.Shared(language, "desktop.settings.agent.shared.help"), func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			if st.loading && !st.loaded {
				ui.Text(c, i18n.Shared(language, "desktop.settings.agent.loading")).FontSize(12).Color(w.pal.muted)
				return
			}
			w.agentError(c, st.err)
			if !st.loaded {
				if ui.Button(c.Key("sharedRetry"), i18n.Shared(language, "desktop.settings.agent.reload")).Outline().Clicked() {
					c.After(func() { s.beginShared(true) })
				}
				return
			}
			ui.Text(c, i18n.SharedFormat(language, "desktop.settings.agent.shared.path", map[string]string{"path": st.lib.File.Path})).
				FontSize(12).Color(w.pal.muted).Ellipsis()
			if st.conflict {
				ui.Wrap(c, i18n.Shared(language, "desktop.settings.agent.shared.conflict")).FontSize(12).Color(w.pal.danger)
			}
			draft := st.draft
			ui.TextArea(c.Key("sharedEditor"), &draft, i18n.Shared(language, "desktop.settings.agent.shared.placeholder"), "").
				FillWidth().Height(160).Disabled(st.saving)
			if draft != st.draft {
				s.mu.Lock()
				s.shared.draft, s.shared.saved = draft, false
				s.mu.Unlock()
			}
			dirty := st.dirty() || draft != st.draft
			if dirty {
				ui.Text(c, i18n.Shared(language, "desktop.settings.agent.shared.dirty")).FontSize(12).Color(w.pal.muted)
			}
			if st.saved {
				ui.Text(c, i18n.Shared(language, "desktop.settings.agent.shared.saved")).FontSize(12).Color(w.pal.muted)
			}
			ui.Row(c).Gap(8).Children(func() {
				if ui.Button(c.Key("sharedSave"), i18n.Shared(language, "desktop.settings.agent.shared.save")).Disabled(!dirty || st.saving).Clicked() {
					c.After(s.saveShared)
				}
				if ui.Button(c.Key("sharedReload"), i18n.Shared(language, "desktop.settings.agent.reload")).Outline().Disabled(st.saving || st.loading).Clicked() {
					c.After(func() { s.beginShared(true) })
				}
			})
			for _, target := range st.lib.Agents {
				w.sharedTargetRow(c, target, st.toggling == target.AgentID, st.saving || st.toggling != "")
			}
		})
	})
}

// sharedTargetRow is one Agent: its native file, whether the block is there and the switch.
func (w *window) sharedTargetRow(c ui.C, target core.AgentSharedTarget, busy, locked bool) {
	s := w.agent
	language := w.marketLanguage()
	name := providerSourceName(target.AgentID)
	if target.AgentID == "codex-acp" {
		name = "Codex"
	} else if target.AgentID == "claude-acp" {
		name = "Claude Code"
	}
	ui.Row(c.Key("shared/" + target.AgentID)).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		ui.Column(c).Grow(1).Gap(1).Children(func() {
			switch {
			case target.File != nil:
				ui.Text(c, i18n.SharedFormat(language, "desktop.settings.agent.shared.target", map[string]string{"name": name, "path": target.File.Path})).
					FontSize(12).Color(w.pal.muted).Ellipsis()
			default:
				ui.Text(c, i18n.SharedFormat(language, "desktop.settings.agent.shared.noFile", map[string]string{"name": name})).FontSize(12).Color(w.pal.muted)
			}
			if target.Issue != nil {
				ui.Wrap(c.Key("issue"), *target.Issue).FontSize(12).Color(w.pal.danger)
			} else if target.Enabled == nil {
				ui.Text(c, i18n.Shared(language, "desktop.settings.agent.shared.unknown")).FontSize(12).Color(w.pal.muted)
			} else if target.NeedsSync {
				ui.Text(c, i18n.Shared(language, "desktop.settings.agent.shared.needsSync")).FontSize(12).Color(w.pal.muted)
			}
		})
		on := target.Enabled != nil && *target.Enabled
		value := on
		// The switch writes a click into value only when it is asked, after Disabled is set.
		toggle := ui.Switch(c.Key("sync/"+target.AgentID), &value, i18n.SharedFormat(language, "desktop.settings.agent.shared.enable", map[string]string{"name": name})).
			Disabled(target.File == nil || target.Enabled == nil || busy || locked)
		if toggle.Changed() && value != on {
			agentID, enabled := target.AgentID, value
			c.After(func() { s.setSharedEnabled(agentID, enabled) })
		}
	})
}
