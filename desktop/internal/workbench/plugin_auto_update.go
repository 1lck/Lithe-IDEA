package workbench

import (
	"context"
	"errors"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
)

const (
	pluginAutoFirstCheck    = 30 * time.Second
	pluginAutoInterval      = 24 * time.Hour
	pluginAutoFetchLimit    = 30 * time.Second
	pluginAutoDownloadLimit = 5 * time.Minute
	pluginAutoMaxSources    = 32
)

// pluginAutoUpdater is one window's auto-update scheduler, shared by its tabs.
// Only the workbench/window thread touches its state.
type pluginAutoUpdater struct {
	enabled, stopped, deferred, checking bool
	timer                                *time.Timer
	cancel                               context.CancelFunc
}

func (a *App) startPluginAutoUpdates() {
	if a.pluginAuto != nil && a.plugins != nil && a.pluginAuto.enabled {
		a.schedulePluginAutoUpdate(pluginAutoFirstCheck)
	}
}

func (a *App) setPluginAutoUpdates(enabled bool) {
	u := a.pluginAuto
	if u == nil || u.enabled == enabled {
		return
	}
	u.enabled = enabled
	for _, tab := range a.everyTab() {
		tab.settings.AutoUpdatePlugins = enabled
	}
	if enabled {
		a.schedulePluginAutoUpdate(pluginAutoFirstCheck)
	} else {
		a.stopPluginAutoTimer()
		if u.cancel != nil {
			u.cancel()
		}
	}
	a.saveSettings()
}

func (a *App) schedulePluginAutoUpdate(delay time.Duration) {
	u := a.pluginAuto
	if u == nil {
		return
	}
	a.stopPluginAutoTimer()
	if u.stopped || !u.enabled || a.plugins == nil {
		return
	}
	var timer *time.Timer
	timer = time.AfterFunc(delay, func() {
		a.post(func(a *App) {
			if u.timer == timer {
				u.timer = nil
				a.pluginAutoCheckDue()
			}
		})
	})
	u.timer = timer
}

func (a *App) stopPluginAutoTimer() {
	u := a.pluginAuto
	if u == nil {
		return
	}
	if u.timer != nil {
		u.timer.Stop()
		u.timer = nil
	}
	u.deferred = false
}

func (a *App) pluginAutoCheckDue() {
	u := a.pluginAuto
	if u == nil || u.stopped || !u.enabled || u.checking {
		return
	}
	if a.shownTab().windowInactive {
		u.deferred = true
		return
	}
	a.checkPluginAutoUpdates()
}

func (a *App) resumePluginAutoUpdates() {
	if u := a.pluginAuto; u != nil && u.deferred {
		u.deferred = false
		a.pluginAutoCheckDue()
	}
}

func (a *App) stopPluginAutoUpdates() {
	u := a.pluginAuto
	if u == nil {
		return
	}
	u.stopped = true
	a.stopPluginAutoTimer()
	if u.cancel != nil {
		u.cancel()
	}
}

// One window owns each check for a plugin root. Other windows wait for the
// shared interval, or retry after an owner was cancelled.
var pluginAutoRounds = struct {
	sync.Mutex
	roots map[string]*pluginAutoRound
}{roots: make(map[string]*pluginAutoRound)}

type pluginAutoRound struct {
	checking bool
	next     time.Time
}

func beginPluginAutoRound(root string, now time.Time) (func(bool), time.Duration) {
	pluginAutoRounds.Lock()
	defer pluginAutoRounds.Unlock()
	for key, round := range pluginAutoRounds.roots {
		if !round.checking && !round.next.After(now) {
			delete(pluginAutoRounds.roots, key)
		}
	}
	if round := pluginAutoRounds.roots[root]; round != nil {
		if round.checking {
			return nil, pluginAutoFirstCheck
		}
		return nil, round.next.Sub(now)
	}
	round := &pluginAutoRound{checking: true}
	pluginAutoRounds.roots[root] = round
	return func(cancelled bool) {
		pluginAutoRounds.Lock()
		defer pluginAutoRounds.Unlock()
		if cancelled {
			delete(pluginAutoRounds.roots, root)
			return
		}
		round.checking = false
		round.next = time.Now().Add(pluginAutoInterval)
	}, 0
}

