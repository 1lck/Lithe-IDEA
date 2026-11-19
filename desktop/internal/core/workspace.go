package core

import "context"

// WorkspaceRepositoryRole is how a discovered repository relates to the opened folder.
type WorkspaceRepositoryRole string

const (
	// RepositoryWorkspace is the repository that contains the opened folder. Discovery lists
	// at most one, first.
	RepositoryWorkspace WorkspaceRepositoryRole = "workspace"
	// RepositoryNested is a repository below the opened folder.
	RepositoryNested WorkspaceRepositoryRole = "nested"
)

// WorkspaceRepository is a Git root discovered by Core. Path is an absolute
// path and can be outside the opened folder when the folder is inside a
// containing repository. Core uses forward slashes on Windows too; callers
// that compare native paths must normalize separators. Ordering belongs to Core.
// The window hands entries back to Core unchanged, so every field is Core's.
type WorkspaceRepository struct {
	Path string `json:"path"`
	// ID is the root relative to the opened folder with "/" separators: "." for the folder
	// itself, "a/b" below it and ".." segments for a containing repository. It names the
	// repository in commit plans, color assignments and selections.
	ID string `json:"id"`
	// Name is what views show: the folder name of the workspace repository, the ID of a
	// nested one.
	Name string                  `json:"name"`
	Role WorkspaceRepositoryRole `json:"role"`
}

// WorkspaceRepositorySelection is the repository a multi-repository view acts on.
type WorkspaceRepositorySelection struct {
	// Active is the ID the view acts on, empty when the workspace has no repository.
	Active string
	// FellBack reports that the repository the view picked is no longer listed, so the view
	// drops what belonged to it.
	FellBack bool
	// Others are every other ID in discovery order: the repositories the view lists to
	// switch to.
	Others []string
	// Chosen are the repositories a view that walks several acts on, in discovery order, the
	// first of them Active; set only by SelectWorkspaceRepositories.
	Chosen []string
}

// SelectWorkspaceRepositories asks Core which repositories a view that walks several acts on,
// given the discovery list and the IDs the view chose before. Core keeps the chosen ones still
// listed and falls back to one repository when none is.
func (c *Client) SelectWorkspaceRepositories(ctx context.Context, repositories []WorkspaceRepository, chosen []string) (WorkspaceRepositorySelection, error) {
	request := struct {
		Repositories []WorkspaceRepository `json:"repositories"`
		Chosen       []string              `json:"chosen"`
	}{nonNil(repositories), nonNil(chosen)}
	var response struct {
		Active   *string  `json:"active"`
		FellBack bool     `json:"fellBack"`
		Others   []string `json:"others"`
		Chosen   []string `json:"chosen"`
	}
	if err := c.Execute(ctx, "git.workspaceRepositorySelection", request, &response); err != nil {
		return WorkspaceRepositorySelection{}, err
	}
	selection := WorkspaceRepositorySelection{FellBack: response.FellBack, Others: response.Others, Chosen: response.Chosen}
	if response.Active != nil {
		selection.Active = *response.Active
	}
	return selection, nil
}

// WorkspaceHistory is the history of one repository a log walks with others, as far as it is
// loaded.
type WorkspaceHistory struct {
	ID      string                   `json:"id"`
	Commits []WorkspaceHistoryCommit `json:"commits"`
	// Complete says Commits hold the whole walk, so no page is left to load.
	Complete bool `json:"complete"`
}

// WorkspaceHistoryCommit is one loaded commit as the merge places it.
type WorkspaceHistoryCommit struct {
	Hash         string   `json:"hash"`
	ParentHashes []string `json:"parentHashes"`
	// Timestamp is the commit's Unix seconds, nil when Git reported no valid date.
	Timestamp *int64 `json:"timestamp,omitempty"`
}

// WorkspaceHistoryEntry is one row of the merged list: the commit at Index of the history at
// Repository in the request, and its key and its parents' keys in the merged graph.
type WorkspaceHistoryEntry struct {
	Repository int      `json:"repository"`
	Index      int      `json:"index"`
	Key        string   `json:"key"`
	ParentKeys []string `json:"parentKeys"`
}

// WorkspaceHistoryMerge is Core's merged list, newest first, and the indices of the histories
// whose next page it waits on before it places more.
type WorkspaceHistoryMerge struct {
	Entries []WorkspaceHistoryEntry `json:"entries"`
	Pending []int                   `json:"pending"`
}

