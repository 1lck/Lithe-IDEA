package workbench

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/vivaui/viva/ui"
)

const (
	pluginRecommendationScanDepth    = 3
	pluginRecommendationScanLimit    = 4000
	pluginRecommendationFetchTimeout = 15 * time.Second
	pluginRecommendationCacheTTL     = 15 * time.Minute
)

var ignoredRecommendationDirs = map[string]struct{}{
	".cache":       {},
	".git":         {},
	".gradle":      {},
	".hg":          {},
	".idea":        {},
	".lithe":       {},
	".next":        {},
	".nuxt":        {},
	".svn":         {},
	".venv":        {},
	".vscode":      {},
	"__pycache__":  {},
	"bin":          {},
	"build":        {},
	"dist":         {},
	"node_modules": {},
	"obj":          {},
	"out":          {},
	"target":       {},
	"vendor":       {},
	"venv":         {},
}

// PluginRecommendationSource identifies one marketplace source URL and policy
// tier checked by marketplace background tasks.
type PluginRecommendationSource struct {
	Input string
	Kind  core.MarketplaceSourceKind
}

type pluginRecommendationState struct {
	mu            sync.Mutex
	cached        []core.MarketplaceRecommendationCatalog
	cachedSources string
	cachedAt      time.Time
	hasCache      bool
	notifiedRoots map[string]string
}

func newPluginRecommendationState() *pluginRecommendationState {
	return &pluginRecommendationState{
		notifiedRoots: map[string]string{},
	}
}

func (s *pluginRecommendationState) cachedFor(sourcesKey string, now time.Time) ([]core.MarketplaceRecommendationCatalog, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.hasCache || s.cachedSources != sourcesKey || now.Sub(s.cachedAt) >= pluginRecommendationCacheTTL {
		return nil, false
	}
	out := make([]core.MarketplaceRecommendationCatalog, len(s.cached))
	copy(out, s.cached)
	return out, true
}

func (s *pluginRecommendationState) storeCache(sourcesKey string, now time.Time, catalogs []core.MarketplaceRecommendationCatalog) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cachedSources = sourcesKey
	s.cachedAt = now
	s.hasCache = true
	s.cached = make([]core.MarketplaceRecommendationCatalog, len(catalogs))
	copy(s.cached, catalogs)
}

func (s *pluginRecommendationState) markNotified(root string, ids []string) bool {
	key := strings.Join(ids, ",")
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.notifiedRoots[root] == key {
		return false
	}
	s.notifiedRoots[root] = key
	return true
}

func (s *pluginRecommendationState) clearRoot(root string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.notifiedRoots, root)
}

func (a *App) checkPluginRecommendations(p *project) {
	if p == nil || a.documentOnly || a.disableRecommendations || a.kernel == nil || a.pluginRecommendations == nil {
		return
	}
	root := p.root
	sources := a.marketplaceSources()
	platform := marketplaceHostPlatform()
	capabilities := pluginhost.Declared().Clone()
	dismissed := append([]string(nil), a.settings.DismissedPluginRecommendations...)
	fetcher := a.recommendationFetcher
	pluginsService := a.plugins
	nowFn := a.now
	state := a.pluginRecommendations
	kernel := a.kernel

	a.background(p, 0, func(ctx context.Context) func(*App) {
		files, scanWarnings, scanErr := scanWorkspaceRecommendationFiles(ctx, root, pluginRecommendationScanDepth, pluginRecommendationScanLimit)
		if scanErr != nil {
			return func(a *App) {
				if !errors.Is(scanErr, context.Canceled) {
					a.backgroundFailed("plugin_recommendations", scanErr)
				}
			}
		}
		if len(scanWarnings) > 0 {
			warningErr := errors.Join(scanWarnings...)
			// Best-effort diagnostics for partially unreadable subdirs without blocking valid matches.
			a.backgroundFailedIn(ctx, "plugin_recommendations_scan", warningErr)
		}
		if len(files) == 0 || ctx.Err() != nil {
			return nil
		}

		var installedIDs []string
		if pluginsService != nil {
			entries, err := pluginsService.CurrentInstalled(ctx)
			if err != nil {
				return func(a *App) {
					if !errors.Is(err, context.Canceled) {
						a.backgroundFailed("plugin_recommendations", err)
					}
				}
			}
			installedIDs = make([]string, 0, len(entries))
			for _, entry := range entries {
				if entry.Installed.ID != "" {
					installedIDs = append(installedIDs, entry.Installed.ID)
				}
			}
		}

		catalogs, fetchErr := loadRecommendationCatalogs(ctx, kernel, state, sources, nowFn(), fetcher)
		if len(catalogs) == 0 {
			if fetchErr == nil || errors.Is(fetchErr, context.Canceled) {
				return nil
			}
			return func(a *App) {
				a.backgroundFailed("plugin_recommendations", fetchErr)
			}
		}

		result, recErr := kernel.RecommendMarketplacePlugins(ctx, platform, files, catalogs, capabilities, installedIDs, dismissed)
		return func(a *App) {
			if fetchErr != nil && !errors.Is(fetchErr, context.Canceled) {
				a.backgroundFailed("plugin_recommendations", fetchErr)
			}
			if recErr != nil {
				if !errors.Is(recErr, context.Canceled) {
					a.backgroundFailed("plugin_recommendations", recErr)
				}
				return
			}
			a.notifyPluginRecommendations(root, result.Plugins)
		}
	})
}

