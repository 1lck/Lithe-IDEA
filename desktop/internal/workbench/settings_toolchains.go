package workbench

import (
	"context"
	"errors"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// settingsToolchains is the settings window's adapter onto the workbench: it
// reads the open project's enabled plugin manifests and writes explicit
// directory pins. All calls run on the settings window's background worker.
type settingsToolchains struct {
	app *App
}

// Load reads toolchains for the open project. No project means an empty
// snapshot, which the page shows as "open a project".
func (s settingsToolchains) Load(ctx context.Context) (snapshot toolchain.Snapshot, err error) {
	defer func() { s.recordFailure("toolchain_settings_load", err) }()
	root := s.app.toolchainRoot.Load()
	if root == nil || *root == "" {
		return toolchain.Snapshot{}, nil
	}
	return s.loadAt(ctx, *root)
}

func (s settingsToolchains) loadAt(ctx context.Context, root string) (toolchain.Snapshot, error) {
	manifests, err := s.app.toolchainManifests()
	if err != nil && len(manifests) == 0 {
		return toolchain.Snapshot{}, err
	}
	return toolchain.Load(ctx, s.app.kernel, root, ".", manifests, toolchain.Options{Platform: buildPlatform()})
}

// Save applies all draft changes in one Core edit, against the exact
// bytes the snapshot was read from, then re-reads the effective values.
func (s settingsToolchains) Save(ctx context.Context, snapshot toolchain.Snapshot, edits []toolchain.Edit) (updated toolchain.Snapshot, err error) {
	defer func() { s.recordFailure("toolchain_settings_save", err) }()
	root := s.app.toolchainRoot.Load()
	if root == nil || *root == "" || snapshot.Root == "" {
		return snapshot, toolchain.ErrPinConflict
	}
	// Compare native directory identity, not path spelling: Load canonicalizes
	// the root, while the window may have opened it through a platform alias.
	source, err := os.Stat(snapshot.Root)
	if err != nil {
		return snapshot, errors.Join(toolchain.ErrPinConflict, err)
	}
	current, err := os.Stat(*root)
	if err != nil {
		return snapshot, errors.Join(toolchain.ErrPinConflict, err)
	}
	if !source.IsDir() || !current.IsDir() || !os.SameFile(source, current) {
		return snapshot, toolchain.ErrPinConflict
	}
	if _, _, err := toolchain.SavePins(ctx, s.app.kernel, snapshot.Root, snapshot.Directory, edits, snapshot.Baseline); err != nil {
		return snapshot, err
	}
	// A project switch during an already confirmed save must not retarget its
	// reread. The settings page continues to describe the captured source.
	return s.loadAt(ctx, snapshot.Root)
}

func (s settingsToolchains) recordFailure(operation string, err error) {
	// log-exempt: 用户取消：设置窗口关闭或取消操作不是失败。
	if err == nil || errors.Is(err, context.Canceled) {
		return
	}
	s.app.emit(operationFailedLevel, operationFailedEvent, operationFailedFields(operation, err))
}