// MergeWorkspaceHistories asks Core to interleave the loaded histories of several repositories
// by date, each in its own order (git.workspaceHistoryMerge).
func (c *Client) MergeWorkspaceHistories(ctx context.Context, histories []WorkspaceHistory) (WorkspaceHistoryMerge, error) {
	for i := range histories {
		histories[i].Commits = nonNil(histories[i].Commits)
		for j := range histories[i].Commits {
			histories[i].Commits[j].ParentHashes = nonNil(histories[i].Commits[j].ParentHashes)
		}
	}
	request := struct {
		Repositories []WorkspaceHistory `json:"repositories"`
	}{nonNil(histories)}
	var merged WorkspaceHistoryMerge
	if err := c.Execute(ctx, "git.workspaceHistoryMerge", request, &merged); err != nil {
		return WorkspaceHistoryMerge{}, err
	}
	return merged, nil
}

// SelectWorkspaceRepository asks Core which repository a view acts on, given the discovery
// list and the ID the view picked before, empty when it has not picked one.
func (c *Client) SelectWorkspaceRepository(ctx context.Context, repositories []WorkspaceRepository, selected string) (WorkspaceRepositorySelection, error) {
	request := struct {
		Repositories []WorkspaceRepository `json:"repositories"`
		Selected     string                `json:"selected,omitempty"`
	}{nonNil(repositories), selected}
	var response struct {
		Active   *string  `json:"active"`
		FellBack bool     `json:"fellBack"`
		Others   []string `json:"others"`
	}
	if err := c.Execute(ctx, "git.workspaceRepositorySelection", request, &response); err != nil {
		return WorkspaceRepositorySelection{}, err
	}
	selection := WorkspaceRepositorySelection{FellBack: response.FellBack, Others: response.Others}
	if response.Active != nil {
		selection.Active = *response.Active
	}
	return selection, nil
}

// WorkspaceRepositoryChanges is a discovery entry with the changes git.status read for it.
type WorkspaceRepositoryChanges struct {
	WorkspaceRepository
	Changes []GitChange `json:"changes"`
}

// StagingOperation is what a checkbox of the Commit tool window writes.
type StagingOperation string

const (
	StageChanges   StagingOperation = "stage"
	UnstageChanges StagingOperation = "unstage"
)

// StagingPlan is the operation one checkbox applies to one repository.
type StagingPlan struct {
	Operation StagingOperation `json:"operation"`
	// Paths are repository-relative, both sides of a rename, in change order.
	Paths []string `json:"paths"`
}

// ParentReference says whether the listed ancestor that records a nested repository as a
// submodule moved its recorded commit.
type ParentReference string

const (
	// ParentReferenceMoved is a gitlink the ancestor lists with a new commit.
	ParentReferenceMoved ParentReference = "moved"
	// ParentReferenceUnchanged is a gitlink the ancestor lists with only content changes: a
	// commit here still has to be recorded in the parent.
	ParentReferenceUnchanged ParentReference = "unchanged"
)

// WorkspaceChangeGroup is one repository with changes in the Commit tool window.
type WorkspaceChangeGroup struct {
	ID   string                  `json:"id"`
	Name string                  `json:"name"`
	Role WorkspaceRepositoryRole `json:"role"`
	// FileCount counts each file below a summarized untracked directory.
	FileCount   int `json:"fileCount"`
	StagedCount int `json:"stagedCount"`
	// AllStaged reports that every change that can toggle is staged in full.
	AllStaged bool `json:"allStaged"`
	// Toggleable reports that some change can be staged or unstaged.
	Toggleable bool `json:"toggleable"`
	// Staging is what the group's checkbox writes, nil when it writes nothing.
	Staging *StagingPlan `json:"staging,omitempty"`
	// ParentReference is empty when no listed ancestor records the repository as a submodule.
	ParentReference ParentReference `json:"parentReference,omitempty"`
}

// RepositoryStaging is the paths one repository stages or unstages.
type RepositoryStaging struct {
	ID    string   `json:"id"`
	Paths []string `json:"paths"`
}

// WorkspaceStageAll is what the workspace line's checkbox writes: one operation for every
// repository with something to write.
type WorkspaceStageAll struct {
	Operation    StagingOperation    `json:"operation"`
	Repositories []RepositoryStaging `json:"repositories"`
}

// WorkspaceChangeGroups is the Commit tool window of a workspace with several repositories:
// one line for all changes and a group per repository that has changes, in discovery order.
type WorkspaceChangeGroups struct {
	Groups      []WorkspaceChangeGroup `json:"groups"`
	FileCount   int                    `json:"fileCount"`
	StagedCount int                    `json:"stagedCount"`
	AllStaged   bool                   `json:"allStaged"`
	// StageAll is nil when the workspace line writes nothing.
	StageAll *WorkspaceStageAll `json:"stageAll,omitempty"`
}

