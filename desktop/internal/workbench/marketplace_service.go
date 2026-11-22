package workbench

import (
	"context"
	"errors"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/githubapi"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// pinnedMarketplace is the marketplace service of the reads a user waits on: the plugin page
// and the automatic updates. It reads a GitHub-hosted index at the newest commit, which a
// one-request anonymous lookup finds, so a release that has just reached the store shows at
// once rather than after raw.githubusercontent.com's branch cache expires. A failed lookup or
// pinned read is logged and the canonical index read instead.
func (a *App) pinnedMarketplace() *marketplace.Service {
	service := marketplace.New(a.kernel, nil)
	client := a.githubAPI()
	if client == nil {
		return service
	}
	return service.PinToLatestCommit(func(ctx context.Context, repository core.GitHubRepo, ref string) (string, error) {
		// latestCommit needs no account: Core plans it without the token, so none is passed.
		raw, err := client.Do(ctx, core.GitHubRequest{Operation: "latestCommit", Repository: &repository, Ref: ref}, "")
		if err != nil {
			return "", err
		}
		return githubapi.DecodeLatestCommit(raw)
	}, func(ctx context.Context, err error) {
		a.backgroundFailedIn(ctx, "plugin_marketplace_pin", err)
	})
}

// pluginReleases lists the releases of a plugin's source repository for the Installed tab's
// changelog, newest first. A repository GitHub does not host is not an error: supported is
// false and the tab links to the repository instead. The request is anonymous, like the index
// pin, so it works signed out.
func (a *App) pluginReleases(ctx context.Context, repository string) ([]settingswindow.PluginRelease, bool, error) {
	kernel, ok := a.kernel.(interface {
		GitHubParseRemote(ctx context.Context, remoteURL string) (core.GitHubRepo, error)
	})
	client := a.githubAPI()
	if !ok || client == nil {
		return nil, false, nil
	}
	repo, err := kernel.GitHubParseRemote(ctx, repository)
	var refused *core.Error
	// log-exempt: 预期的缺失：Core 认不出的地址不是 GitHub 仓库，没有可读的 Releases，页面改为给出仓库链接。
	if errors.As(err, &refused) && refused.Code == core.CodeInvalidRequest {
		return nil, false, nil
	}
	if err != nil {
		return nil, true, err
	}
	raw, err := client.Do(ctx, core.GitHubRequest{Operation: "listReleases", Repository: &repo}, "")
	if err != nil {
		return nil, true, err
	}
	items, err := githubapi.DecodeReleases(raw)
	if err != nil {
		return nil, true, err
	}
	releases := make([]settingswindow.PluginRelease, len(items))
	for i, item := range items {
		// An unreadable time leaves the date out; the release is still listed.
		published, _ := time.Parse(time.RFC3339, item.PublishedAt)
		releases[i] = settingswindow.PluginRelease{
			Tag: item.TagName, Name: item.Name, Notes: item.Body,
			Published: published, Prerelease: item.Prerelease, URL: item.URL,
		}
	}
	return releases, true, nil
}
