package workbench

import (
	"context"
	"errors"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

func (s settingsToolchains) Inspect(ctx context.Context, snapshot toolchain.Snapshot, tool, home string) (selection core.ToolchainSelection, err error) {
	ctx = s.app.performedIn(ctx, "toolchain.inspectDirectory", surfaceButton)
	defer func() { s.recordFailure(ctx, "toolchain_settings_inspect", err) }()
	if snapshot.Global {
		manifests, _, readErr := s.app.usableToolchainManifests(ctx, "toolchain_settings_discovery")
		if readErr != nil {
			return selection, readErr
		}
		return toolchain.Resolve(ctx, s.app.kernel, "", ".", tool, "", &toolchain.Fixed{Home: home}, manifests, s.app.toolchainOptions(ctx, "", manifests))
	}
	root := s.app.toolchainRoot.Load()
	if root == nil || snapshot.Root == "" {
		return selection, toolchain.ErrPinConflict
	}
	if err := snapshot.CheckWorkspace(ctx, *root); err != nil {
		return selection, errors.Join(toolchain.ErrPinConflict, err)
	}
	manifests, _, err := s.app.usableToolchainManifests(ctx, "toolchain_settings_discovery")
	if err != nil {
		return selection, err
	}
	selection, err = toolchain.Resolve(ctx, s.app.kernel, snapshot.Root, snapshot.Directory, tool, "", &toolchain.Fixed{Home: home}, manifests, s.app.toolchainOptions(ctx, snapshot.Root, manifests))
	if err != nil {
		return selection, err
	}
	if current := s.app.toolchainRoot.Load(); current != root {
		return selection, toolchain.ErrPinConflict
	}
	return selection, snapshot.CheckWorkspace(ctx, *root)
}

// SetWorkspaceTrust grants or revokes machine-local permission to probe and run
// tool environments or wrappers inside the open project, then reloads toolchains.
func (s settingsToolchains) SetWorkspaceTrust(ctx context.Context, snapshot toolchain.Snapshot, trusted bool) (updated toolchain.Snapshot, err error) {
	if trusted {
		ctx = s.app.performedIn(ctx, "toolchain.workspaceTrust.grant", surfaceButton)
	} else {
		ctx = s.app.performedIn(ctx, "toolchain.workspaceTrust.revoke", surfaceButton)
	}
	defer func() { s.recordFailure(ctx, "toolchain_settings_trust", err) }()
	root := s.app.toolchainRoot.Load()
	if snapshot.Global || root == nil || *root == "" || snapshot.Root == "" {
		return snapshot, toolchain.ErrPinConflict
	}
	if err := snapshot.CheckWorkspace(ctx, *root); err != nil {
		return snapshot, errors.Join(toolchain.ErrPinConflict, err)
	}
	if _, err := snapshot.SaveWorkspaceTrust(ctx, s.app.kernel, trusted); err != nil {
		return snapshot, err
	}
	// The open project leaves or enters safe mode with the decision.
	s.app.post(func(a *App) {
		a.retryFailedPluginServers()
		a.reloadProjectTrust(a.project)
	})
	updated, err = s.loadAt(ctx, snapshot.Root)
	if err != nil {
		return snapshot, errors.Join(toolchain.ErrPinCommitted, err)
	}
	return updated, nil
}

// LoadTrustedLocations reads the machine's trusted locations from the preference directory.
func (s settingsToolchains) LoadTrustedLocations(ctx context.Context) (locations toolchain.TrustedLocations, err error) {
	defer func() { s.recordFailure(ctx, "toolchain_settings_trusted_locations_load", err) }()
	return toolchain.ReadTrustedLocations(ctx, s.app.kernel, s.app.globalToolchainRoot())
}

// PreviewTrustedLocations asks Core what the draft changes lead to, writing nothing.
func (s settingsToolchains) PreviewTrustedLocations(ctx context.Context, locations toolchain.TrustedLocations, changes []toolchain.LocationChange) (preview []string, err error) {
	defer func() { s.recordFailure(ctx, "toolchain_settings_trusted_locations_preview", err) }()
	return locations.Preview(ctx, s.app.kernel, changes)
}

// SaveTrustedLocations writes the draft changes against the bytes locations were read from;
// the open project then leaves or enters safe mode with its new trust, and the list is re-read.
func (s settingsToolchains) SaveTrustedLocations(ctx context.Context, locations toolchain.TrustedLocations, changes []toolchain.LocationChange) (updated toolchain.TrustedLocations, err error) {
	ctx = s.app.performedIn(ctx, "toolchain.trustedLocations.save", surfaceButton)
	defer func() { s.recordFailure(ctx, "toolchain_settings_trusted_locations_save", err) }()
	if _, err := locations.Save(ctx, s.app.kernel, changes); err != nil {
		return locations, err
	}
	s.app.post(func(a *App) {
		a.retryFailedPluginServers()
		a.reloadProjectTrust(a.project)
	})
	updated, err = toolchain.ReadTrustedLocations(ctx, s.app.kernel, s.app.globalToolchainRoot())
	if err != nil {
		return locations, errors.Join(toolchain.ErrPinCommitted, err)
	}
	return updated, nil
}

// LoadRemoteTrust reads the trust decisions this machine keeps on remote workspaces. It needs no
// connection; Core's message may name host paths, so only its code is logged.
func (s settingsToolchains) LoadRemoteTrust(ctx context.Context) (trust remoteconn.Trust, err error) {
	defer func() { s.recordFailure(ctx, "remote_trust_settings_load", documentLogError(err)) }()
	return remoteconn.ReadTrust(ctx, s.app.kernel, s.app.globalToolchainRoot(), "", "")
}

// SaveRemoteTrust removes the drafted records against the bytes trust was read from and reads
// them again. A remote workspace that is open keeps the trust it opened with until it opens again.
func (s settingsToolchains) SaveRemoteTrust(ctx context.Context, trust remoteconn.Trust, revokes []core.RemoteWorkspaceTrustRevoke) (updated remoteconn.Trust, err error) {
	ctx = s.app.performedIn(ctx, "remote.workspaceTrust.revoke", surfaceButton)
	defer func() { s.recordFailure(ctx, "remote_trust_settings_save", documentLogError(err)) }()
	if _, _, err := trust.Revoke(ctx, s.app.kernel, revokes); err != nil {
		return trust, err
	}
	return remoteconn.ReadTrust(ctx, s.app.kernel, s.app.globalToolchainRoot(), "", "")
}

// LoadRemotePreferences reads the remote workspace preferences and what each value resolves to
// when it is automatic. A damaged file still names its path. Core's message may name local paths,
// so only its code is logged.
func (s settingsToolchains) LoadRemotePreferences(ctx context.Context) (prefs settingswindow.RemotePreferences, err error) {
	defer func() { s.recordFailure(ctx, "remote_preferences_settings_load", documentLogError(err)) }()
	return s.readRemotePreferences(ctx)
}

// SaveRemotePreferences applies the page's edits in order against the bytes prefs was read from;
// a refused or conflicting edit stops the rest. Connections read the file each time OpenSSH
// starts, and a lost connection reads the reconnect limit when it is lost.
func (s settingsToolchains) SaveRemotePreferences(ctx context.Context, prefs settingswindow.RemotePreferences, edits []core.RemotePreferenceEdit) (updated settingswindow.RemotePreferences, err error) {
	ctx = s.app.performedIn(ctx, "remote.preferences.edit", surfaceButton)
	defer func() { s.recordFailure(ctx, "remote_preferences_settings_save", documentLogError(err)) }()
	saved := prefs.Saved
	for _, edit := range edits {
		if saved, _, err = saved.Edit(ctx, s.app.kernel, edit); err != nil {
			return prefs, err
		}
	}
	return s.readRemotePreferences(ctx)
}

func (s settingsToolchains) readRemotePreferences(ctx context.Context) (settingswindow.RemotePreferences, error) {
	// The home directory only names ~/.ssh/config; without one the row is left out.
	home, _ := os.UserHomeDir()
	automatic, err := s.app.kernel.RemotePreferences(ctx, nil, "")
	if err != nil {
		return settingswindow.RemotePreferences{}, err
	}
	saved, err := remoteconn.ReadPreferences(ctx, s.app.kernel, s.app.globalToolchainRoot(), home)
	return settingswindow.RemotePreferences{Saved: saved, Automatic: automatic}, err
}

// settingsToolchains is the settings window's adapter onto the workbench: it
// reads the open project's enabled plugin manifests and writes explicit
// directory pins. All calls run on the settings window's background worker.
type settingsToolchains struct {
	app *App
}

// Load reads toolchains for the open project. No project means an empty
// snapshot, which the page shows as "open a project".
func (s settingsToolchains) Load(ctx context.Context) (snapshot toolchain.Snapshot, err error) {
	defer func() { s.recordFailure(ctx, "toolchain_settings_load", err) }()
	root := s.app.toolchainRoot.Load()
	if root == nil || *root == "" {
		return toolchain.Snapshot{}, nil
	}
	return s.loadAt(ctx, *root)
}

// LoadScope keeps machine SDK management available before any project is open.
func (s settingsToolchains) LoadScope(ctx context.Context, scope string) (snapshot toolchain.Snapshot, err error) {
	if scope != "global" {
		return s.Load(ctx)
	}
	defer func() { s.recordFailure(ctx, "toolchain_settings_load", err) }()
	manifests, incomplete, err := s.app.usableToolchainManifests(ctx, "toolchain_settings_discovery")
	if err != nil {
		return snapshot, err
	}
	snapshot, err = toolchain.Load(ctx, s.app.kernel, "", ".", manifests, s.app.toolchainOptions(ctx, "", manifests))
	snapshot.DiscoveryIncomplete = incomplete
	return snapshot, err
}

func (s settingsToolchains) loadAt(ctx context.Context, root string) (toolchain.Snapshot, error) {
	manifests, incomplete, err := s.app.usableToolchainManifests(ctx, "toolchain_settings_discovery")
	if err != nil {
		return toolchain.Snapshot{}, err
	}
	snapshot, err := toolchain.Load(ctx, s.app.kernel, root, ".", manifests, s.app.toolchainOptions(ctx, root, manifests))
	snapshot.DiscoveryIncomplete = incomplete
	return snapshot, err
}

// Save applies all draft changes in one Core edit, against the exact
// bytes the snapshot was read from, then re-reads the effective values.
func (s settingsToolchains) Save(ctx context.Context, snapshot toolchain.Snapshot, edits []toolchain.Edit) (updated toolchain.Snapshot, err error) {
	defer func() { s.recordFailure(ctx, "toolchain_settings_save", err) }()
	if snapshot.Global {
		if _, err := snapshot.SaveCatalog(ctx, s.app.kernel, edits); err != nil {
			return snapshot, err
		}
		s.app.post(func(a *App) { a.retryFailedPluginServers() })
		updated, err = s.LoadScope(ctx, "global")
		if err != nil {
			return snapshot, errors.Join(toolchain.ErrPinCommitted, err)
		}
		return updated, nil
	}
	root := s.app.toolchainRoot.Load()
	if root == nil || *root == "" || snapshot.Root == "" {
		return snapshot, toolchain.ErrPinConflict
	}
	if err := snapshot.CheckWorkspace(ctx, *root); err != nil {
		return snapshot, errors.Join(toolchain.ErrPinConflict, err)
	}
	if _, _, err := snapshot.SavePins(ctx, s.app.kernel, edits); err != nil {
		return snapshot, err
	}
	s.app.post(func(a *App) { a.retryFailedPluginServers() })
	// A project switch during an already confirmed save must not retarget its
	// reread. The settings page continues to describe the captured source.
	updated, err = s.loadAt(ctx, snapshot.Root)
	if err != nil {
		return snapshot, errors.Join(toolchain.ErrPinCommitted, err)
	}
	return updated, nil
}

// SettingsView asks Core to filter, group, fold and count the Toolchains list.
// It runs on the settings worker for every query change.
func (s settingsToolchains) SettingsView(ctx context.Context, request core.ToolchainSettingsViewRequest) (view core.ToolchainSettingsView, err error) {
	defer func() { s.recordFailure(ctx, "toolchain_settings_view", err) }()
	return s.app.kernel.ToolchainSettingsViewOf(ctx, request)
}

// PrepareRuntime downloads or repairs the declared managed runtimes for tool's plugin,
// retries failed language servers, and reloads the requested scope's toolchain snapshot.
func (s settingsToolchains) PrepareRuntime(ctx context.Context, scope string, snapshot toolchain.Snapshot, tool toolchain.Tool, progress func(pluginruntime.Progress)) (updated toolchain.Snapshot, err error) {
	ctx = s.app.performedIn(ctx, "toolchain.prepareRuntime", surfaceButton)
	defer func() { s.recordFailure(ctx, "toolchain_prepare_runtime", err) }()
	if s.app.plugins == nil {
		return snapshot, errors.New("the plugin host is not available")
	}
	if err := s.app.plugins.PreparePluginRuntimes(ctx, tool.PluginID, progress); err != nil {
		return snapshot, err
	}
	s.app.post(func(a *App) { a.retryFailedPluginServers() })
	if scope == "global" {
		return s.LoadScope(ctx, "global")
	}
	root := s.app.toolchainRoot.Load()
	if root == nil || *root == "" || snapshot.Root == "" {
		return snapshot, toolchain.ErrPinConflict
	}
	if err := snapshot.CheckWorkspace(ctx, *root); err != nil {
		return snapshot, errors.Join(toolchain.ErrPinConflict, err)
	}
	return s.loadAt(ctx, snapshot.Root)
}

// recordFailure logs a failed settings request from the settings worker that ran it, under the
// user action ctx carries; it never reads the window thread's operation.
func (s settingsToolchains) recordFailure(ctx context.Context, operation string, err error) {
	// log-exempt: 用户取消：设置窗口关闭或取消操作不是失败。
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	s.app.operationFailedIn(ctx, operation, err)
}
