package toolchain

import (
	"context"
	"errors"
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

type catalogKernel interface {
	ReadToolchainCatalog(context.Context, *string, string) (core.ToolchainCatalogState, error)
	EditToolchainCatalog(context.Context, *string, string, []core.ToolchainCatalogEdit) (core.ToolchainCatalogPublication, error)
}

type catalogSource struct {
	file     configfile.Snapshot
	state    core.ToolchainCatalogState
	platform string
}

// Global registrations live in the platform preference root. Reads do not create
// that root; source bytes and native identity remain private to this adapter.
func captureCatalog(ctx context.Context, kernel Kernel, root, platform string) (*catalogSource, error) {
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
	plan, err := native.ReadToolchainCatalog(ctx, nil, platform)
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
	state, err := native.ReadToolchainCatalog(ctx, document, platform)
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
