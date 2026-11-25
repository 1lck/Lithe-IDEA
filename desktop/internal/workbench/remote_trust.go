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
// tools' wrappers, Git) and in safe mode it is only read. Both answers are kept: Core records
// them, per connection and folder, in the preference file remoteconn.ReadTrust names
// (toolchains/remote-trust.json under the toolchain preference root), never on the host or in the
// app's bundle, so a folder already trusted or kept in safe mode opens at once the next time. The
// notice above the editor of a workspace in safe mode, and the Git and Commit windows, trust it at
// any time (workspace_trust.go); trusted, its Git runs on the host (remote_git.go). Every way of
// opening a remote folder comes through openRemoteFolderAt, so none of them trusts a folder the
// user was not asked about.

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
			switch of := trust.State.WorkspaceTrust; {
			case err != nil:
				// The folder opens in safe mode: a remote workspace runs none of its code until
				// it is trusted, and the question comes back the next time.
				a.backgroundFailed("remote_trust_read", documentLogError(err))
				a.openRemoteFolderNow(dir, false)
			case of != nil && of.State == core.WorkspaceTrustUnset:
				r.trust = &remoteTrustPrompt{browser: b, dir: dir, trust: trust}
			default:
				a.openRemoteFolderNow(dir, remoteTrusted(trust.State))
			}
		}
	})
}

// leaveRemoteTrust goes back from the question to the folders.
func (a *App) leaveRemoteTrust() {
	a.remote.trust = nil
}

// remoteTrusted reports whether state, Core's reading for one workspace, lets its code run.
func remoteTrusted(state core.RemoteWorkspaceTrustState) bool {
	of := state.WorkspaceTrust
	return state.ProjectCodeAllowed && of != nil && of.State == core.WorkspaceTrusted
}

// remoteTrustDecision is the decision that trusts, or keeps in safe mode, the workspace trust
// was read for at dir over session, named label among the trusted locations. location also
// trusts the parent folder Core offered.
func remoteTrustDecision(trust remoteconn.Trust, session, dir, label string, trusted, location bool) core.RemoteWorkspaceTrustDecision {
	of := trust.State.WorkspaceTrust
	workspace := dir
	if of != nil && of.Workspace != "" {
		workspace = of.Workspace
	}
	return core.RemoteWorkspaceTrustDecision{
		SessionID: session, Workspace: workspace, Trusted: trusted,
		Location: trusted && location && of != nil && of.OfferedLocation != nil, Label: label,
	}
}

// decideRemoteTrust records the answer to the question and opens the folder: trusted when
// trusted is set, in safe mode otherwise. A trust that cannot be recorded is told in the
// question, which stays; a safe mode that cannot be recorded is told in a notification and the
// folder still opens in safe mode, so the question comes back the next time.
func (a *App) decideRemoteTrust(trusted bool) {
	r := &a.remote
	t := r.trust
	if t == nil || t.deciding || r.browser != t.browser {
		return
	}
	if trusted {
		a.performed("remote.workspace.trust", surfaceButton)
	} else {
		a.performed("remote.workspace.safeMode", surfaceButton)
	}
	decision := remoteTrustDecision(t.trust, t.browser.session.ID, t.dir, t.browser.name, trusted, t.parent)
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
				reason := i18n.SharedFormat(a.language(), "desktop.remote.trust.failed", map[string]string{"reason": documentLogError(err).Error()})
				if trusted {
					t.err = reason
					return
				}
				a.notifyError(reason)
			}
			r.trust = nil
			a.openRemoteFolderNow(t.dir, trusted)
		}
	})
}

