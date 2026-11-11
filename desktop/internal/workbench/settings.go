package workbench

import (
	"context"
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/app"
)

// newSettingsWindow makes the controller of the settings window. The settings are a window
// of their own, like the log window, so the controller is handed what it may read from its
// own thread (the language and the look of the frame last painted) and two ways back into
// the workbench, both of which only queue the work for the workbench's window thread.
func (a *App) newSettingsWindow() *settingswindow.Controller {
	service := marketplace.New(a.kernel, nil)
	var navigation func(context.Context, []core.SettingsNavigationItem, string) ([]core.SettingsNavigationRow, error)
	if kernel, ok := a.kernel.(interface {
		SettingsNavigation(context.Context, []core.SettingsNavigationItem, string) ([]core.SettingsNavigationRow, error)
	}); ok {
		navigation = kernel.SettingsNavigation
	}
	return settingswindow.NewController(settingswindow.Options{
		SettingsError:      func(err error) { (settingsToolchains{app: a}).recordFailure("plugin_settings_surface", err) },
		SettingsNavigation: navigation,
		SettingsPages: func(ctx context.Context) ([]core.SettingsPage, error) {
			if a.plugins == nil {
				return nil, nil
			}
			return a.plugins.SettingsPages(ctx)
		},
		MarketplaceRank: a.kernel.RankNames,
		PluginRuntime:   a.pluginSettingsRuntime,
		RestartPlugin: func(id, version, scope, workspace string) {
			a.post(func(a *App) { a.restartSettingsPlugin(id, version, scope, workspace) })
		},
		MarketplaceInstalled: func(ctx context.Context) (marketplace.Snapshot, error) {
			plugins, err := a.plugins.SettingsCatalog(ctx)
			if err != nil {
				if plugins == nil {
					return marketplace.Snapshot{}, err
				}
				a.post(func(a *App) {
					fields := logwindow.ErrorFields(err)
					fields["operation"] = "plugin_settings_catalog"
					a.emit(core.LevelError, "app.notification.operation_failed", fields)
				})
			}
			return marketplace.Snapshot{Index: core.MarketplaceIndex{Plugins: plugins}}, nil
		},
		Marketplace: func(ctx context.Context) (marketplace.Snapshot, error) {
			arch := runtime.GOARCH
			if arch == "amd64" {
				arch = "x64"
			}
			return service.Fetch(ctx, "https://github.com/Lithe-IDEA/Lithe-store", core.MarketplaceThirdParty, runtime.GOOS+"-"+arch, pluginhost.Declared().Clone())
		},
		MarketplaceOfficial: func(ctx context.Context) (marketplace.Snapshot, error) {
			arch := runtime.GOARCH
			if arch == "amd64" {
				arch = "x64"
			}
			return service.Fetch(ctx, marketplace.OfficialIndexURL, core.MarketplaceOfficial, runtime.GOOS+"-"+arch, pluginhost.Declared().Clone())
		},
		MarketplaceError: func(err error) {
			a.post(func(a *App) {
				fields := logwindow.ErrorFields(err)
				fields["operation"] = "plugin_marketplace"
				a.emit(core.LevelError, "app.notification.operation_failed", fields)
			})
		},
		MarketplaceRejected: func(_ int) {
			a.post(func(a *App) {
				a.emit(core.LevelWarn, "app.notification.operation_rejected", map[string]any{
					"operation": "plugin_marketplace", "reason": "invalid_index_entries",
				})
			})
		},
		MarketplaceResized: func(width float32) {
			a.post(func(a *App) { a.setMarketplaceWidth(width) })
		},
		// The plugin page paints from memory and hands every action back, so the
		// window never installs, enables or removes anything on its own thread.
		PluginState: func(id string) settingswindow.PluginState {
			states := a.pluginState.Load()
			if states == nil {
				return settingswindow.PluginState{}
			}
			return (*states)[id]
		},
		InstallPlugin: func(plugin core.MarketplacePlugin) {
			a.post(func(a *App) { a.installPlugin(plugin) })
		},
		SetPluginEnabled: func(id string, enabled bool) {
			a.post(func(a *App) { a.setPluginEnabled(id, enabled) })
		},
		UninstallPlugin: func(id string) {
			a.post(func(a *App) { a.uninstallPlugin(id) })
		},
		Language: func() i18n.Language {
			if a.shared.text.Load() == i18n.For(i18n.Chinese) {
				return i18n.Chinese
			}
			return i18n.English
		},
		Text: a.shared.text.Load,
		Dark: a.shared.dark.Load,
		// The look "follow the system" resolves to is the system's own, which Dark cannot
		// tell once the user has picked a look: then it reports that pick.
		SystemDark:     func() bool { return app.SystemAppearance() == app.AppearanceDark },
		SystemLanguage: a.systemLanguage,
		Version:        a.version,
		SetLanguage: func(language string) {
			a.post(func(a *App) { a.setLanguage(language) })
		},
		SetTheme: func(theme string) {
			a.post(func(a *App) { a.setTheme(themeChoice(theme)) })
		},
		SetTabRows: func(value string) {
			a.post(func(a *App) { a.setTabRows(value) })
		},
		SetTabOverflow: func(value string) {
			a.post(func(a *App) { a.setTabOverflow(value) })
		},
		SetHideGitGutter: func(value bool) {
			a.post(func(a *App) { a.setHideGitGutter(value) })
		},
		SetInlineGitBlame: func(value bool) {
			a.post(func(a *App) { a.setInlineGitBlame(value) })
		},
		SetDisableSemanticHighlight: func(value bool) {
			a.post(func(a *App) { a.setDisableSemanticHighlight(value) })
		},
		SetProcessTermination: func(value settingswindow.ProcessTermination) {
			a.post(func(a *App) { a.setProcessTermination(value) })
		},
		SetFonts: func(fonts []fontprefs.Font) {
			a.post(func(a *App) { a.setFonts(fonts) })
		},
		// The Fonts page lists the installed fixed-pitch families; reading them is slow, so
		// the page asks for them off its window thread.
		MonospaceFamilies: app.MonospaceFamilies,
		// The Terminal page lists the shells the new-terminal menu offers, found the same
		// way, and names the login shell a terminal runs while the setting is automatic.
		TerminalShells: func() ([]localshell.Choice, string) {
			return a.listShells(), localshell.DefaultShell()
		},
		SetTerminalShell: func(value string) {
			a.post(func(a *App) { a.setTerminalShell(value) })
		},
		ResetLayout: func() {
			a.post(func(a *App) { a.resetLayout() })
		},
		Toolchains:     settingsToolchains{app: a},
		PluginSettings: pluginSettingsSources{app: a},
		// The AI pages read and edit the Agents' own configuration through Core.
		AgentSettings:      a.agentSettingsBackend(),
		AgentDataDirectory: a.store.Dir,
		AgentWorkspace: func() string {
			if root := a.toolchainRoot.Load(); root != nil {
				return *root
			}
			return ""
		},
		AgentContextLimits: func(id string) settingswindow.AgentContextLimit {
			l := a.agentContextLimitsFor(id)
			return settingswindow.AgentContextLimit{WindowTokens: l.WindowTokens, AutoCompactTokens: l.AutoCompactTokens}
		},
		SetAgentContextLimits: func(id string, l settingswindow.AgentContextLimit) {
			a.post(func(a *App) {
				a.setAgentContextLimits(id, agentContextLimit{WindowTokens: l.WindowTokens, AutoCompactTokens: l.AutoCompactTokens})
			})
		},
		AIGeneration: a.aiGenerationSettings,
		SetAIGeneration: func(value settingswindow.AIGenerationSettings) {
			a.post(func(a *App) { a.setAIGenerationSettings(value) })
		},
		AIProviders: a.aiProviderStatuses,
		MCP:         a.mcpSettingsLoader(),
		IDEAPI:      a.ideAPISettingsLoader(),
	})
}

