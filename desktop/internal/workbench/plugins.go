package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sheet"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	pluginReviewScope   = tree.ID(shellPage, "plugin-review-scope")
	pluginReviewDismiss = tree.ID(shellPage, "plugin-review-dismiss")
	pluginReviewInstall = tree.ID(shellPage, "plugin-review-install")
	pluginReviewCancel  = tree.ID(shellPage, "plugin-review-cancel")
)

const (
	// pluginDownloadTimeout bounds one marketplace download.
	pluginDownloadTimeout = 5 * time.Minute
	// pluginInstallTimeout bounds an extraction, a review or a commit.
	pluginInstallTimeout = 2 * time.Minute
	// pluginStateTimeout bounds a listing of the installed packages.
	pluginStateTimeout = 30 * time.Second
)

// pluginInstallState is the install the user started, from the click until the
// review sheet closes.
//
// Downloading and extracting happen off the window thread; the review is the only
// part the user sees, and nothing is installed before it closes with a confirm.
type pluginInstallState struct {
	// open says the review sheet is showing.
	open bool
	// busy says an archive is being downloaded and reviewed.
	busy bool
	// plugin is what the user asked to install.
	plugin core.MarketplacePlugin
	// plan is the prepared package, valid while open.
	plan plugininstall.Plan
	// generation rejects the result of an install the user replaced or cancelled.
	generation uint64
}

// refreshPluginState reloads what the marketplace page shows about installed
// plugins. It is called when the page opens and after every change, and it answers
// from memory while painting.
func (a *App) refreshPluginState() {
	if a.plugins == nil {
		return
	}
	a.background(nil, pluginStateTimeout, func(context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_list", err))
				return
			}
			states := make(map[string]settingswindow.PluginState, len(entries))
			for _, entry := range entries {
				states[entry.Installed.ID] = settingswindow.PluginState{
					Installed: true,
					Version:   entry.Installed.Version,
					Enabled:   entry.Enabled,
				}
			}
			a.pluginState.Store(&states)
		}
	})
}

// installPlugin downloads and reviews one marketplace version.
//
// Nothing is installed here: the review sheet opens with what the package asks for,
// and only confirmPluginInstall writes anything the user can run.
func (a *App) installPlugin(plugin core.MarketplacePlugin) {
	if a.plugins == nil {
		return
	}
	if plugin.Availability.Status != "available" || plugin.Availability.DownloadURL == "" {
		a.notify(i18n.Shared(a.language(), "desktop.marketplace.installFailed"))
		return
	}
	a.pluginInstall.generation++
	generation := a.pluginInstall.generation
	// A review may still be open in the settings window's own page; the user can
	// start another install from there, so the earlier package is dropped here
	// rather than left in the staging area with no owner.
	a.discardPluginInstall()
	a.pluginInstall.plugin = plugin
	a.pluginInstall.busy = true
	a.pluginInstall.open = false
	a.performed("plugin.install", "marketplace")
	availability := plugin.Availability
	a.background(nil, pluginDownloadTimeout, func(ctx context.Context) func(*App) {
		archive, err := marketplace.NewArchiveDownloader(nil).Download(ctx, availability)
		if err != nil {
			return func(a *App) { a.finishPluginInstall(generation, plugininstall.Plan{}, err) }
		}
		// Extraction copies what it needs into the staging directory, so the
		// download is no longer needed once Prepare returns.
		defer archive.Discard()
		plan, err := a.plugins.Installer.Prepare(ctx, plugininstall.Request{
			ArchivePath:     archive.Path(),
			Root:            a.plugins.Root,
			Source:          plugintrust.Marketplace,
			ArchiveSHA256:   availability.SHA256,
			ExpectedID:      plugin.ID,
			ExpectedVersion: availability.Version,
		})
		return func(a *App) { a.finishPluginInstall(generation, plan, err) }
	})
}

// finishPluginInstall takes the prepared plan back on the window thread.
func (a *App) finishPluginInstall(generation uint64, plan plugininstall.Plan, err error) {
	if a.pluginInstall.generation != generation {
		if a.plugins != nil && plan.Staging != "" {
			_ = a.plugins.Installer.Discard(plan)
		}
		return
	}
	a.pluginInstall.busy = false
	if err != nil {
		a.notify(i18n.Shared(a.language(), "desktop.marketplace.installFailed"))
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_install", err))
		return
	}
	a.pluginInstall.plan = plan
	a.pluginInstall.open = true
}

// confirmPluginInstall installs the reviewed package and records the approval.
func (a *App) confirmPluginInstall() {
	plan := a.pluginInstall.plan
	a.pluginInstall.open = false
	a.pluginInstall.plan = plugininstall.Plan{}
	if a.plugins == nil || plan.Staging == "" {
		return
	}
	a.background(nil, pluginInstallTimeout, func(context.Context) func(*App) {
		_, err := a.plugins.Installer.Commit(plan)
		return func(a *App) {
			if err != nil {
				var approval *plugininstall.ApprovalError
				if errors.As(err, &approval) {
					// The package is on disk; only its approval record failed, so the
					// user is not told the installation failed. The next installation
					// of the same version asks again.
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_approval", err))
				} else {
					a.notify(i18n.Shared(a.language(), "desktop.marketplace.installFailed"))
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_commit", err))
					// A refused install leaves the extracted package behind; Discard
					// is a no-op once the rename consumed it.
					_ = a.plugins.Installer.Discard(plan)
				}
			}
			a.refreshPluginState()
			a.reloadPluginLanguages()
		}
	})
}

