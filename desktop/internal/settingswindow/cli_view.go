package settingswindow

import (
	"context"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/cli"
	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

type cliRequest struct {
	baseline cli.State
	action   string
}

type cliRegistration struct {
	effect  *ui.EffectState[cli.State, *cliRequest]
	request *cliRequest
	state   cli.State
	err     error
	loaded  bool
	changed bool
}

func (w *window) declareCLI(c ui.C) {
	s := &w.cli
	if s.effect != nil && s.request != nil {
		ui.Effect(c, s.effect, s.request)
	}
}

// General > CLI reports the captured native source, and only the explicit
// install/remove button can publish. Leaving or cancelling settings never writes.
func (w *window) cliCard(c ui.C) {
	manager := w.ctrl.opts.CLI
	if manager == nil {
		return
	}
	s := &w.cli
	language := w.marketLanguage()
	if s.effect == nil {
		s.effect = ui.NewEffectKeyed[cli.State, *cliRequest](func(parent context.Context, request *cliRequest) (cli.State, error) {
			ctx, cancel := context.WithTimeout(parent, 10*time.Second)
			defer cancel()
			if request.action == "read" {
				return manager.Read(ctx)
			}
			return manager.Apply(ctx, request.baseline, request.action == "install")
		})
		s.request = &cliRequest{action: "read"}
	}
	if state, err, ok := s.effect.Take(); ok {
		s.changed = s.request != nil && s.request.action != "read" && err == nil
		s.request, s.err, s.loaded = nil, err, err == nil
		if err == nil {
			s.state = state
		} else {
			// log-exempt: 用户取消：关闭设置窗口撤销尚未发布的读取或注册请求。
			if !errors.Is(err, context.Canceled) {
				reportSettingsError(w.ctrl.opts, "cli_registration", err)
			}
		}
	}
	w.card(c, i18n.Shared(language, "desktop.cli.title"), i18n.Shared(language, "desktop.cli.help"), func() {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(10).Children(func() {
			status := i18n.Shared(language, "desktop.cli.notRegistered")
			if s.state.Installed {
				status = i18n.Shared(language, "desktop.cli.registered")
			}
			if s.request != nil {
				status = i18n.Shared(language, "native.loading")
			}
			ui.Text(c, status).Color(w.pal.muted).Grow(1)
			if s.loaded {
				label, action := i18n.Shared(language, "desktop.cli.register"), "install"
				if s.state.Registered {
					label, action = i18n.Shared(language, "desktop.cli.remove"), "remove"
				}
				if ui.Button(c, label).Outline().Disabled(s.request != nil).Clicked() {
					c.After(func() {
						if w.ctrl.opts.CLIAction != nil {
							w.ctrl.opts.CLIAction(action)
						}
						s.request = &cliRequest{baseline: s.state, action: action}
					})
				}
			}
			if s.loaded && s.state.Registered && !s.state.Installed {
				if ui.Button(c, i18n.Shared(language, "desktop.cli.repair")).Outline().Disabled(s.request != nil).Clicked() {
					c.After(func() {
						if w.ctrl.opts.CLIAction != nil {
							w.ctrl.opts.CLIAction("repair")
						}
						s.request = &cliRequest{baseline: s.state, action: "install"}
					})
				}
			}
			if ui.Button(c, i18n.Shared(language, "desktop.cli.refresh")).Ghost().Disabled(s.request != nil).Clicked() {
				c.After(func() {
					if w.ctrl.opts.CLIAction != nil {
						w.ctrl.opts.CLIAction("refresh")
					}
					s.request = &cliRequest{action: "read"}
				})
			}
		})
		if s.loaded {
			ui.Wrap(c, i18n.SharedFormat(language, "desktop.cli.source", map[string]string{"target": s.state.Target})).FontSize(11).Color(w.pal.subtle)
			ui.Wrap(c, s.state.Launcher).Mono().FontSize(11).Color(w.pal.subtle)
		}
		if s.changed {
			ui.Wrap(c, i18n.Shared(language, "desktop.cli.reopenTerminal")).FontSize(12).Color(w.pal.muted)
		}
		if s.err != nil {
			message := i18n.Shared(language, "desktop.cli.failed")
			switch {
			case errors.Is(s.err, cli.ErrUnsupportedShell):
				message = i18n.Shared(language, "desktop.cli.unsupportedShell")
			case errors.Is(s.err, cli.ErrLauncherConflict):
				message = i18n.Shared(language, "desktop.cli.launcherConflict")
			case errors.Is(s.err, configfile.ErrConflict):
				message = i18n.Shared(language, "desktop.cli.conflict")
			}
			ui.Wrap(c, message).FontSize(12).Color(w.pal.danger)
		}
	})
}