func (a *App) setMarketplaceWidth(width float32) {
	if a.settings.MarketplaceWidth != width {
		a.settings.MarketplaceWidth = width
		a.saveSettings()
	}
}

// invalidateSettingsWindow repaints the open settings window after state one of its pages
// reads changed off that window's thread.
func (a *App) invalidateSettingsWindow() {
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
}

// openSettings shows the settings window, or raises it when it is already open. surface is
// where the user started the action from, written as the catalog's token.
//
// The window is opened from a queued task because the toolkit only opens a window from a
// window thread, which the task runs on. The settings in force are read there, at the
// moment the window opens, so a window that has to be made starts from the latest ones.
func (a *App) openSettings(surface string) {
	a.openSettingsPage(surface, settingsHome)
}

// openPluginSettings shows the settings window on its plugin page.
func (a *App) openPluginSettings(surface string) {
	a.openSettingsPage(surface, settingsPlugins)
}

// openTerminalSettings shows the settings window on its Terminal page, where the shell new
// terminals run is picked.
func (a *App) openTerminalSettings(surface string) {
	a.openSettingsPage(surface, settingsTerminal)
}

// settingsPage is the page of the settings window an action opens it on.
type settingsPage uint8

const (
	// settingsHome opens the window where it was left, or on its first page.
	settingsHome settingsPage = iota
	settingsPlugins
	settingsTerminal
	// settingsAI is the AI page, where the providers a commit message is generated with are
	// configured.
	settingsAI
)

func (a *App) openSettingsPage(surface string, page settingsPage) {
	a.performed("settings.open", surface)
	// Users can enter Plugins from any settings page. Publish native installed
	// state when the window opens, including its general-settings entry point.
	a.refreshPluginState()
	if a.application == nil {
		return
	}
	if page == settingsPlugins {
		a.reloadPluginLanguages()
	}
	a.post(func(a *App) {
		if a.application == nil {
			return
		}
		current := settingswindow.Values{
			Language: a.settings.Language, Theme: string(a.settings.Theme), MarketplaceWidth: a.settings.MarketplaceWidth,
			EditorTabRows: a.settings.EditorTabRows, EditorTabOverflow: a.settings.EditorTabOverflow,
			TerminalShell: a.settings.TerminalShell,
			HideGitGutter: a.settings.HideGitGutter, InlineGitBlame: a.settings.InlineGitBlame,
			DisableSemanticHighlight: a.settings.DisableSemanticHighlight,
			ProcessTermination:       a.settings.ProcessTermination,
			Fonts:                    fontprefs.Normalize(a.settings.Fonts),
		}
		var err error
		switch page {
		case settingsPlugins:
			err = a.settingsWindow.OpenPlugins(a.application, current)
		case settingsTerminal:
			err = a.settingsWindow.OpenTerminal(a.application, current)
		case settingsAI:
			err = a.settingsWindow.OpenAI(a.application, current)
		default:
			err = a.settingsWindow.Open(a.application, current)
		}
		if err != nil {
			a.notify(a.text.Errors.SettingsFailed(err.Error()))
		}
	})
}
