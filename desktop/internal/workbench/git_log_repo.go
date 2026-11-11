package workbench

import "path/filepath"

// This file keeps which repository the Git log walks (matrix id git-multi-repository-references).
// The log starts on the project's own repository. A click on a group or a reference of a nested
// repository in the reference pane makes that repository the one the log walks: its history,
// commit details, comparisons, fetches and branch writes then act on it, and the log's header
// names it and offers the way back. A nested repository that leaves the workspace falls back to the
// project's own (nested_repos.go). The nested repositories' references are read in nested_refs.go.

// logRepo is the nested repository the log walks, nil while it walks the project's own.
func (p *project) logRepo() *nestedRepo {
	repo, ok := p.nested.repo(p.nested.logRepo)
	if !ok {
		return nil
	}
	return repo
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

// repositoryName is the name a repository's group shows: the folder name of the project's own
// repository, or the nested repository's path in the project folder. The empty ID is the own one.
func (p *project) repositoryName(id string) string {
	if id == "" || id == commitRepositoryID {
		return filepath.Base(p.git.repositoryRoot(p.root))
	}
	return id
}

// referenceGroups are the repositories the reference pane lists below its own sections: every
// nested repository but the one the log walks. While a nested repository is walked, the project's
// own repository is listed too, read-only, so the user can walk back to it by a click.
func (p *project) referenceGroups() []nestedRepo {
	active := p.nested.logRepo
	var groups []nestedRepo
	if active != "" {
		groups = append(groups, nestedRepo{id: commitRepositoryID, root: p.root})
	}
	for _, repo := range p.nested.repos {
		if repo.id != active {
			groups = append(groups, repo)
		}
	}
	return groups
}

// setLogRepo makes the repository with ID the one the log walks, "" or the project's own ID for the
// project's own repository, and reads its log once. full, when given, is the reference the log then
// walks in it, short its name.
func (a *App) setLogRepo(p *project, id, full, short string) {
	if id == commitRepositoryID {
		id = ""
	}
	if p.nested.logRepo == id && full == "" {
		return
	}
	// The history walk belongs to the repository it was opened in, so it is closed before the switch.
	a.releaseLogCursor(p)
	p.nested.logRepo = id
	l := &p.log
	l.reference, l.referenceLabel, l.refSelected = full, short, full
	a.loadLog(p)
}

// releaseLogCursor closes the history walk of the log, when one is open, in the repository it
// was opened in.
func (a *App) releaseLogCursor(p *project) {
	if p.log.cursor != "" {
		a.closeLogCursor(p, p.log.cursor)
		p.log.cursor = ""
	}
}

// logFallsBack reports that the log walked a nested repository that is no longer in the workspace,
// and makes the project's own repository the one it walks again. It reports whether it did.
func (a *App) logFallsBack(p *project) bool {
	if p.nested.logRepo == "" || p.logRepo() != nil {
		return false
	}
	a.releaseLogCursor(p)
	p.nested.logRepo = ""
	p.log.reference, p.log.referenceLabel, p.log.refSelected = "", "", ""
	return true
}

// workspaceRepositoryIDs are the IDs of every repository of the workspace, the project's own first
// and the nested ones in discovery order, for the color assignments. Core's list is unfiltered, so
// worktrees stay in it; the views drop the hidden ones.
func (p *project) workspaceRepositoryIDs() []string {
	ids := make([]string, 0, len(p.nested.repos)+1)
	ids = append(ids, commitRepositoryID)
	for _, repo := range p.nested.repos {
		ids = append(ids, repo.id)
	}
	return ids
}
