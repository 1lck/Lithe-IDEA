package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Before a remote folder opens the first time, the window asks whether to trust it, as the
// editor asks of a local folder: trusted, the folder's own code may run (its tasks, its build
// tools' wrappers); in safe mode it is only read. Core keeps the answers, per connection and
// folder, in the preference file remoteconn.ReadTrust names (toolchains/remote-trust.json under
// the toolchain preference root), never on the host or in the app's bundle. A folder already
// trusted or distrusted opens at once. Opening in safe mode records nothing, so the question
// comes back the next time.

// remoteTrustPrompt is the question asked before dir opens over browser's session.
type remoteTrustPrompt struct {
	browser *remoteBrowser
	dir     string
	trust   remoteconn.Trust
	// parent is set to trust the folder above dir as well, so that its other folders open
	// trusted.
	parent   bool
	deciding bool
	err      string
}

// openRemoteFolderAt opens dir over the browser's session, asking first whether to trust it
// when that was never decided.
func (a *App) openRemoteFolderAt(dir string) {
	r := &a.remote
	b := r.browser
	if !r.open || b == nil || b.opening {
		return
	}
	b.opening, b.err = true, ""
	generation, kernel, root, session := r.generation, a.kernel, a.globalToolchainRoot(), b.session.ID
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		trust, err := remoteconn.ReadTrust(ctx, kernel, root, session, dir)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.browser != b {
				// log-exempt: 用户取消：窗口已关闭或已返回，会话已随之结束。
				return
			}
			b.opening = false
			if err != nil {
				// The folder opens in safe mode: a remote workspace runs none of its code until
				// it is trusted, and the question comes back the next time.
				a.backgroundFailed("remote_trust_read", documentLogError(err))
			} else if of := trust.State.WorkspaceTrust; of != nil && of.State == core.WorkspaceTrustUnset {
				r.trust = &remoteTrustPrompt{browser: b, dir: dir, trust: trust}
				return
			}
			a.openRemoteFolderNow(dir)
		}
	})
}

// leaveRemoteTrust goes back from the question to the folders.
func (a *App) leaveRemoteTrust() {
	a.remote.trust = nil
}

// decideRemoteTrust opens the folder asked about, trusting it first when trusted is set.
func (a *App) decideRemoteTrust(trusted bool) {
	r := &a.remote
	t := r.trust
	if t == nil || t.deciding || r.browser != t.browser {
		return
	}
	if !trusted {
		a.performed("remote.workspace.safeMode", surfaceButton)
		r.trust = nil
		a.openRemoteFolderNow(t.dir)
		return
	}
	a.performed("remote.workspace.trust", surfaceButton)
	of := t.trust.State.WorkspaceTrust
	workspace := t.dir
	if of != nil && of.Workspace != "" {
		workspace = of.Workspace
	}
	decision := core.RemoteWorkspaceTrustDecision{
		SessionID: t.browser.session.ID, Workspace: workspace, Trusted: true,
		Location: t.parent && of != nil && of.OfferedLocation != nil, Label: t.browser.name,
	}
	t.deciding, t.err = true, ""
	generation, kernel, trust := r.generation, a.kernel, t.trust
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		_, err := trust.Decide(ctx, kernel, decision)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.trust != t {
				// log-exempt: 用户取消：窗口已关闭或已返回。
				return
			}
			t.deciding = false
			if err != nil {
				a.operationFailed("remote_workspace_trust", documentLogError(err))
				t.err = i18n.SharedFormat(a.language(), "desktop.remote.trust.failed", map[string]string{"reason": documentLogError(err).Error()})
				return
			}
			r.trust = nil
			a.openRemoteFolderNow(t.dir)
		}
	})
}

