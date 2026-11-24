package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

const (
	// pluginPrepareTimeout bounds checking and unpacking one downloaded package.
	// Downloading it has no time limit: the download ends when nothing arrives for
	// a minute, or when the review window is closed.
	pluginPrepareTimeout = 5 * time.Minute
	// pluginInstallTimeout bounds the context-aware work after confirmation and during removal.
	pluginInstallTimeout = 2 * time.Minute
	// pluginStateTimeout bounds a listing of the installed packages.
	pluginStateTimeout = 30 * time.Second
)

// refreshPluginState reloads what the marketplace page shows about installed
// plugins. It is called when the page opens and after every change, and it answers
// from memory while painting.
func (a *App) refreshPluginState() {
	if a.plugins == nil {
		return
	}
	a.background(nil, pluginStateTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.CurrentInstalled(ctx)
		facts := installedPluginFacts(entries, a.plugins.Manager)
		return func(a *App) {
			a.pluginFacts.Store(&facts)
			if err != nil {
				a.backgroundFailed("plugin_list", err)
				if entries == nil {
					return
				}
			}
			states := make(map[string]settingswindow.PluginState, len(entries))
			for _, entry := range entries {
				states[entry.Installed.ID] = settingswindow.PluginState{
					Installed: true,
					Version:   entry.Installed.Version,
					Enabled:   entry.Enabled,
				}
			}
			previous := a.pluginState.Load()
			changed := previous == nil || !maps.Equal(*previous, states)
			if changed {
				// An open New Project window lists the generators again, and the open project
				// reads the debug adapters the changed plugins declare.
				a.newProject.revision++
				a.invalidateDebugAdapters(a.project)
			}
			a.pluginState.Store(&states)
			if changed && a.settingsWindow != nil {
				a.settingsWindow.PluginRegistryChanged()
			}
		}
	})
}

// installPlugin queues download, preparation and review for the settings window.
func (a *App) installPlugin(plugin core.MarketplacePlugin, feedback settingswindow.PluginInstallFeedback) {
	availability := plugin.Availability
	if a.pluginDownloads == nil {
		a.pluginDownloads = marketplace.NewArchiveSession(nil)
	}
	downloads := a.pluginDownloads
	a.performed("plugin.install.marketplace", surfaceButton)
	a.preparePluginInstall(feedback, func(ctx context.Context) (plugininstall.Plan, error) {
		downloader := marketplace.NewArchiveDownloader(nil)
		var previous plugintrust.Record
		if plugin.MarketplaceDeltasURL != "" {
			var err error
			previous, err = a.installedMarketplaceApproval(ctx, plugin.ID)
			if err != nil && ctx.Err() == nil {
				a.backgroundFailedIn(ctx, "plugin_delta_base", err)
			}
		}
		archive, err := a.downloadMarketplacePlugin(ctx, downloader, plugin, previous, func() (*marketplace.DownloadedArchive, error) {
			return downloads.Download(ctx, availability, feedback.Progress)
		}, feedback.Progress)
		if err != nil {
			return plugininstall.Plan{}, err
		}
		defer func() {
			a.recordPluginInstallCleanup(ctx, archive.Discard())
		}()
		if feedback.Preparing != nil {
			feedback.Preparing()
		}
		plan, err := a.preparePlugin(ctx, plugininstall.Request{
			ArchivePath:         archive.Path(),
			Root:                a.plugins.Root,
			Source:              plugintrust.Marketplace,
			ArchiveSHA256:       availability.SHA256,
			MarketplaceIndexURL: plugin.MarketplaceIndexURL,
			ExpectedID:          plugin.ID,
			ExpectedVersion:     availability.Version,
		})
		if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
			a.recordPluginInstallCleanup(ctx, downloads.Forget(archive))
		}
		return plan, err
	})
}

func (a *App) closePluginDownloads() {
	downloads := a.pluginDownloads
	a.pluginDownloads = nil
	if downloads != nil {
		a.background(nil, 0, func(ctx context.Context) func(*App) {
			a.recordPluginInstallCleanup(ctx, downloads.Close())
			return nil
		})
	}
}