func (a *App) checkPluginAutoUpdates() {
	u := a.pluginAuto
	if u == nil || u.checking || !u.enabled || u.stopped || a.plugins == nil {
		return
	}
	finish, delay := beginPluginAutoRound(a.plugins.Root, time.Now())
	if finish == nil {
		a.schedulePluginAutoUpdate(delay)
		return
	}
	ctx, cancel := context.WithCancel(a.operationContext(context.Background()))
	u.checking, u.cancel = true, cancel
	sources := a.marketplaceSources()
	platform := marketplaceHostPlatform()
	capabilities := pluginhost.Declared().Clone()
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		count, err := a.performPluginAutoUpdates(ctx, sources, platform, capabilities)
		finish(ctx.Err() != nil && count == 0)
		return func(a *App) {
			u.checking, u.cancel = false, nil
			if err != nil && !errors.Is(err, context.Canceled) {
				a.backgroundFailed("plugin_auto_update", err)
			}
			if count > 0 {
				for _, tab := range a.everyTab() {
					tab.refreshPluginState()
				}
				a.shownTab().notifySuccess(i18n.SharedFormat(a.language(), "desktop.marketplace.autoUpdated", map[string]string{
					"count": strconv.Itoa(count),
				}))
			}
			if u.enabled && !u.stopped {
				a.schedulePluginAutoUpdate(pluginAutoInterval)
			}
		}
	})
}

func (a *App) marketplaceSources() []PluginRecommendationSource {
	sources := []PluginRecommendationSource{
		{Input: marketplace.CommunityRepositoryURL, Kind: core.MarketplaceThirdParty},
		{Input: marketplace.OfficialIndexURL, Kind: core.MarketplaceOfficial},
	}
	for _, url := range a.settings.MarketplaceSources {
		if len(sources) >= pluginAutoMaxSources {
			break
		}
		sources = append(sources, PluginRecommendationSource{Input: url, Kind: core.MarketplaceThirdParty})
	}
	return sources
}

func marketplaceHostPlatform() string {
	arch := runtime.GOARCH
	if arch == "amd64" {
		arch = "x64"
	}
	return runtime.GOOS + "-" + arch
}

// autoUpdateCandidates uses only Core-validated availability and release order.
// Its source must be exactly the index the user originally approved.
func autoUpdateCandidates(entries []pluginmanager.Entry, approvals map[string]plugintrust.Record, snapshot marketplace.Snapshot) []core.MarketplacePlugin {
	installed := make(map[string]pluginmanager.Entry, len(entries))
	for _, entry := range entries {
		if entry.Enabled {
			installed[entry.Installed.ID] = entry
		}
	}
	var candidates []core.MarketplacePlugin
	for _, plugin := range snapshot.Index.Plugins {
		entry, ok := installed[plugin.ID]
		approval, approved := approvals[plugin.ID]
		if !ok || !approved || approval.Source != plugintrust.Marketplace ||
			approval.MarketplaceIndexURL == "" ||
			approval.MarketplaceIndexURL != snapshot.Source.IndexURL ||
			!marketplace.NewerOffered(plugin, entry.Installed.Version) {
			continue
		}
		candidates = append(candidates, plugin)
	}
	return candidates
}

// approvedPluginAutoSource avoids contacting unrelated indexes just because
// the user enabled automatic updates for a different plugin.
func approvedPluginAutoSource(indexURL string, approvals map[string]plugintrust.Record) bool {
	if indexURL == "" {
		return false
	}
	for _, record := range approvals {
		if record.MarketplaceIndexURL == indexURL {
			return true
		}
	}
	return false
}