// remoteTrustView declares the question: the folder on its host, what trusting it lets run, what
// each answer opens it with, and whether to trust the folders beside it too.
func (a *App) remoteTrustView(c ui.C, language i18n.Language, t *remoteTrustPrompt) {
	small := a.theme.Metrics.FontSizeS
	of := t.trust.State.WorkspaceTrust
	ui.Scroll(c.Part("trust")).Fill().Children(func() {
		ui.Column(c).FillWidth().Items(ui.Center).PadSides(28, 32, 32, 32).Children(func() {
			ui.Row(c.Part("card")).Width(560).Gap(14).Children(func() {
				ui.Row(c.Part("mark")).Size(40, 40).Shrink(0).Center().Radius(8).Background(a.colors.Warning).Children(func() {
					ui.Text(c, "!").FontSize(16).Weight(gfx.WeightBold).Color(gfx.RGB24(0xFFFFFF))
				})
				ui.Column(c).Grow(1).Basis(0).MinWidth(0).Gap(12).Children(func() {
					ui.Column(c).FillWidth().Gap(6).Children(func() {
						ui.Text(c, i18n.Shared(language, "desktop.remote.trust.title")).FontSize(16).Weight(gfx.WeightSemibold)
						ui.Text(c, remoteAddress(t.browser.connection)+" : "+t.dir).Mono().FontSize(small).Ellipsis().Shrink(1).MinWidth(0)
					})
					ui.Paragraph(c.Part("body"), i18n.Shared(language, "desktop.remote.trust.body"), 6).FontSize(small).Color(a.colors.Subtle)
					ui.Column(c.Part("choices")).FillWidth().Gap(4).Pad(12).Radius(8).Stroke(1, a.colors.Line).Children(func() {
						a.remoteTrustChoice(c.Part("full"), language, "desktop.remote.trust.trustOpen", "desktop.remote.trust.full")
						a.remoteTrustChoice(c.Part("safe"), language, "desktop.remote.trust.safeOpen", "desktop.remote.trust.safe")
					})
					if of != nil && of.OfferedLocation != nil {
						ui.Checkbox(c.Part("parent"), &t.parent, i18n.SharedFormat(language, "desktop.remote.trust.parent", map[string]string{"parent": *of.OfferedLocation})).
							Disabled(t.deciding)
					}
					if t.err != "" {
						a.remoteNotice(c.Part("error"), icons.CircleX, a.theme.Danger, t.err)
					}
				})
			})
		})
	})
}

// remoteTrustChoice declares an answer in bold, then what the folder opens with after it.
func (a *App) remoteTrustChoice(c ui.C, language i18n.Language, choice, effect string) {
	small := a.theme.Metrics.FontSizeS
	ui.Row(c).FillWidth().Items(ui.Start).Gap(0).Children(func() {
		ui.Text(c, i18n.SharedFormat(language, "desktop.remote.trust.choice", map[string]string{"choice": i18n.Shared(language, choice)})).
			FontSize(small).Weight(gfx.WeightSemibold).Shrink(0)
		ui.Paragraph(c, i18n.Shared(language, effect), 3).FontSize(small).Grow(1).Basis(0).MinWidth(0)
	})
}

// remoteTrustFooter declares where the answer is kept and the question's answers.
func (a *App) remoteTrustFooter(c ui.C, language i18n.Language, t *remoteTrustPrompt) {
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		ui.Icon(c, icons.Info).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
		ui.Text(c, i18n.Shared(language, "desktop.remote.trust.local")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
		ui.Spacer(c)
		if ui.Button(c.Part("back"), i18n.Shared(language, "desktop.remote.trust.back")).Outline().Disabled(t.deciding).Clicked() {
			c.After(a.leaveRemoteTrust)
		}
		if ui.Button(c.Part("safe"), i18n.Shared(language, "desktop.remote.trust.safeOpen")).Outline().Disabled(t.deciding).Clicked() {
			c.After(func() { a.decideRemoteTrust(false) })
		}
		if ui.Button(c.Part("trust"), i18n.Shared(language, "desktop.remote.trust.trustOpen")).Disabled(t.deciding).Clicked() {
			c.After(func() { a.decideRemoteTrust(true) })
		}
	})
}
