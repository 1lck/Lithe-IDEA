package workbench

import (
	"context"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This file adds the repositories nested in the project folder to a commit of the project's
// staged changes (matrix id git-workspace-staged-commit). Core discovers them; each one with
// staged changes is planned and committed with the project's repository, and each keeps its
// own result. The request of a retry and the request of a ChangeList scope keep the repositories
// they were planned with, so only a first plan without a scope takes them.

// repositoryDiscoverer is the part of the kernel the nested repositories use. Core's client
// implements it.
type repositoryDiscoverer interface {
	DiscoverWorkspaceRepositories(ctx context.Context, root string) ([]core.WorkspaceRepository, error)
}

// includeNestedRepositories adds the repositories below the project folder, other than the
// project's own, to request. It keeps request unchanged when the commit is a retry, is held to
// a ChangeList scope, or when Core cannot discover the repositories; the project's repository
// is committed in every case.
func includeNestedRepositories(ctx context.Context, kernel Kernel, p *project, t commitTarget, request core.WorkspaceCommitRequest) core.WorkspaceCommitRequest {
	discoverer, ok := kernel.(repositoryDiscoverer)
	if !ok || !t.console || t.scope != nil || request.Previous != nil {
		return request
	}
	repos, err := discoverer.DiscoverWorkspaceRepositories(ctx, p.root)
	if err != nil {
		return request
	}
	own := filepath.Clean(t.root)
	for _, repo := range repos {
		path := filepath.Clean(filepath.FromSlash(repo.Path))
		if path == own {
			continue
		}
		rel, err := filepath.Rel(p.root, path)
		if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			continue
		}
		request.Repositories = append(request.Repositories, core.WorkspaceCommitRepository{
			ID:   filepath.ToSlash(rel),
			Root: path,
		})
	}
	return request
}
