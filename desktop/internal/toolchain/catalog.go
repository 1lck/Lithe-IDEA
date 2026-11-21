package toolchain

import (
	"context"
	"errors"
	"os"
	"runtime"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type catalogReader interface {
	ReadToolchainCatalogForWorkspace(context.Context, *string, string, string) (core.ToolchainCatalogState, error)
}

type catalogKernel interface {
	catalogReader
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
	file, err := captureCatalogFile(ctx, native, root, platform)
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

func captureCatalogFile(ctx context.Context, kernel catalogReader, root, platform string) (configfile.Snapshot, error) {
	plan, err := kernel.ReadToolchainCatalogForWorkspace(ctx, nil, platform, "")
	if err != nil {
		return configfile.Snapshot{}, err
	}
	return configfile.Capture(ctx, root, plan.Storage.RelativePath, plan.Storage.MaximumBytes)
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
	check := func() error { return s.catalog.verify(ctx) }
	return s.catalog.replace(ctx, *change.Document, check)
}

// verify refuses a catalog file changed since it was read, as ErrPinConflict.
func (c *catalogSource) verify(ctx context.Context) error {
	if err := c.file.Verify(ctx); err != nil {
		if errors.Is(err, configfile.ErrConflict) {
			return errors.Join(ErrPinConflict, err)
		}
		return err
	}
	return nil
}

// replace writes document over the catalog file atomically once check passes. A conflict is
// ErrPinConflict; a failure after the bytes were committed is also ErrPinCommitted.
func (c *catalogSource) replace(ctx context.Context, document string, check func() error) (bool, error) {
	committed, err := c.file.Replace(ctx, []byte(document), check)
	if errors.Is(err, configfile.ErrConflict) && !errors.Is(err, ErrPinConflict) {
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
		return catalog.verify(ctx)
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
	return catalog.replace(ctx, *change.Document, check)
}

// locationsKernel is a Core client that edits the trusted locations of a catalog.
type locationsKernel interface {
	EditToolchainTrustedLocations(context.Context, *string, string, core.ToolchainTrustedLocationsEdit) (core.ToolchainCatalogPublication, error)
}

// LocationChange is one change the user made to the trusted locations: Add trusts Folder,
// otherwise the change stops trusting it.
type LocationChange struct {
	Folder string
	Add    bool
}

// LocationChangeError is a change Core refused; Index is its place in the changes.
type LocationChangeError struct {
	Index int
	Err   error
}

func (e *LocationChangeError) Error() string { return e.Err.Error() }
func (e *LocationChangeError) Unwrap() error { return e.Err }

// TrustedLocations are the folders the machine trusts every workspace in, as Core reads them
// from the catalog in the preference directory (toolchains/global.json), with the bytes they
// were read from, so changes are saved against the same source. The catalog lives in the
// platform user preference directory, never in the app bundle, an installation directory or a
// workspace, so it affects neither code signing nor Sparkle delta updates.
type TrustedLocations struct {
	// Locations are the trusted folders in the catalog's order, as Core normalized them.
	Locations []string
	catalog   *catalogSource
}

// ReadTrustedLocations reads the trusted locations from the catalog in globalRoot, the
// platform preference directory. Reading creates nothing.
func ReadTrustedLocations(ctx context.Context, kernel Kernel, globalRoot string) (TrustedLocations, error) {
	if globalRoot == "" {
		return TrustedLocations{}, errors.New("toolchain: trusted locations need the preference directory")
	}
	catalog, err := captureCatalog(ctx, kernel, globalRoot, "", "")
	if err != nil {
		return TrustedLocations{}, err
	}
	return TrustedLocations{Locations: slices.Clone(catalog.state.Document.TrustedLocations), catalog: catalog}, nil
}

// Preview replays changes, in order, on the bytes l was read from and returns the locations
// they lead to. It writes nothing. A change Core refuses is a *LocationChangeError.
func (l TrustedLocations) Preview(ctx context.Context, kernel Kernel, changes []LocationChange) ([]string, error) {
	_, locations, err := l.replay(ctx, kernel, changes)
	return locations, err
}

// Save replays changes on the bytes l was read from and, when the locations they lead to
// differ, writes the result to the catalog. It refuses a catalog changed since it was read
// (ErrPinConflict) and writes only toolchains/global.json in the preference directory.
func (l TrustedLocations) Save(ctx context.Context, kernel Kernel, changes []LocationChange) (bool, error) {
	if l.catalog == nil {
		return false, ErrPinConflict
	}
	check := func() error { return l.catalog.verify(ctx) }
	if err := check(); err != nil {
		return false, err
	}
	document, locations, err := l.replay(ctx, kernel, changes)
	if err != nil {
		return false, err
	}
	if document == nil || sameLocations(locations, l.Locations) {
		// Nothing to write: the changes cancel out, at most moving a folder in the list.
		return false, check()
	}
	return l.catalog.replace(ctx, *document, check)
}

// sameLocations reports whether two lists hold the same folders, in any order.
func sameLocations(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	a, b = slices.Clone(a), slices.Clone(b)
	slices.Sort(a)
	slices.Sort(b)
	return slices.Equal(a, b)
}

// replay applies changes one at a time, so a folder removed and added again is trusted, as
// the user's last change says, rather than refused as both added and removed. document is the
// source the last change led to, nil while it is the file's own missing source.
func (l TrustedLocations) replay(ctx context.Context, kernel Kernel, changes []LocationChange) (document *string, locations []string, err error) {
	native, ok := kernel.(locationsKernel)
	if !ok || l.catalog == nil {
		return nil, nil, ErrPinConflict
	}
	document, err = l.catalog.file.Text()
	if err != nil {
		return nil, nil, err
	}
	locations = slices.Clone(l.Locations)
	for index, change := range changes {
		edit := core.ToolchainTrustedLocationsEdit{Remove: []string{change.Folder}}
		if change.Add {
			edit = core.ToolchainTrustedLocationsEdit{Add: []string{change.Folder}}
		}
		publication, err := native.EditToolchainTrustedLocations(ctx, document, l.catalog.platform, edit)
		if err != nil {
			return nil, nil, &LocationChangeError{Index: index, Err: err}
		}
		if publication.Changed {
			if publication.Document == nil {
				return nil, nil, errors.New("toolchain: changed catalog has no source")
			}
			document = publication.Document
		}
		locations = publication.Catalog.TrustedLocations
	}
	return document, locations, nil
}