// installPluginFromFile submits a local package to the same review.
func (a *App) installPluginFromFile(path string, feedback settingswindow.PluginInstallFeedback) {
	a.performed("plugin.install.disk", surfaceButton)
	a.preparePluginInstall(feedback, func(ctx context.Context) (plugininstall.Plan, error) {
		return a.preparePlugin(ctx, plugininstall.Request{
			ArchivePath: path,
			Root:        a.plugins.Root,
			Source:      plugintrust.Disk,
		})
	})
}

func (a *App) preparePluginInstall(feedback settingswindow.PluginInstallFeedback, prepare func(context.Context) (plugininstall.Plan, error)) {
	if a.plugins == nil {
		a.operationFailed("plugin_install", errors.New("plugin service unavailable"))
		if feedback.Failure != nil {
			feedback.Failure(errors.New("plugin service unavailable"))
		}
		feedback.Finish(true)
		return
	}
	// Register the worker on the workbench thread so application shutdown waits
	// for cancelled downloads and unapproved packages to be cleaned up.
	a.background(nil, 0, func(work context.Context) func(*App) {
		// The review window's context ends the install; the install still belongs to the
		// action that started it, so its records and Core requests carry its op.
		origin := core.OriginOf(work)
		plan, err := prepare(core.WithOrigin(feedback.Context, origin))
		if err != nil {
			// log-exempt: 用户取消：关闭审查窗口取消未完成的安装。
			cancelled := feedback.Context.Err() != nil
			if cancelled && errors.Is(err, context.Canceled) {
				return nil
			}
			a.operationFailedIn(work, "plugin_install", err)
			if !cancelled {
				if feedback.Failure != nil {
					feedback.Failure(err)
				}
				feedback.Finish(true)
			}
			return nil
		}
		// The worker holds staging until the originating window accepts the
		// verified package; a cancelled window discards it before installation.
		if !feedback.Review(plan.Version, plan.Review, plan.Decision.Reuse) {
			a.recordPluginInstallCleanup(work, a.plugins.Installer.Discard(plan))
			return nil
		}
		commitCtx, cancelCommit := context.WithTimeout(core.WithOrigin(context.Background(), origin), pluginInstallTimeout)
		defer cancelCommit()
		stop := context.AfterFunc(work, cancelCommit)
		defer stop()
		return a.commitPluginInstall(commitCtx, plan, feedback)
	})
}

// preparePlugin checks and unpacks a package for review, within pluginPrepareTimeout.
func (a *App) preparePlugin(ctx context.Context, request plugininstall.Request) (plugininstall.Plan, error) {
	ctx, cancel := context.WithTimeout(ctx, pluginPrepareTimeout)
	defer cancel()
	return a.plugins.Installer.Prepare(ctx, request)
}

// recordPluginInstallCleanup records a download or staging package the install could not
// remove, under the action ctx belongs to. It is safe from any goroutine.
func (a *App) recordPluginInstallCleanup(ctx context.Context, err error) {
	if err != nil {
		fields := core.LogErrorFields(err)
		fields["stage"] = "plugin_install_cleanup"
		a.emitIn(ctx, core.LevelWarn, "app.storage.maintenance_failed", fields)
	}
}

func (a *App) commitPluginInstall(ctx context.Context, plan plugininstall.Plan, feedback settingswindow.PluginInstallFeedback) func(*App) {
	work, finish, err := a.plugins.BeginRuntimeInstallation(ctx, plan.ID)
	if err == nil {
		defer func() { a.recordPluginInstallCleanup(work, finish()) }()
		ctx = work
		err = ctx.Err()
	}
	if err == nil {
		if feedback.Preparing != nil {
			feedback.Preparing()
		}
		_, err = a.plugins.Installer.Commit(plan)
	}
	var approval *plugininstall.ApprovalError
	var enableErr error
	var displaced displacement
	if err == nil || errors.As(err, &approval) {
		// Confirming the install is the user choosing to use the plugin, so it
		// works at once; a choice the user already made, such as disabling
		// the plugin before this update, is kept. An enabled plugin turns off
		// the plugins that served one of its languages.
		var outcome pluginmanager.Outcome
		outcome, enableErr = a.plugins.Manager.EnableInstalled(plan.ID)
		displaced = a.describeDisplacement(ctx, plan.ID, outcome.Displaced)
	}
	if err != nil && approval == nil {
		a.recordPluginInstallCleanup(ctx, a.plugins.Installer.Discard(plan))
	}
	return func(a *App) {
		installed := err == nil
		if enableErr != nil {
			a.operationFailed("plugin_enable", enableErr)
		}
		if err != nil {
			if approval != nil {
				installed = true
				// The package is on disk; only its approval record failed, so the
				// user is not told the installation failed. The next installation
				// of the same version asks again.
				a.operationFailed("plugin_approval", err)
			} else if !errors.Is(err, context.Canceled) {
				a.operationFailed("plugin_commit", err)
			}
			// log-exempt: the user may cancel runtime preparation before publication.
		}
		if installed && plan.ID != "" {
			// The installation was just enabled, unless the user had disabled the
			// plugin, so a disable tombstone from a previous version must not
			// block its server.
			a.allowPluginPrograms(plan.ID)
		}
		a.stopDisplaced(displaced)
		a.applyPluginLifecycleChange(installed)
		if !installed && feedback.Failure != nil {
			feedback.Failure(err)
		}
		feedback.Finish(!installed)
	}
}

