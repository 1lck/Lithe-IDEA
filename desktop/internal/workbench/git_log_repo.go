package workbench

import (
	"context"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// This file keeps which repository the Git log walks (matrix id git-multi-repository-references).
// Core picks it from the repositories of the folder: the one the user picked while it is listed,
// otherwise the project's own, otherwise the first nested one, so a folder that is no repository
// itself walks its first nested repository. A click on a root of the Paths filter, or on a group or
// a reference of another repository in the reference pane, picks that repository: its history,
// commit details, comparisons, fetches and branch writes then act on it, and the log's header names
// it. The other repositories' references are read in nested_refs.go.

// logRepo is the nested repository the log walks, nil while it walks the project's own.
func (p *project) logRepo() *nestedRepo {
	repo, ok := p.nested.repo(p.nested.logRepo)
	if !ok {
		return nil
	}
	return repo
}

// logRepoID is Core's ID of the repository the log walks.
func (p *project) logRepoID() string {
	if repo := p.logRepo(); repo != nil {
		return repo.id
	}
	return p.ownID()
}

// logRoot is the root the log reads the repository it walks from: the project folder for the
// project's own repository, as the log always read it, and the nested repository's root otherwise.
func (p *project) logRoot() string {
	if repo := p.logRepo(); repo != nil {
		return repo.root
	}
	return p.root
}

// logRepositoryRoot is the root of the repository the log walks, where Git writes act.
func (p *project) logRepositoryRoot() string {
	if repo := p.logRepo(); repo != nil {
		return repo.root
	}
	return p.git.repositoryRoot(p.root)
}

// logBranchRepo is what the branch dialogs act on when the log opened them: the nested repository's
// root, or empty for the project's own repository, which the branch popup uses too.
func (p *project) logBranchRepo() string {
	if repo := p.logRepo(); repo != nil {
		return repo.root
	}
	return ""
}

// repositoryName is the name a repository shows, Core's name for it: the folder name of the
// project's own repository and the path in the project folder of a nested one. The empty ID and
// commitRepositoryID are the own one.
func (p *project) repositoryName(id string) string {
	if p.isOwnID(id) {
		if own, ok := p.nested.own(); ok {
			return own.Name
		}
		return filepath.Base(p.git.repositoryRoot(p.root))
	}
	if repo, ok := p.nested.repo(id); ok && repo.name != "" {
		return repo.name
	}
	return id
}

// selectLogRepo asks Core which repository the log walks now that the repositories were read
// again, and the ones its reference pane lists besides. When Core falls back from the one walked,
// or picks a nested one because the folder is no repository, the log walks that one from its start.
func (a *App) selectLogRepo(p *project) {
	n := &p.nested
	selection, ok := a.workspaceSelection(p, n.logRepo)
	if !ok {
		return
	}
	n.others = selection.Others
	active := selection.Active
	if _, nested := n.repo(active); !nested {
		active = ""
	}
	if active != n.logRepo {
		a.releaseLogCursor(p)
		n.logRepo = active
		p.log.reference, p.log.referenceLabel, p.log.refSelected = "", "", ""
		if p.log.started {
			a.loadLog(p)
			return
		}
	}
	// The reference pane lists the other repositories' references, so they are read again once the
	// repositories are.
	if p.log.started {
		a.loadNestedReferences(p)
	}
}

// setLogRepo makes the repository with ID the one the log walks, "" or the project's own ID for the
// project's own repository, and reads its log once. full, when given, is the reference the log then
// walks in it, short its name.
func (a *App) setLogRepo(p *project, id, full, short string) {
	if p.isOwnID(id) {
		id = ""
	}
	if p.nested.logRepo == id && full == "" {
		return
	}
	// The history walk belongs to the repository it was opened in, so it is closed before the switch.
	a.releaseLogCursor(p)
	p.nested.logRepo = id
	if selection, ok := a.workspaceSelection(p, id); ok {
		p.nested.others = selection.Others
	}
	l := &p.log
	l.reference, l.referenceLabel, l.refSelected = full, short, full
	a.loadLog(p)
}

// workspaceSelection asks Core which repository a view acts on, given the ID of the one the log
// walks, "" for the project's own. It reports false, after logging why, when Core cannot answer.
func (a *App) workspaceSelection(p *project, picked string) (core.WorkspaceRepositorySelection, bool) {
	discoverer, ok := a.kernel.(repositoryDiscoverer)
	if !ok {
		return core.WorkspaceRepositorySelection{}, false
	}
	n := &p.nested
	if picked == "" {
		if own, ok := n.own(); ok {
			picked = own.ID
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	selection, err := discoverer.SelectWorkspaceRepository(ctx, n.discovered, picked)
	if err != nil {
		a.backgroundFailed("workspace_repository_selection", err)
		return core.WorkspaceRepositorySelection{}, false
	}
	return selection, true
}

// releaseLogCursor closes the history walk of the log, when one is open, in the repository it
// was opened in.
func (a *App) releaseLogCursor(p *project) {
	if p.log.cursor != "" {
		a.closeLogCursor(p, p.log.cursor)
		p.log.cursor = ""
	}
}