func loadRecommendationCatalogs(
	ctx context.Context,
	kernel Kernel,
	state *pluginRecommendationState,
	sources []PluginRecommendationSource,
	now time.Time,
	fetcher func(context.Context, []PluginRecommendationSource) ([]core.MarketplaceRecommendationCatalog, error),
) ([]core.MarketplaceRecommendationCatalog, error) {
	if fetcher != nil {
		return fetcher(ctx, sources)
	}
	sourcesKey := recommendationSourcesKey(sources)
	if cached, ok := state.cachedFor(sourcesKey, now); ok {
		return cached, nil
	}
	service := marketplace.New(kernel, nil)
	var catalogs []core.MarketplaceRecommendationCatalog
	var failures []error
	for _, src := range sources {
		if ctx.Err() != nil {
			return catalogs, ctx.Err()
		}
		fetchCtx, cancel := context.WithTimeout(ctx, pluginRecommendationFetchTimeout)
		bundle, ok, err := service.FetchRecommendationBundle(fetchCtx, src.Input, src.Kind)
		cancel()
		if err != nil {
			failures = append(failures, err)
			continue
		}
		if ok {
			catalogs = append(catalogs, core.MarketplaceRecommendationCatalog{
				Index:           bundle.Index,
				SourceKind:      bundle.SourceKind,
				IndexURL:        bundle.Source.IndexURL,
				Recommendations: bundle.Recommendations,
			})
		}
	}
	if len(failures) == 0 {
		state.storeCache(sourcesKey, now, catalogs)
	}
	return catalogs, errors.Join(failures...)
}

func recommendationSourcesKey(sources []PluginRecommendationSource) string {
	var b strings.Builder
	for i, src := range sources {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(string(src.Kind))
		b.WriteByte(':')
		b.WriteString(src.Input)
	}
	return b.String()
}

// scanWorkspaceRecommendationFiles runs a bounded breadth-first scan of workspace files up to
// maxDepth directory levels and maxEntries filesystem entries without following directory symlinks.
func scanWorkspaceRecommendationFiles(ctx context.Context, root string, maxDepth, maxEntries int) ([]string, []error, error) {
	type queueItem struct {
		abs   string
		rel   string
		depth int
	}
	if maxDepth < 0 || maxEntries <= 0 {
		return nil, nil, nil
	}
	queue := []queueItem{{abs: root, rel: "", depth: 0}}
	visited := 0
	var files []string
	var warnings []error
	for len(queue) > 0 && visited < maxEntries {
		if err := ctx.Err(); err != nil {
			return nil, nil, err
		}
		item := queue[0]
		queue = queue[1:]
		entries, err := os.ReadDir(item.abs)
		if err != nil {
			if item.depth == 0 {
				return nil, nil, err
			}
			if errors.Is(err, fs.ErrNotExist) {
				// log-exempt: 预期的缺失：并发扫描期间子目录已被删除或移动。
				continue
			}
			warnings = append(warnings, err)
			continue
		}
		for _, entry := range entries {
			if visited >= maxEntries {
				break
			}
			visited++
			name := entry.Name()
			if entry.Type()&os.ModeSymlink != 0 {
				continue
			}
			rel := name
			if item.rel != "" {
				rel = item.rel + "/" + name
			}
			if entry.IsDir() {
				if _, ignored := ignoredRecommendationDirs[name]; ignored {
					continue
				}
				if item.depth < maxDepth {
					queue = append(queue, queueItem{
						abs:   filepath.Join(item.abs, name),
						rel:   rel,
						depth: item.depth + 1,
					})
				}
				continue
			}
			files = append(files, rel)
		}
	}
	return files, warnings, nil
}

