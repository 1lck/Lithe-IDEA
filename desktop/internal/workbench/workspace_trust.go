package workbench

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Workspace trust follows IntelliJ IDEA's trusted projects. Before a folder Lithe has no
// decision for opens, the user is asked to trust it, to preview it in safe mode or not to open
// it; trusting may cover every project of the parent folder. The decision is machine-local,
// kept by Core in the toolchain catalog of the preference directory (toolchains/global.json),
// never in the project. In safe mode the project's code is not run (#2208):
//   - models are not loaded, and Core refuses the plans that would run the build tool, a wrapper
//     or a build extension (plugin.build.untrustedWorkspace);
//   - Core plans no language server, build provider process or version control provider that
//     may run the project's code (plugin.launch.untrustedWorkspace); a language server whose
//     plugin declares it runs none still starts;
//   - no Git runs, since the repository's configuration can name programs Git runs: the window
//     reads no status, and Core refuses any Git of the project's requests
//     (git_untrusted_workspace, core.WithProjectCodeAllowed).
//
// A run, build, test or reload the user asks for first asks to trust the project; the notice
// above the editor, the Git and version control windows and the language server status offer
// it too. Trusting the project loads and starts what safe mode left out (applyProjectTrust).
//
// A remote workspace is trusted the same way, but its decision is Core's record for the
// connection and the host folder (remote_trust.go, remoteconn.ReadTrust), not the catalog's for
// its placeholder. Trusted, its Git runs on the host (remote_git.go); the features that would run
// the host's project on this computer stay off whatever its trust.

// workspaceTrustTimeout bounds reading or saving a trust decision: a Core call and a look at
// the workspace folder.
const workspaceTrustTimeout = 10 * time.Second

// projectTrust is the trust of an open project.
type projectTrust struct {
	// codeAllowed tells the plans built on background goroutines whether the project's code may
	// run (BuildPlanRequest.ProjectCodeAllowed and the like).
	codeAllowed atomic.Bool
	// asking is set while the question to trust the project is shown, so a second action does
	// not queue a second question.
	asking bool
}

// allowed reports whether the project's code may run; any goroutine may ask.
func (t *projectTrust) allowed() bool { return t.codeAllowed.Load() }

// safeMode reports whether p is open without trust.
func (p *project) safeMode() bool { return p != nil && !p.standalone && !p.trust.allowed() }

// openProjectByTrust opens the folder at root once its trust is known. A trusted folder opens at
// once; one the user previewed in safe mode before opens in safe mode; for one with no
// decision the user is asked first, and "Don't Open" leaves the open project as it was. A
// decision that cannot be read opens the folder in safe mode, from where it can be trusted.
func (a *App) openProjectByTrust(root string) {
	if a.trustEveryWorkspace {
		a.openProjectWithTrust(root, true)
		return
	}
	kernel, globalRoot := a.kernel, a.globalToolchainRoot()
	a.background(nil, workspaceTrustTimeout, func(ctx context.Context) func(*App) {
		trust, err := toolchain.ReadWorkspaceTrust(ctx, kernel, globalRoot, root)
		return func(a *App) {
			switch {
			case err != nil:
				a.backgroundFailed("workspace_trust_read", err)
				a.openProjectWithTrust(root, false)
			case trust.State == core.WorkspaceTrusted:
				a.openProjectWithTrust(root, true)
			case trust.State == core.WorkspaceDistrusted:
				a.openProjectWithTrust(root, false)
			default:
				a.askToOpenUntrusted(trust)
			}
		}
	})
}

// askToOpenUntrusted asks before a folder with no trust decision opens: "Trust and Open
// Project", as IDEA asks. The parent folder is offered when Core may trust it as a location.
func (a *App) askToOpenUntrusted(trust toolchain.WorkspaceTrust) {
	language := a.language()
	prompt := &pluginPrompt{
		title: i18n.SharedFormat(language, "desktop.trust.openTitle", map[string]string{"project": filepath.Base(trust.Root)}),
		text:  i18n.Shared(language, "desktop.trust.openText"),
		actions: []string{
			i18n.Shared(language, "desktop.trust.dontOpen"),
			i18n.Shared(language, "desktop.trust.previewSafeMode"),
			i18n.Shared(language, "desktop.trust.trustProject"),
		},
	}
	if trust.OfferedLocation != nil {
		home, _ := os.UserHomeDir()
		folder := *trust.OfferedLocation
		short := trustFolderLabel(folder, home)
		prompt.check = i18n.SharedFormat(language, "desktop.trust.location", map[string]string{"folder": short})
		if short != welcomeShorten(filepath.FromSlash(folder), home) {
			prompt.checkFull = i18n.SharedFormat(language, "desktop.trust.location", map[string]string{"folder": filepath.FromSlash(folder)})
		}
	}
	prompt.onAnswer = func(choice *int) {
		if choice == nil || *choice == 0 {
			// A project tab made to open the folder has nothing to show without it.
			if a.project == nil {
				a.sessions.leave(a)
			}
			return
		}
		trusted := *choice == 2
		a.saveWorkspaceTrust(trust, trusted, trusted && prompt.checked, func(saved bool) {
			a.openProjectWithTrust(trust.Root, trusted && saved)
		})
	}
	a.prompts.queue = append(a.prompts.queue, prompt)
}

