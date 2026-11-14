package workbench

import (
	"context"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"maps"
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
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
		GitHub:             a.githubSettings(),
		SettingsError:      func(operation string, err error) { (settingsToolchains{app: a}).recordFailure(operation, err) },
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
			return service.Fetch(ctx, marketplace.CommunityRepositoryURL, core.MarketplaceThirdParty, runtime.GOOS+"-"+arch, pluginhost.Declared().Clone())
		},
		MarketplaceURL:         marketplace.CommunityRepositoryURL,
		OfficialMarketplaceURL: marketplace.OfficialIndexURL,
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
		InstalledPlugins: func() []settingswindow.PluginFacts {
			if facts := a.pluginFacts.Load(); facts != nil {
				return *facts
			}
			return nil
		},
		LanguageServerState: func(pluginID string) string {
			for _, server := range a.lspServers() {
				if server.session.PluginID == pluginID {
					return server.sharedStateName()
				}
			}
			return ""
		},
		MarketplaceSources: append([]string(nil), a.settings.MarketplaceSources...),
		FetchMarketplaceSource: func(ctx context.Context, url string) (marketplace.Snapshot, error) {
			arch := runtime.GOARCH
			if arch == "amd64" {
				arch = "x64"
			}
			return service.Fetch(ctx, url, core.MarketplaceThirdParty, runtime.GOOS+"-"+arch, pluginhost.Declared().Clone())
		},
		SetMarketplaceSources: func(urls []string) {
			a.post(func(a *App) { a.setMarketplaceSources(urls) })
		},
		InstallPluginFromFile: func(path string) {
			a.post(func(a *App) { a.installPluginFromFile(path) })
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
		Stable:         buildinfo.Stable,
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
		SetTabLimit: func(limit int, policy string) {
			a.post(func(a *App) {
				a.settings.EditorTabLimit = &limit
				if limit == settingswindow.DefaultTabLimit {
					a.settings.EditorTabLimit = nil
				}
				a.settings.EditorTabPolicy = policy
				a.saveSettings()
				if p := a.project; p != nil {
					a.enforceTabLimit(p, p.selectedDocument(p.docs.group))
				}
			})
		},
		SetHideGitGutter: func(value bool) {
			a.post(func(a *App) { a.setHideGitGutter(value) })
		},
		SetInlineGitBlame: func(value bool) {
			a.post(func(a *App) { a.setInlineGitBlame(value) })
		},
		SetHideChangeLists: func(value bool) {
			a.post(func(a *App) { a.setHideChangeLists(value) })
		},
		SetHideParentReferences: func(value bool) {
			a.post(func(a *App) { a.setHideParentReferences(value) })
		},
		SetDisableSemanticHighlight: func(value bool) {
			a.post(func(a *App) { a.setDisableSemanticHighlight(value) })
		},
		SetVimMode: func(value bool) {
			a.post(func(a *App) { a.setVimMode(value) })
		},
		SetDisableAutoSave: func(value bool) {
			a.post(func(a *App) {
				if a.settings.DisableAutoSave != value {
					a.settings.DisableAutoSave = value
					a.saveSettings()
				}
			})
		},
		SetProcessTermination: func(value settingswindow.ProcessTermination) {
			a.post(func(a *App) { a.setProcessTermination(value) })
		},
		StopTime:                 a.stopTimeOption(),
		SweepsLeftovers:          processledger.Supported,
		SteppingAdapters:         a.steppingAdapters,
		NormalizeSteppingFilters: a.kernel.NormalizeSteppingFilters,
		SetSteppingFilters: func(adapter string, filters *core.DebugSteppingFilters) {
			a.post(func(a *App) { a.setSteppingFilters(adapter, filters) })
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
		SetTerminalScrollback: func(lines int) {
			a.post(func(a *App) { a.setTerminalScrollback(lines) })
		},
		ResetLayout: func() {
			a.post(func(a *App) { a.resetLayout() })
		},
		SetHideProjectColors: func(hide bool) {
			a.post(func(a *App) {
				if a.settings.HideProjectColors != hide {
					a.settings.HideProjectColors = hide
					a.saveSettings()
				}
			})
		},
		// The image is the window's and its snapshot is read under its lock, so the settings
		// window reads it from its own thread; the changes run on the workbench's.
		WorkbenchBackground:       a.backgroundSnapshot,
		ChooseWorkbenchBackground: func() { a.post(func(a *App) { a.chooseBackground() }) },
		RemoveWorkbenchBackground: func() { a.post(func(a *App) { a.removeBackground() }) },
		SetWorkbenchBackgroundStrength: func(value string) {
			a.post(func(a *App) { a.setBackgroundStrength(backgroundStrengthFromString(value)) })
		},
		SetProjectOpenDestination: func(destination string) {
			a.post(func(a *App) {
				if a.settings.ProjectOpenDestination != destination {
					a.settings.ProjectOpenDestination = destination
					a.saveSettings()
				}
			})
		},
		UpdateStatus:        a.updateStatus,
		CheckForUpdates:     func() { a.post(func(a *App) { a.checkForUpdates(true) }) },
		UpdateNow:           func() { a.post(func(a *App) { a.updateNow() }) },
		CancelUpdate:        func() { a.post(func(a *App) { a.cancelUpdate() }) },
		SetAutoCheckUpdates: func(on bool) { a.post(func(a *App) { a.setAutoCheckUpdates(on) }) },
		OpenURL:             func(address string) { a.post(func(a *App) { a.openSettingsLink(address) }) },
		SetNetwork: func(next settingswindow.NetworkSettings, password *string) {
			a.post(func(a *App) { a.setNetwork(next, password) })
		},
		CheckNetwork: a.networkChecker(),
		SetLocalHistory: func(next settingswindow.LocalHistorySettings) {
			a.post(func(a *App) {
				a.settings.LocalHistory = next
				a.saveSettings()
			})
		},
		LocalHistory: a.localHistorySettingsSource(),
		SetEditorPreferences: func(stored core.EditorStoredPreferences, resolved core.EditorPreferences) {
			a.post(func(a *App) {
				a.settings.EditorPreferences = stored
				a.editorPreferences = resolved
				a.saveSettings()
				a.invalidator.Invalidate()
			})
		},
		SetKeymapSchemes: func(value core.KeymapSchemeResult) {
			a.post(func(a *App) {
				a.settings.KeymapSchemes = value.State
				a.settings.Keymap = shortcuts.Overrides(value.Bindings)
				a.saveSettings()
				a.invalidator.Invalidate()
			})
		},
		SetKeymap: func(value shortcuts.Overrides) {
			value = shortcuts.Normalize(value)
			a.post(func(a *App) {
				a.settings.Keymap = value
				a.saveSettings()
				a.invalidator.Invalidate()
			})
		},
		Toolchains:     settingsToolchains{app: a},
		PluginSettings: pluginSettingsSources{app: a},
		AIGeneration:   a.aiGenerationSettings,
		SetAIGeneration: func(value settingswindow.AIGenerationSettings) {
			a.post(func(a *App) { a.setAIGenerationSettings(value) })
		},
		AIProviders: a.aiProviderStatuses,
		IDEAPI:      a.ideAPISettingsLoader(),
	})
}