func (a *App) notifyPluginRecommendations(root string, recommendations []core.MarketplaceRecommendation) {
	if len(recommendations) == 0 {
		return
	}
	dismissed := make(map[string]struct{}, len(a.settings.DismissedPluginRecommendations))
	for _, id := range a.settings.DismissedPluginRecommendations {
		dismissed[id] = struct{}{}
	}
	filtered := make([]core.MarketplaceRecommendation, 0, len(recommendations))
	matchedIDs := make([]string, 0, len(recommendations))
	for _, rec := range recommendations {
		if _, skip := dismissed[rec.Plugin.ID]; skip {
			continue
		}
		filtered = append(filtered, rec)
		matchedIDs = append(matchedIDs, rec.Plugin.ID)
	}
	if len(filtered) == 0 {
		return
	}
	sortedIDs := append([]string(nil), matchedIDs...)
	sort.Strings(sortedIDs)
	if !a.pluginRecommendations.markNotified(root, sortedIDs) {
		return
	}

	language := a.language()
	names := make([]string, 0, len(filtered))
	for _, rec := range filtered {
		name := rec.Plugin.Name
		if name == "" {
			name = rec.Plugin.ID
		}
		names = append(names, name)
	}
	separator := ", "
	if strings.HasPrefix(language.Code(), "zh") {
		separator = "、"
	}
	title := i18n.Shared(language, "desktop.marketplace.recommendedTitle")
	detail := i18n.SharedFormat(language, "desktop.marketplace.recommendedPlugins", map[string]string{
		"plugins": strings.Join(names, separator),
	})
	primaryLabel := i18n.Shared(language, "desktop.marketplace.recommendedAction")
	secondaryLabel := i18n.Shared(language, "desktop.marketplace.recommendedDismiss")
	query := ""
	if len(names) == 1 {
		query = names[0]
	}
	a.shownTab().notifyActions(
		title,
		detail,
		ui.ToastInfo,
		primaryLabel,
		func(target *App) {
			target.openPluginSettingsSearch(surfaceNotification, query)
		},
		secondaryLabel,
		func(target *App) {
			target.dismissPluginRecommendations(root, matchedIDs, title, detail)
		},
	)
}

func (a *App) dismissPluginRecommendations(root string, ids []string, title, detail string) {
	if len(ids) == 0 {
		return
	}
	seen := make(map[string]struct{}, len(a.settings.DismissedPluginRecommendations)+len(ids))
	for _, existing := range a.settings.DismissedPluginRecommendations {
		seen[existing] = struct{}{}
	}
	for _, id := range ids {
		if id != "" {
			seen[id] = struct{}{}
		}
	}
	merged := make([]string, 0, len(seen))
	for id := range seen {
		merged = append(merged, id)
	}
	slices.Sort(merged)
	for _, tab := range a.everyTab() {
		tab.settings.DismissedPluginRecommendations = append([]string(nil), merged...)
	}
	a.saveSettings()
	if a.pluginRecommendations != nil && root != "" {
		a.pluginRecommendations.clearRoot(root)
	}
	for _, entry := range a.notifications.list {
		if entry.text == title && entry.detail == detail && entry.kind == ui.ToastInfo {
			a.overlay.toaster.Close(entry.toast)
		}
	}
}
