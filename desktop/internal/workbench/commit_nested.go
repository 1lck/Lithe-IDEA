package workbench

import "github.com/1lck/Lithe-IDEA/desktop/internal/core"

// This file adds the repositories nested in the project folder to a commit of the project's
// staged changes (matrix id git-workspace-staged-commit). The window hands Core's discovery list
// back with the request, and Core binds the nested repositories to the plan: every one on a first
// plan, none when a ChangeList scope holds the commit to the project's repository, and on a retry
// only the ones its failed attempt planned, so the continued plan matches the one the attempt
// recorded. A folder that is no repository itself commits its nested repositories alone.

// withWorkspaceRepositories hands the repositories of the project folder to request, for a commit
// of the Commit tool window. The project's own checkouts other than that window commit their
// repository alone.
func (p *project) withWorkspaceRepositories(t commitTarget, request core.WorkspaceCommitRequest) core.WorkspaceCommitRequest {
	if !t.console || len(p.nested.discovered) == 0 {
		return request
	}
	request.WorkspaceRepositories = append([]core.WorkspaceRepository(nil), p.nested.discovered...)
	if !p.git.isRepository() {
		// The project folder is no repository, so only the nested ones Core binds are planned.
		request.Repositories = nil
	}
	return request
}
