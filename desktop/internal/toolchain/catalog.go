package toolchain

import (
	"context"
	"errors"
	"os"
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
	return saveWorkspaceTrust(ctx, kernel, s.catalog, s.Root, s.rootIdentity, core.ToolchainWorkspaceTrustEdit{
		Workspace: s.Root,
		Trusted:   trusted,
	})
}

// WorkspaceTrust is one workspace's trust decision as Core reads it from the
// machine-local catalog, with the source it was read from so a decision is saved
// against the same bytes.
type WorkspaceTrust struct {
	// Root is the workspace folder.
	Root string
	core.ToolchainWorkspaceTrust
	catalog      *catalogSource
	rootIdentity os.FileInfo
}

// ReadWorkspaceTrust reads the trust of the workspace at root from the catalog in
// globalRoot, the platform preference directory. Reading creates nothing.
func ReadWorkspaceTrust(ctx context.Context, kernel Kernel, globalRoot, root string) (WorkspaceTrust, error) {
	if globalRoot == "" || root == "" {
		return WorkspaceTrust{}, errors.New("toolchain: workspace trust needs the preference directory and a workspace")
	}
	identity, err := directoryIdentity(ctx, root)
	if err != nil {
		return WorkspaceTrust{}, err
	}
	catalog, err := captureCatalog(ctx, kernel, globalRoot, root, "")
	if err != nil {
		return WorkspaceTrust{}, err
	}
	if catalog.state.WorkspaceTrust == nil {
		return WorkspaceTrust{}, errors.New("toolchain: Core returned no workspace trust")
	}
	return WorkspaceTrust{Root: root, ToolchainWorkspaceTrust: *catalog.state.WorkspaceTrust, catalog: catalog, rootIdentity: identity}, nil
}

// Save records the user's decision: trusted lets the workspace's project code run
// and false keeps it in safe mode; location also trusts its offered parent folder.
// It writes only toolchains/global.json in the preference directory and refuses a
// catalog changed since it was read or a workspace folder replaced since.
func (t WorkspaceTrust) Save(ctx context.Context, kernel Kernel, trusted, location bool) (bool, error) {
	if t.catalog == nil {
		return false, ErrPinConflict
	}
	return saveWorkspaceTrust(ctx, kernel, t.catalog, t.Root, t.rootIdentity, core.ToolchainWorkspaceTrustEdit{
		Workspace: t.Root,
		Trusted:   trusted,
		Location:  location,
	})
}

// saveWorkspaceTrust publishes one trust decision on root against the catalog
// bytes it was read from.
func saveWorkspaceTrust(ctx context.Context, kernel Kernel, catalog *catalogSource, root string, rootIdentity os.FileInfo, edit core.ToolchainWorkspaceTrustEdit) (bool, error) {
	native, ok := kernel.(catalogKernel)
	if !ok {
		return false, ErrPinConflict
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	check := func() error {
		if err := checkDirectoryIdentity(ctx, root, rootIdentity); err != nil {
			return err
		}
		if err := catalog.file.Verify(ctx); err != nil {
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
	text, err := catalog.file.Text()
	if err != nil {
		return false, err
	}
	change, err := native.EditToolchainWorkspaceTrust(ctx, text, catalog.platform, edit)
	if err != nil {
		return false, err
	}
	if !change.Changed {
		return false, check()
	}
	if change.Document == nil {
		return false, errors.New("toolchain: changed catalog has no source")
	}
	committed, err := catalog.file.Replace(ctx, []byte(*change.Document), check)
	if errors.Is(err, configfile.ErrConflict) {
		err = errors.Join(ErrPinConflict, err)
	}
	if err != nil && committed {
		err = errors.Join(ErrPinCommitted, err)
	}
	return committed, err
}
