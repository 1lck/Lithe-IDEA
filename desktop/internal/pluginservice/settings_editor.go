package pluginservice

import (
	"bytes"
	"context"
	"errors"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

// SettingsEditor binds an editable snapshot to one installed package. Native
// identity and manifest bytes stay private; rendering cannot change its owner.
// Reading settings does not admit, enable or start a plugin.
type SettingsEditor struct {
	Snapshot  pluginsettings.Snapshot
	entry     pluginmanager.Entry
	directory os.FileInfo
	manifest  []byte
}

// SettingsCatalog returns validated metadata in Core's selected-version order,
// including disabled packages. Partial failures accompany healthy entries and
// must be recorded by the caller before presenting those entries.
func (s *Service) SettingsCatalog(ctx context.Context) ([]core.MarketplacePlugin, error) {
	entries, err := s.CurrentInstalled(ctx)
	if entries == nil && err != nil {
		return nil, err
	}
	catalog := make([]core.MarketplacePlugin, 0, len(entries))
	failures := []error{err}
	for _, entry := range entries {
		manifest, readErr := configfile.Capture(ctx, entry.Installed.Path, pluginpkg.ManifestFile, MaxManifestBytes)
		if readErr != nil {
			failures = append(failures, readErr)
			continue
		}
		state, stateErr := s.kernel.ReadInstalledPluginSettingsState(ctx, manifest.Bytes(), entry.Installed.ID, entry.Installed.Version)
		if stateErr != nil {
			failures = append(failures, stateErr)
			continue
		}
		catalog = append(catalog, core.MarketplacePlugin{ID: state.PluginID, Name: state.Metadata.DisplayName, Author: state.Metadata.Vendor, LatestVersion: state.Metadata.Version})
	}
	return catalog, errors.Join(failures...)
}

func (s *Service) settingsEntry(ctx context.Context, id string) (pluginmanager.Entry, error) {
	entries, err := s.CurrentInstalled(ctx)
	// An editing operation requires an unambiguous registration. The catalog can
	// show partial results; publication must not ignore discovery diagnostics.
	if err != nil {
		return pluginmanager.Entry{}, err
	}
	for _, entry := range entries {
		if entry.Installed.ID == id {
			return entry, nil
		}
	}
	return pluginmanager.Entry{}, pluginmanager.ErrUnknownPlugin
}

// LoadSettingsEditor captures real sources without creating files or processes.
func (s *Service) LoadSettingsEditor(ctx context.Context, id, workspace string) (SettingsEditor, error) {
	if s == nil || s.Settings == nil {
		return SettingsEditor{}, ErrAssembly
	}
	entry, err := s.settingsEntry(ctx, id)
	if err != nil {
		return SettingsEditor{}, err
	}
	info, err := settingsPackageDirectoryInfo(ctx, entry.Installed.Path)
	if err != nil {
		return SettingsEditor{}, err
	}
	manifest, err := configfile.Capture(ctx, entry.Installed.Path, pluginpkg.ManifestFile, MaxManifestBytes)
	if err != nil {
		return SettingsEditor{}, err
	}
	if _, err := s.kernel.ReadInstalledPluginSettingsState(ctx, manifest.Bytes(), entry.Installed.ID, entry.Installed.Version); err != nil {
		return SettingsEditor{}, err
	}
	snapshot, err := s.Settings.Load(ctx, manifest.Bytes(), workspace)
	if err != nil {
		return SettingsEditor{}, err
	}
	return SettingsEditor{Snapshot: snapshot, entry: entry, directory: info, manifest: manifest.Bytes()}, nil
}

// SaveSettingsEditor rejects replacement, uninstall and upgrade before publishing
// to captured preference sources. check additionally binds a project window.
func (s *Service) SaveSettingsEditor(ctx context.Context, editor SettingsEditor, scope string, edits []core.PluginSettingEdit, check func() error) (pluginsettings.SaveResult, error) {
	if s == nil || s.Settings == nil {
		return pluginsettings.SaveResult{}, ErrAssembly
	}
	owner := func() error {
		if check != nil {
			if err := check(); err != nil {
				return err
			}
		}
		entry, err := s.settingsEntry(ctx, editor.entry.Installed.ID)
		if err != nil {
			return errors.Join(configfile.ErrConflict, err)
		}
		if entry.Installed.Version != editor.entry.Installed.Version || entry.Installed.Path != editor.entry.Installed.Path {
			return configfile.ErrConflict
		}
		info, err := settingsPackageDirectoryInfo(ctx, entry.Installed.Path)
		if err != nil {
			return errors.Join(configfile.ErrConflict, err)
		}
		if editor.directory == nil || !os.SameFile(editor.directory, info) {
			return configfile.ErrConflict
		}
		manifest, err := configfile.Capture(ctx, entry.Installed.Path, pluginpkg.ManifestFile, MaxManifestBytes)
		if err != nil {
			return err
		}
		if !bytes.Equal(manifest.Bytes(), editor.manifest) {
			return configfile.ErrConflict
		}
		return nil
	}
	return s.Settings.Save(ctx, editor.Snapshot, scope, edits, owner)
}

// Capture identity from an open directory handle. On Windows os.Stat may defer
// loading the file ID until SameFile, which would reopen an already replaced
// pathname and mistake the replacement for the original package.
func settingsPackageDirectoryInfo(ctx context.Context, path string) (info os.FileInfo, err error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	directory, err := root.Open(".")
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, directory.Close()) }()
	info, err = directory.Stat()
	if err != nil {
		return nil, err
	}
	return info, ctx.Err()
}
