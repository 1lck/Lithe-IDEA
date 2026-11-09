package workbench

import (
	"context"

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
func (s settingsToolchains) Load(ctx context.Context) (toolchain.Snapshot, error) {
	root := s.app.toolchainRoot.Load()
	if root == nil || *root == "" {
		return toolchain.Snapshot{}, nil
	}
	manifests, err := s.app.toolchainManifests()
	if err != nil && len(manifests) == 0 {
		return toolchain.Snapshot{}, err
	}
	return toolchain.Load(ctx, s.app.kernel, *root, ".", manifests, toolchain.Options{Platform: buildPlatform()})
}

// Save applies all draft changes in one Core edit, against the exact
// bytes the snapshot was read from, then re-reads the effective values.
func (s settingsToolchains) Save(ctx context.Context, snapshot toolchain.Snapshot, edits []toolchain.Edit) (toolchain.Snapshot, error) {
	root := s.app.toolchainRoot.Load()
	if root == nil || *root == "" {
		return snapshot, nil
	}
	if _, _, err := toolchain.SavePins(ctx, s.app.kernel, *root, snapshot.Directory, edits, snapshot.Baseline); err != nil {
		return snapshot, err
	}
	return s.Load(ctx)
}