// trustFolderMaxRunes is the longest folder the trust question's checkbox names in full: the
// checkbox is one line in a dialog 520 points wide.
const trustFolderMaxRunes = 48

// trustFolderLabel is how the checkbox names folder: under home as "~" plus the rest, as IDEA
// writes it, and a longer one with its middle left out, so its start and its own name stay.
func trustFolderLabel(folder, home string) string {
	label := []rune(welcomeShorten(filepath.FromSlash(folder), home))
	if len(label) <= trustFolderMaxRunes {
		return string(label)
	}
	head := trustFolderMaxRunes / 3
	tail := trustFolderMaxRunes - head - 1
	return string(label[:head]) + "…" + string(label[len(label)-tail:])
}

// saveWorkspaceTrust records the user's decision and calls done with whether it was kept. A
// decision that cannot be saved is told and logged; the caller then treats the workspace as
// not trusted, since nothing on disk says it is.
func (a *App) saveWorkspaceTrust(trust toolchain.WorkspaceTrust, trusted, location bool, done func(saved bool)) {
	kernel := a.kernel
	if trusted {
		a.performed("workspace.trust.grant", surfaceButton)
	} else {
		a.performed("workspace.trust.distrust", surfaceButton)
	}
	a.background(nil, workspaceTrustTimeout, func(ctx context.Context) func(*App) {
		_, err := trust.Save(ctx, kernel, trusted, location)
		return func(a *App) {
			if err != nil {
				a.backgroundFailed("workspace_trust_save", err)
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.trust.saveFailed", map[string]string{"reason": err.Error()}))
			}
			done(err == nil)
		}
	})
}

// requireProjectTrust runs proceed at once in a trusted project. In safe mode it first asks
// to trust the project ("Trust Project" or "Stay in Safe Mode"); proceed runs once the trust
// is saved, and not at all when the user stays in safe mode.
func (a *App) requireProjectTrust(p *project, proceed func()) {
	if p == nil {
		return
	}
	if !p.safeMode() {
		proceed()
		return
	}
	a.askToTrustProject(p, proceed)
}

// askToTrustProject asks to trust the open project p in safe mode, from the notice above the
// editor or before an action that runs project code; then, when set, it runs proceed.
func (a *App) askToTrustProject(p *project, proceed func()) {
	if p.trust.asking || a.remoteTrustUnreachable(p) {
		return
	}
	p.trust.asking = true
	language := a.language()
	a.prompts.queue = append(a.prompts.queue, &pluginPrompt{
		title: i18n.Shared(language, "desktop.trust.title"),
		text:  i18n.Shared(language, "desktop.trust.actionText"),
		actions: []string{
			i18n.Shared(language, "desktop.trust.stayInSafeMode"),
			i18n.Shared(language, "desktop.trust.trustProject"),
		},
		onAnswer: func(choice *int) {
			p.trust.asking = false
			if choice == nil || *choice != 1 || a.project != p {
				return
			}
			a.trustOpenProject(p, proceed)
		},
	})
}

// trustOpenProject saves the trust of the open project p, read again so the decision is saved
// against the catalog as it is now, and leaves safe mode.
func (a *App) trustOpenProject(p *project, proceed func()) {
	if p.remote != nil {
		a.trustRemoteProject(p, proceed)
		return
	}
	kernel, globalRoot, root := a.kernel, a.globalToolchainRoot(), p.root
	a.background(p, workspaceTrustTimeout, func(ctx context.Context) func(*App) {
		trust, err := toolchain.ReadWorkspaceTrust(ctx, kernel, globalRoot, root)
		return func(a *App) {
			if err != nil {
				a.backgroundFailed("workspace_trust_read", err)
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.trust.saveFailed", map[string]string{"reason": err.Error()}))
				return
			}
			a.saveWorkspaceTrust(trust, true, false, func(saved bool) {
				if !saved || a.project != p {
					return
				}
				a.applyProjectTrust(p, true)
				if proceed != nil {
					proceed()
				}
			})
		}
	})
}

// reloadProjectTrust reads the trust of the open project again, after the settings window
// changed it, and applies it.
func (a *App) reloadProjectTrust(p *project) {
	if p != nil && p.remote != nil {
		a.reloadRemoteTrust(p)
		return
	}
	if p == nil || a.trustEveryWorkspace {
		return
	}
	kernel, globalRoot, root := a.kernel, a.globalToolchainRoot(), p.root
	a.background(p, workspaceTrustTimeout, func(ctx context.Context) func(*App) {
		trust, err := toolchain.ReadWorkspaceTrust(ctx, kernel, globalRoot, root)
		return func(a *App) {
			if err != nil {
				a.backgroundFailed("workspace_trust_read", err)
				return
			}
			if a.project == p {
				a.applyProjectTrust(p, trust.State == core.WorkspaceTrusted)
			}
		}
	})
}