// GroupWorkspaceChanges asks Core to group the changes of every repository and plan what
// each checkbox writes. It reads nothing from disk.
func (c *Client) GroupWorkspaceChanges(ctx context.Context, repositories []WorkspaceRepositoryChanges) (WorkspaceChangeGroups, error) {
	request := make([]WorkspaceRepositoryChanges, len(repositories))
	for i, repository := range repositories {
		repository.Changes = nonNil(repository.Changes)
		request[i] = repository
	}
	var groups WorkspaceChangeGroups
	err := c.Execute(ctx, "git.workspaceChangeGroups", struct {
		Repositories []WorkspaceRepositoryChanges `json:"repositories"`
	}{request}, &groups)
	return groups, err
}

// DiscoverWorkspaceRepositories returns Core's ordered repository roots. Core
// owns discovery, nested checkout validation and exclusions. This reads the
// filesystem and must run away from the window thread.
func (c *Client) DiscoverWorkspaceRepositories(ctx context.Context, root string) ([]WorkspaceRepository, error) {
	var response struct {
		Repositories []WorkspaceRepository `json:"repositories"`
	}
	err := c.Execute(ctx, "workspace.repositories", struct {
		Root string `json:"root"`
	}{Root: root}, &response)
	return response.Repositories, err
}

// WorkspaceNode is a file or a directory of a project, as the kernel lists it.
type WorkspaceNode struct {
	// Path is relative to the project root with "/" separators.
	Path string `json:"path"`
	// Name is the last element of Path.
	Name        string `json:"name"`
	IsDirectory bool   `json:"isDirectory"`
	// Children is nil when the kernel did not look inside the directory, and empty when it
	// knows the directory shows nothing.
	Children []WorkspaceNode `json:"children,omitempty"`
	// Leaf says the kernel sent an empty list of children: a directory that shows nothing.
	Leaf bool `json:"-"`
}

// DirectoryListing is the visible children of one directory, directories first and then by
// name, in the kernel's order.
type DirectoryListing struct {
	// Path is relative to the project root; empty for the root.
	Path     string          `json:"path"`
	Children []WorkspaceNode `json:"children"`
}

// directoryListingRequest is the payload of workspace.listDirectories.
type directoryListingRequest struct {
	Root  string   `json:"root"`
	Paths []string `json:"paths"`
}

// rawWorkspaceNode tells a directory the kernel left unlisted, whose children it omits,
// from one it knows is empty, whose children it sends as an empty list.
type rawWorkspaceNode struct {
	Path        string              `json:"path"`
	Name        string              `json:"name"`
	IsDirectory bool                `json:"isDirectory"`
	Children    *[]rawWorkspaceNode `json:"children"`
}

// ListDirectories returns the visible children of each directory in paths, relative to
// root and with "" for the root itself. A directory that no longer exists, or is hidden, is
// left out of the result, which keeps the order of paths. The kernel hides what the project
// hides from its tree.
//
// ListDirectories reads the file system and blocks; call it from a background goroutine.
func (c *Client) ListDirectories(ctx context.Context, root string, paths []string) ([]DirectoryListing, error) {
	var response struct {
		Directories []struct {
			Path     string             `json:"path"`
			Children []rawWorkspaceNode `json:"children"`
		} `json:"directories"`
	}
	if err := c.Execute(ctx, "workspace.listDirectories", directoryListingRequest{Root: root, Paths: paths}, &response); err != nil {
		return nil, err
	}
	listings := make([]DirectoryListing, 0, len(response.Directories))
	for _, d := range response.Directories {
		children := make([]WorkspaceNode, 0, len(d.Children))
		for _, child := range d.Children {
			children = append(children, WorkspaceNode{
				Path: child.Path, Name: child.Name, IsDirectory: child.IsDirectory,
				Leaf: child.IsDirectory && child.Children != nil && len(*child.Children) == 0,
			})
		}
		listings = append(listings, DirectoryListing{Path: d.Path, Children: children})
	}
	return listings, nil
}

// WorkspaceSearchRequest is the shared Core search query and its visibility options.
// Paths in the response are workspace-relative with forward slashes.
type WorkspaceSearchRequest struct {
	Root              string `json:"root"`
	Query             string `json:"query"`
	CaseSensitive     bool   `json:"caseSensitive,omitempty"`
	WholeWords        bool   `json:"wholeWords,omitempty"`
	RegularExpression bool   `json:"regularExpression,omitempty"`
	FileMask          string `json:"fileMask,omitempty"`
	MaxResults        int    `json:"maxResults"`
	// MaxFileResults caps the file-name matches within MaxResults; nil leaves them
	// capped only by MaxResults and zero asks for content matches alone.
	MaxFileResults *int `json:"maxFileResults,omitempty"`
	// IncludeContentRanges asks for the untrimmed line and the match ranges of each
	// content match (WorkspaceSearchMatch.SourceLine and ContentMatchRanges).
	IncludeContentRanges bool `json:"includeContentRanges,omitempty"`
}

