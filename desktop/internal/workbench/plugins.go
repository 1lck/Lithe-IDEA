package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"maps"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/ui"
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
// Downloading and extracting happen off the window thread. Progress and results
// stay in the active window; nothing is installed before explicit confirmation.
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
	generation      uint64
	cancel          context.CancelFunc
	received, total int64
	phase           string
	failed          bool
	failure         error
	archivePath     string
}

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
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_list", err))
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
				// An open New Project window lists the generators again.
				a.newProject.revision++
			}
			a.pluginState.Store(&states)
			if changed && a.settingsWindow != nil {
				a.settingsWindow.PluginRegistryChanged()
			}
		}
	})
}

// installPlugin downloads and reviews one marketplace version.
//
// Nothing is installed here: the review sheet opens with what the package asks for,
// and only confirmPluginInstall writes anything the user can run.
func (a *App) installPlugin(plugin core.MarketplacePlugin) {
	if a.plugins == nil || a.pluginInstall.busy || a.pluginInstall.open {
		return
	}
	if plugin.Availability.Status != "available" || plugin.Availability.DownloadURL == "" {
		a.notifyError(i18n.Shared(a.language(), "desktop.marketplace.installFailed"))
		return
	}
	a.pluginInstall.generation++
	generation := a.pluginInstall.generation
	// Clear any completed staging record before assigning the next native transfer.
	a.discardPluginInstall()
	a.pluginInstall.plugin = plugin
	a.pluginInstall.busy = true
	a.pluginInstall.open = false
	a.pluginInstall.received, a.pluginInstall.total = 0, -1
	a.pluginInstall.failed = false
	a.pluginInstall.failure = nil
	a.pluginInstall.archivePath = ""
	a.pluginInstall.phase = "connect"
	transfer, cancel := context.WithCancel(context.Background())
	a.pluginInstall.cancel = cancel
	a.publishPluginInstall()
	a.performed("plugin.install", "marketplace")
	availability := plugin.Availability
	a.background(nil, pluginDownloadTimeout, func(ctx context.Context) func(*App) {
		downloadContext, stopDownload := context.WithCancel(ctx)
		stopTransfer := context.AfterFunc(transfer, stopDownload)
		defer stopTransfer()
		defer stopDownload()
		archive, err := marketplace.NewArchiveDownloader(nil).DownloadWithProgress(downloadContext, availability, func(received, total int64) {
			a.post(func(a *App) {
				if a.pluginInstall.generation != generation || !a.pluginInstall.busy {
					return
				}
				a.pluginInstall.phase = "download"
				a.pluginInstall.received, a.pluginInstall.total = received, total
				a.publishPluginInstall()
			})
		})
		if err != nil {
			return func(a *App) { a.finishPluginInstall(generation, plugininstall.Plan{}, err) }
		}
		// Extraction copies what it needs into the staging directory, so the
		// download is no longer needed once Prepare returns.
		defer archive.Discard()
		a.post(func(a *App) {
			if a.pluginInstall.generation == generation {
				a.pluginInstall.failed = false
				a.pluginInstall.phase = "prepare"
				a.publishPluginInstall()
			}
		})
		plan, err := a.plugins.Installer.Prepare(downloadContext, plugininstall.Request{
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

// installPluginFromFile reviews a package the user picked on disk. It goes through the
// same review sheet as a marketplace install; nothing is written until the user confirms.
// The package has no index digest to check, so its approval is asked for every time.
func (a *App) installPluginFromFile(path string) {
	if a.plugins == nil || a.pluginInstall.busy || a.pluginInstall.open {
		return
	}
	a.pluginInstall.generation++
	generation := a.pluginInstall.generation
	a.discardPluginInstall()
	a.pluginInstall.plugin = core.MarketplacePlugin{}
	a.pluginInstall.busy = true
	a.pluginInstall.open = false
	a.pluginInstall.failed = false
	a.pluginInstall.phase = "prepare"
	a.pluginInstall.failure = nil
	a.pluginInstall.archivePath = path
	transfer, cancel := context.WithCancel(context.Background())
	a.pluginInstall.cancel = cancel
	a.publishPluginInstall()
	a.performed("plugin.install", "disk")
	a.background(nil, pluginDownloadTimeout, func(ctx context.Context) func(*App) {
		prepareContext, stopPrepare := context.WithCancel(ctx)
		stopTransfer := context.AfterFunc(transfer, stopPrepare)
		defer stopTransfer()
		defer stopPrepare()
		plan, err := a.plugins.Installer.Prepare(prepareContext, plugininstall.Request{
			ArchivePath: path,
			Root:        a.plugins.Root,
			Source:      plugintrust.Disk,
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
	if a.pluginInstall.cancel != nil {
		a.pluginInstall.cancel()
		a.pluginInstall.cancel = nil
	}
	defer a.publishPluginInstall()
	a.pluginInstall.failed = err != nil
	a.pluginInstall.failure = err
	if err != nil {
		a.notifyError(i18n.Shared(a.language(), "desktop.marketplace.installFailed"))
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_install", err))
		return
	}
	a.pluginInstall.plan = plan
	a.pluginInstall.open = true
	a.pluginInstall.phase = "review"
}

// confirmPluginInstall installs the reviewed package and records the approval.
func (a *App) confirmPluginInstall() {
	if !a.pluginInstall.open || a.pluginInstall.busy {
		return
	}
	plan := a.pluginInstall.plan
	a.pluginInstall.open = false
	if a.pluginInstall.plugin.Name == "" {
		a.pluginInstall.plugin.Name = plan.ID
	}
	a.pluginInstall.plugin.Availability.Version = plan.Version
	a.pluginInstall.plan = plugininstall.Plan{}
	if a.plugins == nil || plan.Staging == "" {
		a.publishPluginInstall()
		return
	}
	a.pluginInstall.busy = true
	a.pluginInstall.phase = "install"
	a.publishPluginInstall()
	a.background(nil, pluginInstallTimeout, func(ctx context.Context) func(*App) {
		_, err := a.plugins.Installer.Commit(plan)
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
		return func(a *App) {
			a.pluginInstall.busy = false
			a.pluginInstall.failed = err != nil && approval == nil
			a.pluginInstall.failure = err
			if !a.pluginInstall.failed {
				a.pluginInstall.phase = "done"
			}
			a.publishPluginInstall()
			installed := err == nil
			if enableErr != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_enable", enableErr))
			}
			if err != nil {
				if approval != nil {
					installed = true
					// The package is on disk; only its approval record failed, so the
					// user is not told the installation failed. The next installation
					// of the same version asks again.
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_approval", err))
				} else {
					a.notifyError(i18n.Shared(a.language(), "desktop.marketplace.installFailed"))
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_commit", err))
					// A refused install leaves the extracted package behind; Discard
					// is a no-op once the rename consumed it.
					_ = a.plugins.Installer.Discard(plan)
				}
			}
			if installed && plan.ID != "" {
				// The installation was just enabled, unless the user had disabled the
				// plugin, so a disable tombstone from a previous version must not
				// block its server.
				a.allowPluginPrograms(plan.ID)
			}
			a.stopDisplaced(displaced)
			a.refreshPluginState()
			a.reloadPluginLanguages()
		}
	})
}

// cancelPluginInstall drops a prepared package the user declined.
func (a *App) cancelPluginInstall() {
	if a.pluginInstall.busy && a.pluginInstall.phase == "install" {
		return
	}
	if a.pluginInstall.cancel != nil {
		a.pluginInstall.cancel()
		a.pluginInstall.cancel = nil
	}
	a.pluginInstall.busy = false
	a.pluginInstall.failed = false
	a.pluginInstall.failure = nil
	a.pluginInstall.phase = ""
	defer a.publishPluginInstall()
	a.pluginInstall.open = false
	a.pluginInstall.generation++
	a.discardPluginInstall()
}

// retryPluginInstall restarts native I/O and always asks for approval again.
func (a *App) retryPluginInstall(token uint64) {
	if token != a.pluginInstall.generation || !a.pluginInstall.failed || a.pluginInstall.busy {
		return
	}
	plugin, path := a.pluginInstall.plugin, a.pluginInstall.archivePath
	a.cancelPluginInstall()
	if path != "" {
		a.installPluginFromFile(path)
	} else {
		a.installPlugin(plugin)
	}
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
	// A disabled plugin keeps no process and no session: its server leaves the
	// workbench now, and Disable stops it and the plugin's backend.
	var server *pluginservice.LanguageSession
	if !enabled {
		server = a.detachPluginServer(id)
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
			err = a.plugins.Disable(ctx, id, server)
		}
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_enable", err))
			}
			if enabled {
				// An enable clears the tombstone a disable left for an in-flight start.
				a.allowPluginPrograms(id)
			}
			a.stopDisplaced(displaced)
			// Enabling and disabling both change the detected build systems.
			a.invalidateBuild(a.project)
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
	// Detach native owners on their window thread before asking Core to remove
	// anything. The stopPrograms step waits for every tab, including late starts.
	stop := a.detachPluginPrograms(id)
	a.background(nil, pluginInstallTimeout, func(ctx context.Context) func(*App) {
		err := a.plugins.Uninstall(ctx, id, nil, stop)
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_uninstall", err))
			}
			for _, tab := range a.everyTab() {
				if err == nil {
					tab.invalidateBuild(tab.project)
					tab.reloadPluginLanguages()
				}
				tab.refreshPluginState()
			}
		}
	})
}

// reloadPluginLanguages registers the languages and tool windows of the enabled plugins.
//
// The registry replaces its plugin languages whole, and the catalog its plugin tool
// windows, so a plugin that was disabled or removed loses its highlighting and its
// windows in the same pass that registers a new one.
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
		windows, windowsErr := a.plugins.ToolWindows(ctx, entries)
		commands, commandsErr := a.plugins.ToolCommands(ctx, entries)
		vcsPlugins, vcsErr := a.plugins.VcsPlugins(ctx, entries)
		return func(a *App) {
			if commandsErr != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_tool_commands", commandsErr))
			}
			a.pluginCommands = commands
			shortcuts.SetPluginActions(pluginCommandActions(commands))
			if loadErr != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_languages", loadErr))
			}
			if windowsErr != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_tool_windows", windowsErr))
			}
			if vcsErr != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_vcs_providers", vcsErr))
			}
			a.setPluginTools(windows, vcsWindows(vcsPlugins))
			failed, _ := a.syntaxRegistry().SetPluginLanguages(languages)
			if len(failed) > 0 {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_languages",
					fmt.Errorf("%d plugin languages were rejected", len(failed))))
			}
		}
	})
}

