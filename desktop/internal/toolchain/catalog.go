package toolchain

import (
	"context"
	"errors"
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type catalogKernel interface {
	ReadToolchainCatalogForWorkspace(context.Context, *string, string, string) (core.ToolchainCatalogState, error)
	EditToolchainCatalog(context.Context, *string, string, []core.ToolchainCatalogEdit) (core.ToolchainCatalogPublication, error)
	EditToolchainWorkspaceTrust(context.Context, *string, string, core.ToolchainWorkspaceTrustEdit) (core.ToolchainCatalogPublication, error)
}

type catalogSource struct {
	file     configfile.Snapshot
	state    core.ToolchainCatalogState
	platform string
}

// Global SDK registrations and machine-local workspace toolchain trust
// (trustedWorkspaces / projectCodeAllowed) live in <GlobalRoot>/toolchains/global.json
// inside the platform user preference directory (Application Support / LocalAppData).
// They are never written to the app bundle, plugin package directories or workspace
// .lithe/, do not affect code signing or Sparkle delta updates, and are never copied
// across worktrees. Reads do not create the root or file; source bytes and native
// identity remain private to this adapter.
func captureCatalog(ctx context.Context, kernel Kernel, root, workspaceRoot, platform string) (*catalogSource, error) {
	if root == "" {
		return nil, nil
	}
	native, ok := kernel.(catalogKernel)
	if !ok {
		return nil, errors.New("toolchain: the Core client has no global catalog support")
	}
	if platform == "" {
		platform = PlatformName(runtime.GOOS)
	}
	plan, err := native.ReadToolchainCatalogForWorkspace(ctx, nil, platform, "")
	if err != nil {
		return nil, err
	}
	file, err := configfile.Capture(ctx, root, plan.Storage.RelativePath, plan.Storage.MaximumBytes)
	if err != nil {
		return nil, err
	}
	document, err := file.Text()
	if err != nil {
		return nil, err
	}
	state, err := native.ReadToolchainCatalogForWorkspace(ctx, document, platform, workspaceRoot)
	if err != nil {
		return nil, err
	}
	return &catalogSource{file: file, state: state, platform: platform}, nil
}

// SaveCatalog publishes only confirmed registrations/defaults. It never writes
// a project pin or touches an SDK directory, and never treats a no-op as a file.
func (s Snapshot) SaveCatalog(ctx context.Context, kernel Kernel, edits []Edit) (bool, error) {
	if !s.Global || s.catalog == nil {
		return false, ErrPinConflict
	}
	native, ok := kernel.(catalogKernel)
	if !ok {
		return false, ErrPinConflict
	}
	text, err := s.catalog.file.Text()
	if err != nil {
		return false, err
	}
	entries := make([]core.ToolchainCatalogEdit, 0, len(edits))
	for _, edit := range edits {
		homes := []string{}
		for _, tool := range s.Tools {
			if tool.ID == edit.Tool {
				homes = append(homes, tool.CustomHomes...)
				break
			}
		}
		entry := core.ToolchainCatalogEdit{Tool: edit.Tool, Homes: homes}
		if edit.Pin != nil {
			home := edit.Pin.Home
			entry.DefaultHome = &home
		}
		entries = append(entries, entry)
	}
	change, err := native.EditToolchainCatalog(ctx, text, s.catalog.platform, entries)
	if err != nil {
		return false, err
	}
	if !change.Changed {
		return false, nil
	}
	if change.Document == nil {
		return false, errors.New("toolchain: changed catalog has no source")
	}
	committed, err := s.catalog.file.Replace(ctx, []byte(*change.Document), func() error { return s.catalog.file.Verify(ctx) })
	if errors.Is(err, configfile.ErrConflict) {
		err = errors.Join(ErrPinConflict, err)
	}
	if err != nil && committed {
		err = errors.Join(ErrPinCommitted, err)
	}
	return committed, err
}

// SaveWorkspaceTrust grants or revokes machine-local permission to probe and
// select tool environments or wrappers inside s.Root. It writes only to the
// platform preference root (toolchains/global.json), never to .lithe/ inside
// the workspace, and rejects stale sources or replaced workspace directories.
func (s Snapshot) SaveWorkspaceTrust(ctx context.Context, kernel Kernel, trusted bool) (bool, error) {
	if s.Global || s.Root == "" || s.catalog == nil {
		return false, ErrPinConflict
	}
	native, ok := kernel.(catalogKernel)
	if !ok {
		return false, ErrPinConflict
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	check := func() error {
		if err := checkDirectoryIdentity(ctx, s.Root, s.rootIdentity); err != nil {
			return err
		}
		if err := s.catalog.file.Verify(ctx); err != nil {
			if errors.Is(err, configfile.ErrConflict) {
				return errors.Join(ErrPinConflict, err)
			}
			return err
		}
		return nil
	}
	if err := check(); err != nil {
		return false, err
	}
	text, err := s.catalog.file.Text()
	if err != nil {
		return false, err
	}
	change, err := native.EditToolchainWorkspaceTrust(ctx, text, s.catalog.platform, core.ToolchainWorkspaceTrustEdit{
		Workspace: s.Root,
		Trusted:   trusted,
	})
	if err != nil {
		return false, err
	}
	if !change.Changed {
		return false, check()
	}
	if change.Document == nil {
		return false, errors.New("toolchain: changed catalog has no source")
	}
	committed, err := s.catalog.file.Replace(ctx, []byte(*change.Document), check)
	if errors.Is(err, configfile.ErrConflict) {
		err = errors.Join(ErrPinConflict, err)
	}
	if err != nil && committed {
		err = errors.Join(ErrPinCommitted, err)
	}
	return committed, err
}