func (a *App) performPluginAutoUpdates(ctx context.Context, sources []PluginRecommendationSource, platform string, capabilities map[string][]int) (int, error) {
	entries, err := a.plugins.CurrentInstalled(ctx)
	if err != nil {
		return 0, err
	}
	approvals := make(map[string]plugintrust.Record, len(entries))
	for _, entry := range entries {
		if !entry.Enabled {
			continue
		}
		record, found, readErr := a.plugins.Manager.Approval(entry.Installed.ID, entry.Installed.Version)
		if readErr != nil {
			return 0, readErr
		}
		if found && record.Source == plugintrust.Marketplace && record.MarketplaceIndexURL != "" {
			approvals[entry.Installed.ID] = record
		}
	}
	if len(approvals) == 0 {
		// log-exempt: 用户尚未通过插件市场确认安装源，不自动向网络查询。
		return 0, nil
	}
	service := a.pinnedMarketplace()
	downloader := marketplace.NewArchiveDownloader(nil)
	attempted := make(map[string]bool)
	triedOrigins := make(map[string]bool)
	var failures []error
	updated := 0
	for _, source := range sources {
		if err := ctx.Err(); err != nil {
			return updated, err
		}
		// Resolve sources locally before any HTTP request: only an index the
		// user already installed from can trigger an automatic fetch.
		origin, resolveErr := a.kernel.ResolveMarketplaceSource(ctx, source.Input)
		if resolveErr != nil {
			failures = append(failures, resolveErr)
			continue
		}
		if triedOrigins[origin.IndexURL] || !approvedPluginAutoSource(origin.IndexURL, approvals) {
			continue
		}
		triedOrigins[origin.IndexURL] = true
		fetchCtx, end := context.WithTimeout(ctx, pluginAutoFetchLimit)
		snapshot, fetchErr := service.Fetch(fetchCtx, source.Input, source.Kind, platform, capabilities)
		end()
		if fetchErr != nil {
			failures = append(failures, fetchErr)
			continue
		}
		for _, plugin := range autoUpdateCandidates(entries, approvals, snapshot) {
			if attempted[plugin.ID] {
				continue
			}
			attempted[plugin.ID] = true
			applied, err := a.applyPluginAutoUpdate(ctx, downloader, plugin, approvals[plugin.ID])
			if ctx.Err() != nil {
				return updated, ctx.Err()
			}
			if err != nil {
				failures = append(failures, err)
			} else if applied {
				updated++
			}
		}
	}
	return updated, errors.Join(failures...)
}

// applyPluginAutoUpdate prepares the verified archive, compares the full grant
// set with an existing approved version, and installs without interrupting live
// plugin sessions. Permission changes still need manual review.
func (a *App) applyPluginAutoUpdate(ctx context.Context, downloader *marketplace.ArchiveDownloader, plugin core.MarketplacePlugin, previous plugintrust.Record) (bool, error) {
	pending, err := a.plugins.Installer.HasPending(a.plugins.Root, plugin.ID)
	if err != nil || pending {
		return false, err
	}
	downloadCtx, cancel := context.WithTimeout(ctx, pluginAutoDownloadLimit)
	archive, err := a.downloadMarketplacePlugin(downloadCtx, downloader, plugin, previous, func() (*marketplace.DownloadedArchive, error) {
		return downloader.Download(downloadCtx, plugin.Availability)
	}, nil)
	cancel()
	if err != nil {
		return false, err
	}
	defer func() { a.recordPluginInstallCleanup(ctx, archive.Discard()) }()
	plan, err := a.preparePlugin(ctx, plugininstall.Request{
		ArchivePath: archive.Path(), Root: a.plugins.Root, Source: plugintrust.Marketplace,
		ArchiveSHA256:       plugin.Availability.SHA256,
		MarketplaceIndexURL: plugin.MarketplaceIndexURL,
		ExpectedID:          plugin.ID, ExpectedVersion: plugin.Availability.Version,
	})
	if err != nil {
		return false, err
	}
	defer func() { a.recordPluginInstallCleanup(ctx, a.plugins.Installer.Discard(plan)) }()
	if !plugintrust.MayAutoUpdate(previous, true, plugin.MarketplaceIndexURL, plan.Review) {
		// log-exempt: 新版本的权限/程序声明不受旧版审批覆盖，需用户手动确认。
		return false, nil
	}
	work, finish, err := a.plugins.BeginRuntimeInstallation(ctx, plan.ID)
	if err != nil {
		return false, err
	}
	defer func() { a.recordPluginInstallCleanup(work, finish()) }()
	// A manual change may occur while bytes are downloading; recheck the current
	// plugin and the approval before publishing, under the runtime coordinator.
	current, err := a.plugins.CurrentInstalled(work)
	if err != nil {
		return false, err
	}
	valid := false
	for _, entry := range current {
		if entry.Installed.ID == previous.PluginID && entry.Installed.Version == previous.Version && entry.Enabled {
			record, found, readErr := a.plugins.Manager.Approval(previous.PluginID, previous.Version)
			if readErr != nil {
				return false, readErr
			}
			valid = found && record.ArchiveSHA256 == previous.ArchiveSHA256 &&
				plugintrust.MayAutoUpdate(record, found, plugin.MarketplaceIndexURL, plan.Review)
			break
		}
	}
	if !valid {
		// log-exempt: 用户已更改本机插件状态，此次自动更新放弃写入。
		return false, nil
	}
	if err := work.Err(); err != nil {
		return false, err
	}
	err = a.plugins.Installer.StageAutomatic(plan, previous)
	return err == nil, err
}