// trustRemoteProject records the trust of the open remote workspace p, read again over its
// session so the decision is recorded against Core's record as it is now, and leaves safe mode:
// its Git then runs on the host. A trust that cannot be recorded is told, and p stays in safe
// mode.
func (a *App) trustRemoteProject(p *project, proceed func()) {
	r := p.remote
	if a.remoteTrustUnreachable(p) {
		return
	}
	a.performed("workspace.trust.grant", surfaceButton)
	r.trustRevision++
	revision := r.trustRevision
	kernel, globalRoot, session, dir, label := a.kernel, a.globalToolchainRoot(), r.session, r.binding.RemoteRoot(), r.name
	a.background(p, workspaceTrustTimeout, func(ctx context.Context) func(*App) {
		trust, err := remoteconn.ReadTrust(ctx, kernel, globalRoot, session, dir)
		if err == nil {
			_, err = trust.Decide(ctx, kernel, remoteTrustDecision(trust, session, dir, label, true, false))
		}
		return func(a *App) {
			if err != nil {
				a.backgroundFailed("remote_workspace_trust", documentLogError(err))
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.trust.saveFailed", map[string]string{"reason": documentLogError(err).Error()}))
				return
			}
			if a.project != p || r.closed || r.session != session || r.trustRevision != revision {
				// log-exempt: 用户取消：信任已记录，但工作区或会话已变更，旧结果不能授权新会话。
				return
			}
			a.applyProjectTrust(p, true)
			if proceed != nil {
				proceed()
			}
		}
	})
}

// remoteTrustUnreachable reports whether p is a remote workspace without a session: Core reads
// and records its trust over the session, so trusting it is refused and the notification says
// why.
func (a *App) remoteTrustUnreachable(p *project) bool {
	if r := p.remote; r == nil || r.session != "" {
		return false
	}
	language := a.language()
	a.operationRejected("project_trust", "remote_disconnected")
	a.notifyError(i18n.SharedFormat(language, "desktop.trust.saveFailed", map[string]string{"reason": i18n.Shared(language, "desktop.remote.document.disconnected")}))
	return true
}

// reloadRemoteTrust reads the trust of the open remote workspace p again, after the settings
// window changed it, and applies it. A missing session or failed read leaves code disabled.
func (a *App) reloadRemoteTrust(p *project) {
	r := p.remote
	r.trustRevision++
	revision := r.trustRevision
	if r.session == "" {
		a.applyProjectTrust(p, false)
		// log-exempt: 预期的缺失：远程工作区未连接，无法读取信任，保持安全模式。
		return
	}
	a.applyProjectTrust(p, false)
	kernel, globalRoot, session, dir := a.kernel, a.globalToolchainRoot(), r.session, r.binding.RemoteRoot()
	a.background(p, workspaceTrustTimeout, func(ctx context.Context) func(*App) {
		trust, err := remoteconn.ReadTrust(ctx, kernel, globalRoot, session, dir)
		return func(a *App) {
			if a.project != p || r.closed || r.session != session || r.trustRevision != revision {
				// log-exempt: 用户取消：旧会话的信任读取不再适用。
				return
			}
			if err != nil {
				a.backgroundFailed("remote_trust_read", documentLogError(err))
				return
			}
			a.applyProjectTrust(p, remoteTrusted(trust.State))
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
						ui.Text(c, t.browser.host.address()+" : "+t.dir).Mono().FontSize(small).Ellipsis().Shrink(1).MinWidth(0)
					})
					ui.Paragraph(c, i18n.Shared(language, "desktop.remote.trust.body"), 6).FontSize(small).Color(a.colors.Subtle)
					ui.Column(c.Part("choices")).FillWidth().Gap(4).Pad(12).Radius(8).Stroke(1, a.colors.Line).Children(func() {
						a.remoteTrustChoice(c.Part("full"), language, i18n.Shared(language, "desktop.remote.trust.trustOpen"), i18n.Shared(language, "desktop.remote.trust.full"))
						a.remoteTrustChoice(c.Part("safe"), language, i18n.Shared(language, "desktop.remote.trust.safeOpen"), i18n.Shared(language, "desktop.remote.trust.safe"))
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

// remoteTrustChoice declares an answer's name in bold, then effect, what the folder opens with.
func (a *App) remoteTrustChoice(c ui.C, language i18n.Language, choice, effect string) {
	small := a.theme.Metrics.FontSizeS
	ui.Row(c).FillWidth().Items(ui.Start).Gap(0).Children(func() {
		ui.Text(c, i18n.SharedFormat(language, "desktop.remote.trust.choice", map[string]string{"choice": choice})).
			FontSize(small).Weight(gfx.WeightSemibold).Shrink(0)
		ui.Paragraph(c, effect, 3).FontSize(small).Grow(1).Basis(0).MinWidth(0)
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
