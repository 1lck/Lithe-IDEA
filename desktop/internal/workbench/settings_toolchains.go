package workbench

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"

	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

func (s settingsToolchains) Inspect(ctx context.Context, snapshot toolchain.Snapshot, tool, home string) (selection core.ToolchainSelection, err error) {
	ctx = s.app.performedIn(ctx, "toolchain.inspectDirectory", surfaceButton)
	defer func() { s.recordFailure(ctx, "toolchain_settings_inspect", err) }()
	if snapshot.Global {
		manifests, readErr := s.app.toolchainManifests(ctx)
		if readErr != nil {
			return selection, readErr
		}
		return toolchain.Resolve(ctx, s.app.kernel, "", ".", tool, "", &toolchain.Fixed{Home: home}, manifests, toolchain.Options{Global: true, GlobalRoot: s.app.globalToolchainRoot(), Platform: buildPlatform()})
	}
	root := s.app.toolchainRoot.Load()
	if root == nil || snapshot.Root == "" {
		return selection, toolchain.ErrPinConflict
	}
	if err := snapshot.CheckWorkspace(ctx, *root); err != nil {
		return selection, errors.Join(toolchain.ErrPinConflict, err)
	}
	manifests, err := s.app.toolchainManifests(ctx)
	if err != nil {
		return selection, err
	}
	selection, err = toolchain.Resolve(ctx, s.app.kernel, snapshot.Root, snapshot.Directory, tool, "", &toolchain.Fixed{Home: home}, manifests, toolchain.Options{Platform: buildPlatform(), GlobalRoot: s.app.globalToolchainRoot()})
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
	s.app.post(func(a *App) { a.retryFailedPluginServers() })
	updated, err = s.loadAt(ctx, snapshot.Root)
	if err != nil {
		return snapshot, errors.Join(toolchain.ErrPinCommitted, err)
	}
	return updated, nil
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
	manifests, err := s.app.toolchainManifests(ctx)
	if err != nil {
		return snapshot, err
	}
	return toolchain.Load(ctx, s.app.kernel, "", ".", manifests, toolchain.Options{Global: true, GlobalRoot: s.app.globalToolchainRoot(), Platform: buildPlatform()})
}

func (s settingsToolchains) loadAt(ctx context.Context, root string) (toolchain.Snapshot, error) {
	manifests, err := s.app.toolchainManifests(ctx)
	if err != nil && len(manifests) == 0 {
		return toolchain.Snapshot{}, err
	}
	return toolchain.Load(ctx, s.app.kernel, root, ".", manifests, toolchain.Options{Platform: buildPlatform(), GlobalRoot: s.app.globalToolchainRoot()})
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

// recordFailure logs a failed settings request from the settings worker that ran it, under the
// user action ctx carries; it never reads the window thread's operation.
func (s settingsToolchains) recordFailure(ctx context.Context, operation string, err error) {
	// log-exempt: 用户取消：设置窗口关闭或取消操作不是失败。
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	s.app.operationFailedIn(ctx, operation, err)
}