// cancelPluginInstall drops a prepared package the user declined.
func (a *App) cancelPluginInstall() {
	a.pluginInstall.open = false
	a.pluginInstall.generation++
	a.discardPluginInstall()
}

// discardPluginInstall drops the prepared package that will not be installed.
func (a *App) discardPluginInstall() {
	plan := a.pluginInstall.plan
	a.pluginInstall.plan = plugininstall.Plan{}
	if a.plugins != nil && plan.Staging != "" {
		_ = a.plugins.Installer.Discard(plan)
	}
}

// setPluginEnabled turns an installed plugin on or off.
func (a *App) setPluginEnabled(id string, enabled bool) {
	if a.plugins == nil {
		return
	}
	a.background(nil, pluginStateTimeout, func(context.Context) func(*App) {
		err := a.plugins.Manager.SetEnabled(id, enabled)
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_enable", err))
			}
			a.refreshPluginState()
			a.reloadPluginLanguages()
		}
	})
}

// uninstallPlugin removes every installed version of a plugin.
func (a *App) uninstallPlugin(id string) {
	if a.plugins == nil {
		return
	}
	states := a.pluginState.Load()
	if states == nil {
		return
	}
	if state := (*states)[id]; !state.Installed {
		return
	}
	a.background(nil, pluginInstallTimeout, func(context.Context) func(*App) {
		err := a.plugins.Manager.Uninstall(id)
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_uninstall", err))
			}
			a.refreshPluginState()
			a.reloadPluginLanguages()
		}
	})
}

// reloadPluginLanguages registers the languages of the enabled plugins.
//
// The registry replaces its plugin languages whole, so a plugin that was disabled
// or removed loses its highlighting in the same pass that registers a new one.
func (a *App) reloadPluginLanguages() {
	if a.plugins == nil {
		return
	}
	a.background(nil, pluginStateTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			return func(a *App) {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_languages", err))
			}
		}
		languages, loadErr := a.plugins.LoadLanguages(ctx, entries)
		return func(a *App) {
			if loadErr != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_languages", loadErr))
			}
			failed, _ := a.syntaxRegistry().SetPluginLanguages(languages)
			if len(failed) > 0 {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_languages",
					fmt.Errorf("%d plugin languages were rejected", len(failed))))
			}
		}
	})
}

// drawPluginReview declares the sheet that shows what a package asks for before it
// is installed.
func (a *App) drawPluginReview(f *ui.Frame) {
	if !a.pluginInstall.open {
		return
	}
	language := a.language()
	plan := a.pluginInstall.plan
	background := gfx.RGB24(0xF7F8FA)
	if a.colors.Dark {
		background = gfx.RGB24(0x242529)
	}
	confirmed, cancelled := false, false
	dismissed := sheet.Draw(f, sheet.Options{Width: 620, Height: 480, Background: background,
		Scope: pluginReviewScope, Dismiss: pluginReviewDismiss, InitialFocus: pluginReviewInstall,
		DismissLabel: i18n.Shared(language, "desktop.marketplace.cancel")}, func() {
		f.Column().Fill().Pad(24).Gap(12).Children(func() {
			f.Text(i18n.Shared(language, "desktop.marketplace.reviewTitle")).FontSize(18).Weight(gfx.WeightBold).Color(a.colors.Text)
			f.Text(a.pluginInstall.plugin.Name + " · " + plan.Version).FontSize(12).Color(a.colors.Subtle).Ellipsis()
			if plan.Decision.Reuse {
				f.Wrap(i18n.Shared(language, "desktop.marketplace.reviewReused")).FontSize(12).Color(a.colors.Subtle)
			}
			f.Text(i18n.Shared(language, "desktop.marketplace.reviewPermissions")).FontSize(13).Weight(gfx.WeightSemibold).Color(a.colors.Text)
			if len(plan.Review.Permissions) == 0 && len(plan.Review.Programs) == 0 {
				f.Wrap(i18n.Shared(language, "desktop.marketplace.reviewEmpty")).FontSize(12).Color(a.colors.Subtle)
			}
			for _, permission := range plan.Review.Permissions {
				f.Text(permission).FontSize(12).Color(a.colors.Text).Ellipsis()
			}
			if len(plan.Review.Programs) > 0 {
				f.Text(i18n.Shared(language, "desktop.marketplace.reviewPrograms")).FontSize(13).Weight(gfx.WeightSemibold).Color(a.colors.Text)
				for _, program := range plan.Review.Programs {
					f.Wrap(compactProgram(program)).FontSize(11).Mono().Color(a.colors.Subtle)
				}
			}
			f.Spacer()
			f.Row().FillWidth().Gap(8).Items(ui.Center).Children(func() {
				f.Spacer()
				if f.Button(pluginReviewCancel, i18n.Shared(language, "desktop.marketplace.cancel")).Outline().Clicked() {
					cancelled = true
				}
				if f.Button(pluginReviewInstall, i18n.Shared(language, "desktop.marketplace.confirmInstall")).Clicked() {
					confirmed = true
				}
			})
		})
	})
	if confirmed {
		a.confirmPluginInstall()
		return
	}
	if cancelled || dismissed {
		a.cancelPluginInstall()
	}
}

// compactProgram renders one program declaration on a single line. The contract
// hands programs over as opaque JSON, so the review shows exactly what was
// declared rather than a summary this client would have to interpret.
func compactProgram(program json.RawMessage) string {
	var buffer bytes.Buffer
	if err := json.Compact(&buffer, program); err != nil {
		return string(program)
	}
	return buffer.String()
}