// applyProjectTrust makes trusted the trust of p. Leaving safe mode loads what safe mode left
// out: Git and the version control provider, the models, and through them the run
// configurations of the title bar, and the language servers Core planned none for or that
// failed for want of the workspace's tools. Entering it again stops Git at once, both the status
// and the watch of the repository's metadata; the language servers already running keep running
// until the project closes.
func (a *App) applyProjectTrust(p *project, trusted bool) {
	was := p.trust.allowed()
	p.trust.codeAllowed.Store(trusted)
	if trusted == was {
		return
	}
	if !trusted {
		a.closeGitObservation(p)
		a.loadGit(p)
		return
	}
	a.loadGit(p)
	a.startGitObservation(p)
	if p.remote != nil {
		// A remote workspace's Git runs on its host; its build tools and language servers do not
		// run yet, so trusting it starts nothing else.
		return
	}
	p.vcs.clearFailures()
	for index := range p.build.instances {
		instance := &p.build.instances[index]
		if instance.modelUntrusted {
			instance.modelUntrusted, instance.modelStopped, instance.modelError = false, false, ""
		}
	}
	a.loadTitleRunConfigs(p)
	a.retryFailedPluginServers()
}

// skipUntrustedModel keeps the model of instance unloaded in safe mode, since loading it runs
// the build tool. The Build window says so in place of the model, and a reload asks to trust.
func (a *App) skipUntrustedModel(instance *buildInstance) {
	instance.modelUntrusted, instance.modelStopped = true, true
	instance.modelError = i18n.Shared(a.language(), "desktop.trust.modelSafeMode")
}

// safeModePanel declares what a tool window shows in safe mode in place of what it would read by
// running project code: message, and the button that asks to trust the project.
func (a *App) safeModePanel(c ui.C, p *project, message string) {
	ui.Column(c).Fill().Center().Gap(8).PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, message, 3).FillWidth().TextCenter().Color(a.colors.Subtle)
		if ui.Button(c.Key("trust"), i18n.Shared(a.language(), "desktop.trust.bannerLink")).Ghost().Disabled(p.trust.asking).Clicked() {
			c.After(func() { a.askToTrustProject(p, nil) })
		}
	})
}

// remoteLocalOnlyPanel declares what a tool window that reads or runs the project on this
// computer shows in a remote workspace: that it does not work there yet. Trust does not change
// it, so it has no button.
func (a *App) remoteLocalOnlyPanel(c ui.C) {
	ui.Column(c).Fill().Center().PadX(shellContentPad).Children(func() {
		ui.Paragraph(c, i18n.Shared(a.language(), "desktop.remote.workspace.localOnly"), 3).FillWidth().TextCenter().Color(a.colors.Subtle)
	})
}

// safeModeNotice declares the notice above the editor of a project in safe mode, with the link
// that asks to trust it, as IDEA's editor notification does. A remote workspace's notice also
// stands over its empty editor: in safe mode it says so, with the link, and trusted it says what
// works in a remote workspace, with none.
func (a *App) safeModeNotice(c ui.C, p *project) {
	background, border, foreground := gfx.RGB24(0xFFF6E9), gfx.RGB24(0xF4CD9A), gfx.RGB24(0x000000)
	if a.colors.Dark {
		background, border, foreground = gfx.RGB24(0x44321D), gfx.RGB24(0x694820), gfx.RGB24(0xD1D3D9)
	}
	language := a.language()
	ui.Column(c).FillWidth().Shrink(0).Background(background).Children(func() {
		ui.Row(c.Part("top")).FillWidth().Height(1).Shrink(0).Background(border)
		ui.Row(c).FillWidth().Gap(conflictGap).PadX(conflictPadX).PadY(conflictPadY).Items(ui.Center).Children(func() {
			ui.Icon(c, icons.BannerWarning).Size(conflictIcon, conflictIcon).Shrink(0).Color(gfx.RGB24(0xFFFFFF))
			text, link := i18n.Shared(language, "desktop.trust.banner"), true
			switch {
			case p.remote != nil && p.safeMode():
				text = i18n.Shared(language, "desktop.remote.workspace.safeBanner")
			case p.remote != nil:
				text, link = i18n.Shared(language, "desktop.remote.workspace.banner"), false
			}
			ui.Paragraph(c, text, conflictMaxRows).FontSize(13).Color(foreground).Grow(1).Shrink(1)
			if link && ui.Button(c.Key("trust"), i18n.Shared(language, "desktop.trust.bannerLink")).Link().Disabled(p.trust.asking).Clicked() {
				c.After(func() { a.askToTrustProject(p, nil) })
			}
		})
		ui.Row(c.Part("bottom")).FillWidth().Height(1).Shrink(0).Background(border)
	})
}