// applyPluginLifecycleChange updates plugin state across every tab and, when reload is
// true, reloads languages and refreshes build and language services in open projects.
func (a *App) applyPluginLifecycleChange(reload bool) {
	for _, tab := range a.everyTab() {
		if reload {
			tab.invalidateBuild(tab.project)
			tab.reloadPluginLanguages()
		}
		tab.refreshPluginState()
	}
	if reload {
		for _, tab := range a.openTabs() {
			if p := tab.project; p != nil {
				tab.loadBuildSystems(p)
				// Opening a file normally requests its server. A plugin installed
				// later must also get the files that were already open.
				languages := make(map[string]bool)
				for _, d := range p.docs.list {
					if !d.virtual && !d.scratch && d.languageID != "" && !languages[d.languageID] {
						languages[d.languageID] = true
						tab.requestPluginServer(d.languageID, true)
					}
				}
			}
		}
	}
}

// recordPluginRuntimeIssue records automatic repair and cleanup at the native I/O boundary.
func (a *App) recordPluginRuntimeIssue(ctx context.Context, err error) {
	fields := core.LogErrorFields(err)
	fields["stage"] = "plugin_runtime_repair"
	a.emitIn(ctx, core.LevelWarn, "app.storage.maintenance_failed", fields)
}

// setPluginEnabled turns an installed plugin on or off.
func (a *App) setPluginEnabled(id string, enabled bool) {
	if a.plugins == nil {
		return
	}
	var server *pluginservice.LanguageSession
	var stop func(context.Context) error
	if !enabled {
		server, stop = a.detachPluginPrograms(id)
	}
	a.background(nil, pluginStateTimeout+pluginServerStopTimeout, func(ctx context.Context) func(*App) {
		var err error
		var displaced displacement
		if enabled {
			// Enabling a plugin turns off the plugins that served one of its
			// languages; their programs stop once the window has detached them.
			var list []pluginmanager.Displaced
			list, err = a.plugins.Manager.Enable(id)
			displaced = a.describeDisplacement(ctx, id, list)
		} else {
			err = a.plugins.Disable(ctx, id, server, stop)
		}
		return func(a *App) {
			if err != nil {
				a.operationFailed("plugin_enable", err)
			}
			if enabled {
				// An enable clears the tombstone a disable left for an in-flight start.
				a.allowPluginPrograms(id)
			}
			a.stopDisplaced(displaced)
			// Enabling and disabling both change the detected build systems across tabs.
			a.applyPluginLifecycleChange(err == nil)
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
	// Detach native owners on their window thread before asking Core to remove
	// anything. The stopPrograms step waits for every tab, including late starts.
	server, stop := a.detachPluginPrograms(id)
	a.background(nil, pluginInstallTimeout, func(ctx context.Context) func(*App) {
		err := a.plugins.Uninstall(ctx, id, server, stop)
		return func(a *App) {
			if err != nil {
				a.operationFailed("plugin_uninstall", err)
			}
			a.applyPluginLifecycleChange(err == nil)
		}
	})
}

// reloadPluginLanguages registers the languages and tool windows of the enabled plugins, and
// hands Core the folders they hide.
//
// The registry replaces its plugin languages whole, the catalog its plugin tool windows and
// Core its plugin-declared folders, so a plugin that was disabled or removed loses its
// highlighting, its windows and its hidden folders in the same pass that registers a new one.
func (a *App) reloadPluginLanguages() {
	if a.plugins == nil || a.plugins.Manager == nil {
		return
	}
	registry := a.syntaxRegistry()
	generation := a.pluginReloadGeneration.Add(1)
	if a.initialLanguageLoad.Load() == nil {
		a.initialLanguageLoad.CompareAndSwap(nil, &languageLoad{done: make(chan struct{})})
	}
	finishInitial := func() {
		if l := a.initialLanguageLoad.Load(); l != nil {
			l.finish()
		}
	}
	a.background(nil, pluginStateTimeout, func(ctx context.Context) func(*App) {
		if a.pluginReloadGeneration.Load() != generation {
			return nil
		}
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			if a.pluginReloadGeneration.Load() == generation {
				finishInitial()
			}
			return func(a *App) {
				if a.pluginReloadGeneration.Load() == generation {
					a.backgroundFailed("plugin_languages", err)
				}
			}
		}
		abortOnCancel := func(err error) (func(*App), bool) {
			cancelErr := ctx.Err()
			if cancelErr == nil {
				return nil, false
			}
			if !errors.Is(err, cancelErr) {
				err = errors.Join(err, cancelErr)
			}
			if a.pluginReloadGeneration.Load() == generation {
				finishInitial()
			}
			return func(a *App) {
				if a.pluginReloadGeneration.Load() != generation {
					return
				}
				// log-exempt: 用户取消：插件重读任务已取消。
				if !errors.Is(cancelErr, context.Canceled) {
					a.backgroundFailed("plugin_languages", err)
				}
			}, true
		}
		snapshot, snapshotErr := a.plugins.ReadInstalled(ctx, entries)
		if apply, cancelled := abortOnCancel(snapshotErr); cancelled {
			return apply
		}
		languages, loadErr := a.plugins.LoadLanguagesFromSnapshot(ctx, snapshot)
		loadErr = errors.Join(snapshotErr, loadErr)
		if apply, cancelled := abortOnCancel(loadErr); cancelled {
			return apply
		}
		failedCount := 0
		publishedEarly := false
		if initial := a.initialLanguageLoad.Load(); initial != nil && !initial.closed.Load() {
			a.pluginReloadMu.Lock()
			if a.pluginReloadGeneration.Load() != generation {
				a.pluginReloadMu.Unlock()
				return nil
			}
			if !initial.closed.Load() {
				// Publish the first language snapshot on the worker before allowing restored
				// documents to resolve. They need no tool window or visibility results.
				failed, _ := registry.SetPluginLanguages(languages)
				failedCount = len(failed)
				publishedEarly = true
				initial.finish()
			}
			a.pluginReloadMu.Unlock()
		}
		if a.pluginReloadGeneration.Load() != generation {
			return nil
		}
		windows, windowsErr := snapshot.ToolWindows()
		for _, window := range windows {
			if ctx.Err() != nil || a.pluginReloadGeneration.Load() != generation {
				return nil
			}
			if window.Icon.Path == "" {
				continue
			}
			if err := a.pluginIcons.Read(window.PluginID, window.Package, window.Icon); err != nil {
				a.backgroundFailedIn(ctx, "plugin_icon", fmt.Errorf("%s: %w", window.PluginID, err))
			}
		}
		commands, commandsErr := snapshot.ToolCommands()
		vcsPlugins, vcsErr := snapshot.VcsPlugins()
		a.pluginReloadMu.Lock()
		stale := a.pluginReloadGeneration.Load() != generation
		var hidden hiddenDirectories
		if !stale {
			hidden = a.configureVisibility(ctx, snapshot, vcsPlugins)
		}
		a.pluginReloadMu.Unlock()
		if stale {
			return nil
		}
		return func(a *App) {
			if a.pluginReloadGeneration.Load() != generation {
				return
			}
			a.applyHiddenDirectories(hidden)
			if p := a.project; p != nil && !p.everywhereSymbols.discovering {
				p.everywhereSymbols.discoveryStarted = false
				if a.everywhereView.open && everywhereShowsSymbols(p.everywhere.scope) {
					a.discoverEverywhereLanguages(p)
				}
			}
			if commandsErr != nil {
				a.backgroundFailed("plugin_tool_commands", commandsErr)
			}
			a.pluginCommands = commands
			shortcuts.SetPluginActions(pluginCommandActions(commands))
			if loadErr != nil {
				a.backgroundFailed("plugin_languages", loadErr)
			}
			if windowsErr != nil {
				a.backgroundFailed("plugin_tool_windows", windowsErr)
			}
			if vcsErr != nil {
				a.backgroundFailed("plugin_vcs_providers", vcsErr)
			}
			a.setPluginTools(windows, vcsWindows(vcsPlugins))
			if !publishedEarly {
				failed, _ := registry.SetPluginLanguages(languages)
				failedCount = len(failed)
				finishInitial()
			}
			if failedCount > 0 {
				a.backgroundFailed("plugin_languages", fmt.Errorf("%d plugin languages were rejected", failedCount))
			}
		}
	})
}

// pluginManifestFacts is the part of an installed manifest the Installed tab shows.
type pluginManifestFacts struct {
	DisplayName string   `json:"displayName"`
	Permissions []string `json:"permissions"`
	Vendor      struct {
		DisplayName string `json:"displayName"`
	} `json:"vendor"`
	Languages []struct {
		ID             string   `json:"id"`
		DisplayName    string   `json:"displayName"`
		FileExtensions []string `json:"fileExtensions"`
	} `json:"languages"`
	LanguageServers []struct {
		LanguageID string `json:"languageID"`
		Launch     struct {
			Kind     string   `json:"kind"`
			Commands []string `json:"commands"`
		} `json:"launch"`
	} `json:"languageServers"`
	ExecutionProviders []struct {
		LanguageID string          `json:"languageID"`
		Run        json.RawMessage `json:"run"`
		Test       json.RawMessage `json:"test"`
	} `json:"executionProviders"`
	BuildSystems []struct {
		ID          string            `json:"id"`
		DisplayName string            `json:"displayName"`
		Tasks       []json.RawMessage `json:"tasks"`
		Run         json.RawMessage   `json:"run"`
		Test        json.RawMessage   `json:"test"`
	} `json:"buildSystems"`
	DebugAdapters []struct {
		ID          string `json:"id"`
		DisplayName string `json:"displayName"`
	} `json:"debugAdapters"`
	ProjectGenerators []struct {
		ID          string `json:"id"`
		DisplayName string `json:"displayName"`
		Description string `json:"description"`
	} `json:"projectGenerators"`
	VcsProviders []struct {
		ID          string `json:"id"`
		DisplayName string `json:"displayName"`
	} `json:"vcsProviders"`
	UI struct {
		ToolWindows []struct {
			ID    string `json:"id"`
			Title string `json:"title"`
		} `json:"toolWindows"`
		Commands []struct {
			ID    string `json:"id"`
			Title string `json:"title"`
		} `json:"commands"`
	} `json:"ui"`
	Settings       []json.RawMessage `json:"settings"`
	SettingActions []json.RawMessage `json:"settingActions"`
}

// pluginApprovals looks up what the user approved for one installed version.
type pluginApprovals interface {
	Approval(id, version string) (plugintrust.Record, bool, error)
}

// installedPluginFacts reads what each installed package's manifest declares and what its
// approval recorded, in the order the Installed tab lists them: by name, then by ID. It reads
// files, so it runs off the window thread. A package whose manifest cannot be read still gets an
// entry with its ID, version and path, so the Installed tab lists every package on disk;
// approvals may be nil, which leaves every source unknown.
func installedPluginFacts(entries []pluginmanager.Entry, approvals pluginApprovals) []settingswindow.PluginFacts {
	facts := make([]settingswindow.PluginFacts, 0, len(entries))
	for _, entry := range entries {
		item := settingswindow.PluginFacts{
			ID:      entry.Installed.ID,
			Version: entry.Installed.Version,
			Path:    entry.Installed.Path,
		}
		if approvals != nil {
			if record, ok, err := approvals.Approval(entry.Installed.ID, entry.Installed.Version); err == nil && ok {
				item.Source = string(record.Source)
				item.ArchiveSHA256 = record.ArchiveSHA256
				item.ContentDigest = record.ContentDigest
				for _, program := range record.ApprovedPrograms {
					item.Programs = append(item.Programs, plugintrust.CompactProgram(program))
				}
			}
		}
		if data, err := os.ReadFile(filepath.Join(entry.Installed.Path, "plugin.json")); err == nil {
			var manifest pluginManifestFacts
			if json.Unmarshal(data, &manifest) == nil {
				describeManifest(&item, manifest)
			}
		}
		facts = append(facts, item)
	}
	slices.SortStableFunc(facts, func(left, right settingswindow.PluginFacts) int {
		if order := strings.Compare(strings.ToLower(pluginFactsName(left)), strings.ToLower(pluginFactsName(right))); order != 0 {
			return order
		}
		return strings.Compare(left.ID, right.ID)
	})
	return facts
}

// pluginFactsName is the name the Installed tab sorts by: the manifest's, or the ID when the
// manifest could not be read.
func pluginFactsName(facts settingswindow.PluginFacts) string {
	if facts.Name != "" {
		return facts.Name
	}
	return facts.ID
}

// describeManifest copies what the Installed tab shows out of a parsed manifest, listing the
// capabilities in the order the detail shows them.
func describeManifest(item *settingswindow.PluginFacts, manifest pluginManifestFacts) {
	item.Name = manifest.DisplayName
	item.Vendor = manifest.Vendor.DisplayName
	item.Permissions = manifest.Permissions
	item.Settings = len(manifest.Settings) + len(manifest.SettingActions)
	languageNames := make(map[string]string, len(manifest.Languages))
	for _, language := range manifest.Languages {
		languageNames[language.ID] = language.DisplayName
		item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
			Kind: settingswindow.CapabilityLanguage, ID: language.ID, Title: language.DisplayName,
			Extensions: language.FileExtensions,
		})
	}
	languageTitle := func(id string) string {
		if name := languageNames[id]; name != "" {
			return name
		}
		return id
	}
	for _, server := range manifest.LanguageServers {
		capability := settingswindow.PluginCapability{
			Kind: settingswindow.CapabilityLanguageServer, ID: server.LanguageID, Title: languageTitle(server.LanguageID),
		}
		if server.Launch.Kind == "systemCommand" {
			capability.Commands = server.Launch.Commands
		} else {
			capability.Packaged = true
		}
		item.Capabilities = append(item.Capabilities, capability)
	}
	for _, provider := range manifest.ExecutionProviders {
		if declared(provider.Run) {
			item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
				Kind: settingswindow.CapabilityRun, ID: provider.LanguageID, Title: languageTitle(provider.LanguageID),
			})
		}
		if declared(provider.Test) {
			item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
				Kind: settingswindow.CapabilityTest, ID: provider.LanguageID, Title: languageTitle(provider.LanguageID),
			})
		}
	}
	for _, system := range manifest.BuildSystems {
		item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
			Kind: settingswindow.CapabilityBuildSystem, ID: system.ID, Title: system.DisplayName, Tasks: len(system.Tasks),
		})
		if declared(system.Run) {
			item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
				Kind: settingswindow.CapabilityRun, ID: system.ID, Title: system.DisplayName,
			})
		}
		if declared(system.Test) {
			item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
				Kind: settingswindow.CapabilityTest, ID: system.ID, Title: system.DisplayName,
			})
		}
	}
	for _, adapter := range manifest.DebugAdapters {
		item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
			Kind: settingswindow.CapabilityDebugger, ID: adapter.ID, Title: adapter.DisplayName,
		})
	}
	for _, generator := range manifest.ProjectGenerators {
		item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
			Kind: settingswindow.CapabilityProjectTemplate, ID: generator.ID, Title: generator.DisplayName,
			Description: generator.Description,
		})
	}
	for _, window := range manifest.UI.ToolWindows {
		item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
			Kind: settingswindow.CapabilityToolWindow, ID: window.ID, Title: window.Title,
		})
	}
	for _, command := range manifest.UI.Commands {
		item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
			Kind: settingswindow.CapabilityCommand, ID: command.ID, Title: command.Title,
		})
	}
	for _, provider := range manifest.VcsProviders {
		item.Capabilities = append(item.Capabilities, settingswindow.PluginCapability{
			Kind: settingswindow.CapabilityVersionControl, ID: provider.ID, Title: provider.DisplayName,
		})
	}
}

// declared reports whether an optional manifest section is present.
func declared(value json.RawMessage) bool {
	return len(value) > 0 && string(value) != "null"
}
