package marketplace

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// DeltaCore selects an exact-base patch and verifies the reconstruction.
type DeltaCore interface {
	SelectMarketplaceDelta(context.Context, core.MarketplaceDeltaRequest) (*core.MarketplaceDelta, error)
	ApplyMarketplaceDelta(context.Context, core.MarketplaceDelta, string, string, string) error
}

// DeltaBase describes an installed version with a matching marketplace approval.
type DeltaBase struct{ Version, SHA256 string }

// DownloadUpdate serves both interactive and automatic marketplace installers.
// The full download callback retains its normal resume and progress behavior.
func (s *Service) DownloadUpdate(ctx context.Context, kernel DeltaCore, cache ArchiveCache, downloader *ArchiveDownloader, plugin core.MarketplacePlugin, platform string, base DeltaBase, full func() (*DownloadedArchive, error), progress func(ArchiveProgress), report func(error)) (*DownloadedArchive, error) {
	if cache.directory == "" || kernel == nil || plugin.MarketplaceDeltasURL == "" {
		return full()
	}
	archive, err := s.tryDelta(ctx, kernel, cache, downloader, plugin, platform, base, progress)
	if ctx.Err() != nil {
		// The caller cancelled the transfer. A joined cleanup error still needs a log.
		if err != nil && !errors.Is(err, ctx.Err()) {
			report(err)
		}
		if archive != nil {
			if err := archive.Discard(); err != nil {
				report(err)
			}
		}
		return nil, ctx.Err()
	}
	if err != nil {
		report(err)
	}
	if archive == nil {
		if progress != nil && err != nil {
			progress(ArchiveProgress{Total: -1})
		}
		archive, err = full()
		if err != nil {
			return nil, err
		}
	}
	if err := cache.remember(ctx, plugin.Availability.SHA256, archive); err != nil && !errors.Is(err, context.Canceled) {
		report(err)
	}
	return archive, nil
}

func (s *Service) tryDelta(ctx context.Context, kernel DeltaCore, cache ArchiveCache, downloader *ArchiveDownloader, plugin core.MarketplacePlugin, platform string, base DeltaBase, progress func(ArchiveProgress)) (archive *DownloadedArchive, err error) {
	if plugin.MarketplaceDeltasURL == "" || base.SHA256 == "" || base.Version == plugin.Availability.Version {
		return nil, nil
	}
	path, err := cache.base(base.SHA256)
	if err != nil || path == "" {
		return nil, err
	}
	deltas, _, err := s.fetchJSON(ctx, plugin.MarketplaceDeltasURL)
	// log-exempt: 预期的缺失：市场可只提供完整包，不发布可选增量索引。
	if err == httpStatusError(http.StatusNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	patch, err := kernel.SelectMarketplaceDelta(ctx, core.MarketplaceDeltaRequest{
		Index: deltas, PluginID: plugin.ID, Platform: platform, Repository: plugin.Repository,
		FromVersion: base.Version, FromSHA256: base.SHA256,
		ToVersion: plugin.Availability.Version, ToSHA256: plugin.Availability.SHA256, ArchiveURL: plugin.Availability.DownloadURL,
	})
	if err != nil || patch == nil {
		return nil, err
	}
	transfer := *downloader
	transfer.maximumBytes = min(transfer.maximumBytes, patch.Size)
	data, partial, err := transfer.download(ctx, core.MarketplaceAvailability{
		Status: "available", DownloadURL: patch.DownloadURL, SHA256: patch.SHA256,
	}, nil, progress)
	if partial != nil {
		err = errors.Join(err, partial.remove())
	}
	if err != nil {
		return nil, err
	}
	defer func() {
		if cleanup := data.Discard(); cleanup != nil {
			err = errors.Join(err, cleanup)
		}
	}()
	staging, err := os.MkdirTemp(downloader.temporaryRoot, "lithe-plugin-delta-")
	if err != nil {
		return nil, err
	}
	output := filepath.Join(staging, "archive.zip")
	if err := kernel.ApplyMarketplaceDelta(ctx, *patch, path, data.Path(), output); err != nil {
		return nil, errors.Join(err, os.RemoveAll(staging))
	}
	return &DownloadedArchive{file: &archiveFile{directory: staging, path: output, owners: 1}}, nil
}
