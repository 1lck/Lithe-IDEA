package plugininstall

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

// pendingDirectory is private to the plugin data root. Inventory skips dot
// directories, so running windows keep using the old version until next startup.
const pendingDirectory = ".pending-updates"

const pendingReceiptFile = "selection.json"
const pendingPackageDirectory = "package"

type pendingReceipt struct {
	BaseVersion string             `json:"baseVersion"`
	BaseSHA256  string             `json:"baseSHA256"`
	Target      plugintrust.Record `json:"target"`
}

// HasPending avoids downloading a second update for a plugin until restart.
func (s *Service) HasPending(root, id string) (bool, error) {
	if !filepath.IsAbs(root) {
		return false, ErrRequest
	}
	if err := pluginpkg.CheckIdentity("plugin ID", id); err != nil {
		return false, err
	}
	_, err := os.Lstat(filepath.Join(root, pendingDirectory, id))
	// log-exempt: 预期的缺失：没有为此插件暂存自动更新。
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

// DiscardPending clears the unactivated package and its receipt on uninstall.
func (s *Service) DiscardPending(root, id string) error {
	pending, err := s.HasPending(root, id)
	if err != nil || !pending {
		return err
	}
	return os.RemoveAll(filepath.Join(root, pendingDirectory, id))
}

// StageAutomatic publishes a prepared package into the hidden pending inventory.
// The package and its approval receipt are published by one directory rename.
func (s *Service) StageAutomatic(plan Plan, previous plugintrust.Record) (err error) {
	if plan.Staging == "" || previous.PluginID != plan.ID || previous.Version == plan.Version ||
		plan.Source != plugintrust.Marketplace ||
		!plugintrust.MayAutoUpdate(previous, true, plan.MarketplaceIndexURL, plan.Review) {
		return ErrNotPrepared
	}
	pending, err := s.HasPending(plan.Root, plan.ID)
	if err != nil {
		return err
	}
	if pending {
		return pluginpkg.ErrPackageExists
	}
	targetRoot := filepath.Join(plan.Root, pendingDirectory)
	if err := os.MkdirAll(targetRoot, 0o700); err != nil {
		return err
	}
	candidate, err := pluginpkg.NewStaging(plan.Root)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, os.RemoveAll(candidate)) }()
	receipt := pendingReceipt{previous.Version, previous.ArchiveSHA256, approvalFor(plan)}
	data, err := json.Marshal(receipt)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(candidate, pendingReceiptFile), data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(plan.Staging, filepath.Join(candidate, pendingPackageDirectory)); err != nil {
		return err
	}
	return os.Rename(candidate, filepath.Join(targetRoot, plan.ID))
}

// ActivatePending is called once before a new process exposes plugin inventory.
// An intervening manual upgrade, uninstall or disable abandons the pending update.
func (s *Service) ActivatePending(ctx context.Context, root string, begin func(context.Context, string) (context.Context, func() error, error), active func(context.Context, string) (string, error)) error {
	dir := filepath.Join(root, pendingDirectory)
	entries, err := os.ReadDir(dir)
	// log-exempt: 预期的缺失：用户从未暂存过自动更新。
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil || len(entries) == 0 {
		return err
	}
	var failures []error
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return errors.Join(append(failures, err)...)
		}
		if !entry.IsDir() {
			continue
		}
		if err := s.activatePending(ctx, root, entry.Name(), begin, active); err != nil {
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}

func (s *Service) activatePending(ctx context.Context, root, id string, begin func(context.Context, string) (context.Context, func() error, error), current func(context.Context, string) (string, error)) (err error) {
	if err := pluginpkg.CheckIdentity("plugin ID", id); err != nil {
		return err
	}
	work, finish, err := begin(ctx, id)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, finish()) }()
	ctx = work
	pending, err := s.HasPending(root, id)
	if err != nil || !pending {
		return err
	}
	dir := filepath.Join(root, pendingDirectory, id)
	raw, err := pluginpkg.ReadFile(dir, []string{pendingReceiptFile}, MaxManifestBytes)
	if err != nil {
		return errors.Join(err, os.RemoveAll(dir))
	}
	var receipt pendingReceipt
	if err := json.Unmarshal(raw, &receipt); err != nil {
		return errors.Join(err, os.RemoveAll(dir))
	}
	active, err := current(ctx, id)
	if err != nil {
		return err
	}
	if active == "" || active != receipt.BaseVersion || active == receipt.Target.Version {
		return os.RemoveAll(dir)
	}
	base, found, err := s.approvals.Record(id, active)
	if err != nil {
		return err
	}
	target := receipt.Target
	if target.PluginID != id || target.Validate() != nil || base.ArchiveSHA256 != receipt.BaseSHA256 ||
		target.Source != plugintrust.Marketplace || target.ContentDigest == "" ||
		!plugintrust.MayAutoUpdate(base, found, target.MarketplaceIndexURL, plugintrust.Review{
			Permissions: target.Permissions, Programs: target.ApprovedPrograms,
		}) {
		return errors.Join(errors.New("pending plugin update no longer matches its approval"), os.RemoveAll(dir))
	}
	packageDir := filepath.Join(dir, pendingPackageDirectory)
	digest, err := pendingContentDigest(ctx, packageDir)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil || digest != target.ContentDigest {
		return errors.Join(ErrArchiveDigest, err, os.RemoveAll(dir))
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	manifest, err := readManifest(packageDir)
	if err != nil {
		return errors.Join(err, os.RemoveAll(dir))
	}
	if _, err := pluginhost.Validate(ctx, s.validator, manifest, s.capabilities); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return errors.Join(err, os.RemoveAll(dir))
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := s.approvals.Approve(target); err != nil {
		return err
	}
	if _, err := pluginpkg.Install(root, id, target.Version, packageDir); err != nil {
		return err
	}
	return os.RemoveAll(dir)
}

// pendingContentDigest checks what will actually execute after a restart. It
// walks only the staging tree and applies the same input and size limits as a ZIP.
func pendingContentDigest(ctx context.Context, root string) (string, error) {
	var files []pluginpkg.File
	var total int64
	entries := 0
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if path == root {
			if !entry.IsDir() {
				return pluginpkg.ErrUnsafePath
			}
			return nil
		}
		entries++
		if entries > pluginpkg.MaxEntries*pluginpkg.MaxPathDepth || len(files) == pluginpkg.MaxEntries {
			return pluginpkg.ErrTooManyEntries
		}
		if entry.IsDir() {
			return nil
		}
		if !entry.Type().IsRegular() {
			return pluginpkg.ErrSpecialFile
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.Size() > pluginpkg.MaxFileBytes {
			return pluginpkg.ErrFileTooLarge
		}
		total += info.Size()
		if total > pluginpkg.MaxExtractedBytes {
			return pluginpkg.ErrArchiveTooLarge
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if _, err := pluginpkg.ValidatePath(relative); err != nil {
			return err
		}
		files = append(files, pluginpkg.File{Path: relative, Size: info.Size()})
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	return contentDigest(ctx, root, files)
}
