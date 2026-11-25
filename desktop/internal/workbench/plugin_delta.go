package workbench

import (
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

func (a *App) installedMarketplaceApproval(ctx context.Context, id string) (plugintrust.Record, error) {
	entries, err := a.plugins.CurrentInstalled(ctx)
	if err != nil {
		return plugintrust.Record{}, err
	}
	for _, entry := range entries {
		if entry.Installed.ID == id {
			record, _, err := a.plugins.Manager.Approval(id, entry.Installed.Version)
			return record, err
		}
	}
	return plugintrust.Record{}, nil
}

func (a *App) downloadMarketplacePlugin(ctx context.Context, downloader *marketplace.ArchiveDownloader, plugin core.MarketplacePlugin, previous plugintrust.Record, full func() (*marketplace.DownloadedArchive, error), progress func(marketplace.ArchiveProgress)) (*marketplace.DownloadedArchive, error) {
	var base marketplace.DeltaBase
	if previous.Source == plugintrust.Marketplace && previous.MarketplaceIndexURL != "" &&
		previous.MarketplaceIndexURL == plugin.MarketplaceIndexURL {
		base = marketplace.DeltaBase{Version: previous.Version, SHA256: previous.ArchiveSHA256}
	}
	kernel, _ := a.kernel.(marketplace.DeltaCore)
	return marketplace.New(a.kernel, downloader.HTTPClient()).DownloadUpdate(ctx, kernel, a.pluginArchiveCache, downloader, plugin,
		marketplaceHostPlatform(), base, full, progress, func(err error) {
			a.backgroundFailedIn(ctx, "plugin_delta", err)
		})
}

// startPluginInventory runs pending verification off the window thread. The
// startup project and ordinary plugin discovery use the settled inventory.
func (a *App) startPluginInventory() {
	service := a.plugins
	if service == nil {
		a.openStartupDocuments()
		return
	}
	a.pluginStartupCancel = a.background(nil, pluginPrepareTimeout, func(ctx context.Context) func(*App) {
		err := service.ActivatePendingUpdates(ctx)
		return func(a *App) {
			a.pluginStartupCancel = nil
			if err != nil && !errors.Is(err, context.Canceled) {
				a.backgroundFailed("plugin_activate_pending", err)
			}
			a.reloadPluginLanguages()
			a.startPluginAutoUpdates()
			a.openStartupDocuments()
		}
	})
}

func (a *App) openStartupDocuments() {
	if path := a.startupPath; path != "" {
		a.startupPath = ""
		a.post(func(a *App) { a.openProject(path) })
	}
	if path := a.startupFile; path != "" {
		a.startupFile = ""
		a.post(func(a *App) { a.openStandaloneFile(path) })
	}
}