// setMarketplaceSources stores the custom index URLs and saves the settings.
func (a *App) setMarketplaceSources(urls []string) {
	a.settings.MarketplaceSources = append([]string(nil), urls...)
	a.saveSettings()
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

// openPluginSettingsSearch shows the plugin page with the marketplace search set to query.
func (a *App) openPluginSettingsSearch(surface, query string) {
	a.openSettingsPageWith(surface, settingsPlugins, query)
}

// openTerminalSettings shows the settings window on its Terminal page, where the shell new
// terminals run is picked.
func (a *App) openTerminalSettings(surface string) {
	a.openSettingsPage(surface, settingsTerminal)
}

// openKeymapSettings shows the settings window on its Keymap page.
func (a *App) openKeymapSettings(surface string) {
	a.openSettingsPage(surface, settingsKeymap)
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
	// settingsKeymap is the Keymap page, which the gear menu's Keymap item opens.
	settingsKeymap
)

func (a *App) openSettingsPage(surface string, page settingsPage) {
	a.openSettingsPageWith(surface, page, "")
}

// openSettingsPageWith is openSettingsPage with the marketplace search text the plugin page starts with.
func (a *App) openSettingsPageWith(surface string, page settingsPage, query string) {
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
			EditorTabLimit: settingswindow.TabLimitOf(a.settings.EditorTabLimit), EditorTabPolicy: a.settings.EditorTabPolicy,
			TerminalShell: a.settings.TerminalShell, TerminalScrollback: a.terminalScrollback(),
			HideProjectColors: a.settings.HideProjectColors, ProjectOpenDestination: a.settings.ProjectOpenDestination,
			HideGitGutter: a.settings.HideGitGutter, InlineGitBlame: a.settings.InlineGitBlame,
			HideChangeLists: a.settings.HideChangeLists, HideParentReferences: a.settings.HideParentReferences,
			DisableSemanticHighlight: a.settings.DisableSemanticHighlight,
			VimMode:                  a.settings.VimMode,
			DisableAutoSave:          a.settings.DisableAutoSave,
			ProcessTermination:       a.settings.ProcessTermination,
			SteppingFilters:          maps.Clone(a.settings.DebugSteppingFilters),
			Fonts:                    fontprefs.Normalize(a.settings.Fonts),
			Keymap:                   maps.Clone(a.settings.Keymap),
			EditorPreferences:        a.editorPreferences, EditorStoredPreferences: a.settings.EditorPreferences, KeymapSchemes: a.settings.KeymapSchemes,
			Network:          a.settings.Network,
			LocalHistory:     a.settings.LocalHistory,
			AutoCheckUpdates: a.autoCheckUpdates(),
		}
		var err error
		switch page {
		case settingsPlugins:
			if query != "" {
				err = a.settingsWindow.OpenPluginsWithQuery(a.application, current, query)
			} else {
				err = a.settingsWindow.OpenPlugins(a.application, current)
			}
		case settingsTerminal:
			err = a.settingsWindow.OpenTerminal(a.application, current)
		case settingsKeymap:
			err = a.settingsWindow.OpenKeymap(a.application, current)
		case settingsAI:
			err = a.settingsWindow.OpenAI(a.application, current)
		default:
			err = a.settingsWindow.Open(a.application, current)
		}
		if err != nil {
			a.notifyError(a.text.Errors.SettingsFailed(err.Error()))
		}
	})
}

// openSettingsLink opens a link of the settings window, such as the About page's, in the
// browser. When the system cannot, the window says so and the log records why.
func (a *App) openSettingsLink(address string) {
	if err := openURL(address); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("settings_open_link", err))
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.terminal.openLinkFailed", map[string]string{"reason": err.Error()}))
		return
	}
	a.performed("settings.openLink", surfaceButton)
}
