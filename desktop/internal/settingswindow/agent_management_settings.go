package settingswindow

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// agentManagementBackend is the optional Core surface of the environment and adapter card.
// It is separate from AgentSettingsBackend so existing backends keep satisfying that
// interface; *core.Client satisfies both.
type agentManagementBackend interface {
	ReadAgentManagementStatus(ctx context.Context, dataDirectory string) (core.AgentManagementStatus, error)
	InstallAgentAdapter(ctx context.Context, dataDirectory, agentID string, progress func(core.AgentInstallProgress)) (core.AgentAdapterInstallResult, error, error)
	UninstallAgentAdapter(ctx context.Context, dataDirectory, agentID string) error
}

// agentManagementState is the card's last reading and the change in progress. Nothing is
// read when the page opens; the reading starts only from the Check button.
type agentManagementState struct {
	loaded, loading, busy bool
	status                core.AgentManagementStatus
	err                   error
	notice                string
	uninstalled           bool
}

func (s *agentSettings) managementBackend() agentManagementBackend {
	m, _ := s.backend.(agentManagementBackend)
	return m
}

// checkManagement reads the runtime and the adapter state off the window thread.
func (s *agentSettings) checkManagement() {
	m := s.managementBackend()
	s.mu.Lock()
	st := &s.management
	if m == nil || st.loading || st.busy {
		s.mu.Unlock()
		return
	}
	st.loading, st.err, st.notice, st.uninstalled = true, nil, "", false
	dir := s.dir()
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		status, err := m.ReadAgentManagementStatus(ctx, dir)
		s.mu.Lock()
		defer s.mu.Unlock()
		st := &s.management
		st.loading, st.loaded, st.err = false, true, err
		if err == nil {
			st.status = status
		}
	})
}

// changeAdapter installs or uninstalls the selected Agent's adapter after an explicit press,
// then reads the state again so the card shows what Core now reports.
func (s *agentSettings) changeAdapter(install bool) {
	m := s.managementBackend()
	s.mu.Lock()
	st := &s.management
	if m == nil || st.busy || st.loading {
		s.mu.Unlock()
		return
	}
	st.busy, st.err, st.notice, st.uninstalled = true, nil, "", false
	id, dir := s.agentID(), s.dir()
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		var err error
		var installed core.AgentAdapterInstallResult
		if install {
			installed, _, err = m.InstallAgentAdapter(ctx, dir, id, nil)
		} else {
			err = m.UninstallAgentAdapter(ctx, dir, id)
		}
		status, readErr := m.ReadAgentManagementStatus(ctx, dir)
		s.mu.Lock()
		defer s.mu.Unlock()
		st := &s.management
		st.busy, st.loaded = false, true
		if err != nil {
			st.err = err
		} else if install {
			st.notice = installed.InstalledVersion
		} else {
			st.uninstalled = true
		}
		if readErr == nil {
			st.status = status
		} else if st.err == nil {
			st.err = readErr
		}
	})
}

// managementCard declares the runtime check and the selected Agent's adapter actions. It is
// hidden when the backend cannot manage adapters.
func (w *window) managementCard(c ui.C) {
	s := w.agent
	if s.managementBackend() == nil {
		return
	}
	lang := w.marketLanguage()
	s.mu.Lock()
	st := s.management
	s.mu.Unlock()
	w.card(c, i18n.Shared(lang, "desktop.settings.agent.management.title"), i18n.Shared(lang, "desktop.settings.agent.management.help"), func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			if st.loading || st.busy {
				ui.Text(c, i18n.Shared(lang, "desktop.settings.agent.management.working")).FontSize(12).Color(w.pal.muted)
			}
			w.agentError(c, st.err)
			if st.notice != "" {
				ui.Text(c, i18n.SharedFormat(lang, "desktop.settings.agent.management.installed", map[string]string{"version": st.notice})).FontSize(12).Color(w.pal.muted)
			} else if st.uninstalled {
				ui.Text(c, i18n.Shared(lang, "desktop.settings.agent.management.uninstalled")).FontSize(12).Color(w.pal.muted)
			}
			if st.loaded {
				w.managementStatus(c, st.status, s.agentID())
			}
			if ui.Button(c.Key("check"), i18n.Shared(lang, "desktop.settings.agent.management.check")).Outline().Disabled(st.loading || st.busy).Clicked() {
				c.After(s.checkManagement)
			}
		})
	})
}

// managementStatus shows the runtime tools and the selected adapter, with its install or
// uninstall action.
func (w *window) managementStatus(c ui.C, status core.AgentManagementStatus, agentID string) {
	s := w.agent
	lang := w.marketLanguage()
	ui.Text(c, i18n.SharedFormat(lang, "desktop.settings.agent.management.node", map[string]string{"version": toolVersion(status.Environment.Node, lang)})).FontSize(12).Color(w.pal.muted)
	ui.Text(c, i18n.SharedFormat(lang, "desktop.settings.agent.management.npm", map[string]string{"version": toolVersion(status.Environment.NPM, lang)})).FontSize(12).Color(w.pal.muted)
	for _, agent := range status.Agents {
		if agent.ID != agentID {
			continue
		}
		if agent.InstalledVersion != nil {
			ui.Text(c, i18n.SharedFormat(lang, "desktop.settings.agent.management.installed", map[string]string{"version": *agent.InstalledVersion})).FontSize(12).Color(w.pal.text)
			if ui.Button(c.Key("uninstall"), i18n.Shared(lang, "desktop.settings.agent.management.uninstall")).Outline().Clicked() {
				c.After(func() { s.changeAdapter(false) })
			}
		} else {
			ui.Text(c, i18n.Shared(lang, "desktop.settings.agent.management.notInstalled")).FontSize(12).Color(w.pal.muted)
			if ui.Button(c.Key("install"), i18n.Shared(lang, "desktop.settings.agent.management.install")).Outline().Clicked() {
				c.After(func() { s.changeAdapter(true) })
			}
		}
	}
}

// toolVersion is a runtime tool's version, or the not-found text when Core detected none.
func toolVersion(tool *core.AgentTool, lang i18n.Language) string {
	if tool == nil || tool.Version == "" {
		return i18n.Shared(lang, "desktop.settings.agent.management.notFound")
	}
	return tool.Version
}