// WorkspaceSearchMatch is a file name or a content line returned by Core.
type WorkspaceSearchMatch struct {
	Kind            string            `json:"kind"`
	Path            string            `json:"path"`
	Line            *int              `json:"line"`
	Preview         string            `json:"preview"`
	SymbolName      *string           `json:"symbolName,omitempty"`
	NameMatchRanges []SearchNameRange `json:"nameMatchRanges,omitempty"`
	// MatchingDegree is Core's rank of a name match, higher first.
	MatchingDegree *int `json:"matchingDegree,omitempty"`
	// SourceLine and ContentMatchRanges are the untrimmed line of a content match and
	// its matches in UTF-16 units, returned when the request sets IncludeContentRanges.
	SourceLine         *string           `json:"sourceLine,omitempty"`
	ContentMatchRanges []SearchNameRange `json:"contentMatchRanges,omitempty"`
	// PreviewRanges, returned with SourceLine, are the matches in Preview, which is then the
	// line as a result row shows it: without its indentation, cut in front of a far match.
	PreviewRanges []SearchNameRange `json:"previewRanges,omitempty"`
}

// SearchNameRange locates one Core-selected highlight in UTF-16 code units.
type SearchNameRange struct {
	Start  int `json:"start"`
	Length int `json:"length"`
}

// EverywhereSearchRequest selects the bounded sources and continuation cursor
// of a Core Search Everywhere request. The cursor is opaque and is valid only
// for the same root, query, options and context.
type EverywhereSearchRequest struct {
	Root                      string                   `json:"root"`
	Query                     string                   `json:"query"`
	PageSize                  int                      `json:"pageSize"`
	Cursor                    *string                  `json:"cursor,omitempty"`
	ResultKinds               []string                 `json:"resultKinds"`
	IncludeGeneratedFileNames bool                     `json:"includeGeneratedFileNames"`
	Context                   *EverywhereSearchContext `json:"context,omitempty"`
	// The text options apply to content matches, as in Find in Files.
	CaseSensitive        bool `json:"caseSensitive,omitempty"`
	WholeWords           bool `json:"wholeWords,omitempty"`
	RegularExpression    bool `json:"regularExpression,omitempty"`
	IncludeContentRanges bool `json:"includeContentRanges,omitempty"`
}

type EverywhereSearchContext struct {
	OpenPaths   []string `json:"openPaths,omitempty"`
	RecentPaths []string `json:"recentPaths,omitempty"`
}

type EverywhereSearchPage struct {
	Matches    []WorkspaceSearchMatch `json:"matches"`
	NextCursor *string                `json:"nextCursor"`
}

// SearchEverywherePage asks Core to rank and page workspace matches without
// transferring the complete workspace inventory to the window.
func (c *Client) SearchEverywherePage(ctx context.Context, request EverywhereSearchRequest) (EverywhereSearchPage, error) {
	var page EverywhereSearchPage
	err := c.Execute(ctx, "workspace.searchEverywhere", request, &page)
	return page, err
}

// SearchWorkspace asks Core to match a bounded result set; it performs disk I/O
// and must run away from the window thread.
func (c *Client) SearchWorkspace(ctx context.Context, request WorkspaceSearchRequest) ([]WorkspaceSearchMatch, error) {
	var response struct {
		Matches []WorkspaceSearchMatch `json:"matches"`
	}
	if err := c.Execute(ctx, "workspace.search", request, &response); err != nil {
		return nil, err
	}
	return response.Matches, nil
}

// InvalidateWorkspaceSearch discards Core's cached filesystem inventory, so the
// next search observes file additions and edits even when native events were lost.
func (c *Client) InvalidateWorkspaceSearch(ctx context.Context, root string) error {
	return c.Execute(ctx, "workspace.searchIndex.invalidate", struct {
		Root string `json:"root"`
	}{root}, nil)
}

// FilterWorkspaceChanges applies Core's workspace visibility rules to native
// watcher paths before deciding whether an incremental update is worthwhile.
func (c *Client) FilterWorkspaceChanges(ctx context.Context, paths []string) ([]string, error) {
	var filtered []string
	if err := c.Execute(ctx, "workspace.filterChanges", paths, &filtered); err != nil {
		return nil, err
	}
	return filtered, nil
}

// UpdateWorkspaceSearch applies native file events to Core's cached index.
// Paths are relative to root and are interpreted by Core.
func (c *Client) UpdateWorkspaceSearch(ctx context.Context, root string, paths []string) error {
	return c.Execute(ctx, "workspace.searchIndex.update", struct {
		Root  string   `json:"root"`
		Paths []string `json:"paths"`
	}{root, paths}, nil)
}