// pluginReviewView declares the dialog that shows what a package asks for
// before it is installed.
func (a *App) pluginReviewView(c ui.C) {
	if a.settingsWindow != nil && a.settingsWindow.IsOpen() {
		return
	}
	settingswindow.DrawPluginInstall(c, a.language(), a.installPresentation(), &a.pluginInstallDialog,
		func(token uint64) {
			if token == a.pluginInstall.generation {
				a.confirmPluginInstall()
			}
		}, func(token uint64) {
			if token == a.pluginInstall.generation {
				a.cancelPluginInstall()
			}
		}, a.retryPluginInstall)
}

// publishPluginInstall shares a fresh immutable snapshot with the settings window.
// The native owner alone mutates the transfer and prepared package.
func (a *App) publishPluginInstall() {
	in := &a.pluginInstall
	status := settingswindow.PluginInstallStatus{Token: in.generation, Busy: in.busy, Review: in.open, Failed: in.failed, Completed: in.phase == "done", Failure: a.pluginInstallFailure(),
		Name: in.plugin.Name, Version: in.plan.Version, Phase: in.phase, Received: in.received, Total: in.total,
		Permissions: slices.Clone(in.plan.Review.Permissions), Reused: in.plan.Decision.Reuse}
	if status.Version == "" {
		status.Version = in.plugin.Availability.Version
	}
	if status.Name == "" {
		status.Name = in.plan.ID
	}
	for _, program := range in.plan.Review.Programs {
		status.Programs = append(status.Programs, compactProgram(program))
	}
	a.pluginInstallStatus.Store(&status)
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
}

func (a *App) installPresentation() settingswindow.PluginInstallStatus {
	if status := a.pluginInstallStatus.Load(); status != nil {
		return *status
	}
	return settingswindow.PluginInstallStatus{}
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
					item.Programs = append(item.Programs, compactProgram(program))
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

// pluginInstallFailure localizes native I/O failures without exposing URLs or paths.
func (a *App) pluginInstallFailure() string {
	err := a.pluginInstall.failure
	if err == nil {
		return ""
	}
	var network net.Error
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return i18n.Shared(a.language(), "desktop.marketplace.failureTimeout")
	case errors.Is(err, marketplace.ErrArchiveChecksum):
		return i18n.Shared(a.language(), "desktop.marketplace.failureChecksum")
	case errors.As(err, &network):
		return i18n.Shared(a.language(), "desktop.marketplace.failureNetwork")
	case errors.Is(err, os.ErrPermission):
		return i18n.Shared(a.language(), "desktop.marketplace.failurePermission")
	default:
		return i18n.Shared(a.language(), "desktop.marketplace.failureHelp")
	}
}
