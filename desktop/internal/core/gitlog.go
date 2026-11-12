package core

import "context"

// GitReference is a local branch, remote branch or tag of a repository.
type GitReference struct {
	// FullName is the reference's full name, for example "refs/heads/main".
	FullName string `json:"fullName"`
	// ShortName is the name Git shows, for example "main" or "origin/main".
	ShortName string `json:"shortName"`
	// Kind is "local", "remote" or "tag".
	Kind string `json:"kind"`
	// PeelsToCommit reports that the reference resolves to a commit.
	PeelsToCommit bool `json:"peelsToCommit"`
	// IsCurrent marks the checked-out local branch.
	IsCurrent bool `json:"isCurrent"`
	// UpstreamShortName is the short name of a local branch's upstream, empty without one.
	UpstreamShortName string `json:"upstreamShortName,omitempty"`
	// Ahead and Behind count the commits only the branch and only its upstream have.
	Ahead  int `json:"ahead"`
	Behind int `json:"behind"`
}

// GitReferences are the references of a repository and the configured identity.
type GitReferences struct {
	References []GitReference `json:"references"`
	// RecentReferences are up to five local branches, most recently checked out first.
	RecentReferences []GitReference `json:"recentReferences"`
	UserName         string         `json:"userName,omitempty"`
	UserEmail        string         `json:"userEmail,omitempty"`
}

// GitCommit is the metadata of one commit as a history page lists it.
type GitCommit struct {
	Hash         string   `json:"hash"`
	ShortHash    string   `json:"shortHash"`
	ParentHashes []string `json:"parentHashes"`
	AuthorName   string   `json:"authorName"`
	AuthorEmail  string   `json:"authorEmail"`
	// Date is the author date as "YYYY/MM/DD HH:MM" in the author's own time zone.
	Date string `json:"date"`
	// DateUTCOffsetMinutes is the author's UTC offset for Date, nil when Git reported none.
	DateUTCOffsetMinutes *int `json:"dateUtcOffsetMinutes"`
	// DateUnixSeconds is the author instant, nil when the date or the offset is invalid.
	DateUnixSeconds *int64 `json:"dateUnixSeconds,omitempty"`
	Subject         string `json:"subject"`
	// Decorations is Git's decoration text of the commit, empty when nothing points at it.
	Decorations string `json:"decorations"`
}

// GitHistoryPage is one bounded page of history.
type GitHistoryPage struct {
	Commits []GitCommit `json:"commits"`
	// NextCursor continues the walk with GitHistoryPage; empty when the page reaches the end.
	NextCursor string `json:"nextCursor,omitempty"`
	HasMore    bool   `json:"hasMore"`
}

// GitCommitFile is one path a commit changed.
type GitCommitFile struct {
	// Status is the normalized name-status code, such as "A", "M", "D" or "R".
	Status string `json:"status"`
	Path   string `json:"path"`
}

// GitCommitDetail is one commit with the body of its message.
type GitCommitDetail struct {
	Commit GitCommit `json:"commit"`
	// Body is the message after the subject paragraph, empty when there is only a subject.
	Body string `json:"body"`
}

type gitRootRequest struct {
	Root string `json:"root"`
}

type gitCommitRequest struct {
	Root   string `json:"root"`
	Commit string `json:"commit"`
}

type gitHistoryPageRequest struct {
	Root      string `json:"root"`
	Reference string `json:"reference,omitempty"`
	Order     string `json:"order"`
	Cursor    string `json:"cursor,omitempty"`
	Limit     int    `json:"limit"`
}

type gitCursorRequest struct {
	Root   string `json:"root"`
	Cursor string `json:"cursor"`
}

type gitCursorCloseResponse struct {
	Closed bool `json:"closed"`
}

type gitFilesResponse struct {
	Files []GitCommitFile `json:"files"`
}

// GitReferences returns the branches and tags of the repository at root and the
// configured user identity. A root outside a repository fails with the kernel's Git error.
//
// GitReferences starts git and blocks; call it from a background goroutine.
func (c *Client) GitReferences(ctx context.Context, root string) (GitReferences, error) {
	var references GitReferences
	if err := c.Execute(ctx, "git.references", gitRootRequest{Root: root}, &references); err != nil {
		return GitReferences{}, err
	}
	references.References = nonNil(references.References)
	references.RecentReferences = nonNil(references.RecentReferences)
	return references, nil
}

// GitHistoryPage returns up to limit commits in date order, children before parents.
//
// The walk starts at reference, a full or short reference name, or at every reference
// when reference is empty. A non-empty cursor continues the walk of an earlier page and
// must be asked with the same reference; the kernel drops a cursor that was idle for two
// minutes and keeps at most eight, so a stale cursor fails and the history is reloaded.
// A walk that is not continued to its end should be released with CloseGitHistoryCursor.
//
// GitHistoryPage starts git and blocks; call it from a background goroutine.
func (c *Client) GitHistoryPage(ctx context.Context, root, reference, cursor string, limit int) (GitHistoryPage, error) {
	request := gitHistoryPageRequest{Root: root, Reference: reference, Order: "date", Cursor: cursor, Limit: limit}
	var page GitHistoryPage
	if err := c.Execute(ctx, "git.historyPage", request, &page); err != nil {
		return GitHistoryPage{}, err
	}
	page.Commits = nonNil(page.Commits)
	for i := range page.Commits {
		page.Commits[i].ParentHashes = nonNil(page.Commits[i].ParentHashes)
	}
	return page, nil
}

// CloseGitHistoryCursor releases a history cursor and reports whether it was still open.
func (c *Client) CloseGitHistoryCursor(ctx context.Context, root, cursor string) (bool, error) {
	var response gitCursorCloseResponse
	err := c.Execute(ctx, "git.historyCursorClose", gitCursorRequest{Root: root, Cursor: cursor}, &response)
	return response.Closed, err
}

// GitCommitFiles returns the paths commit changed against its first parent.
//
// GitCommitFiles starts git and blocks; call it from a background goroutine.
func (c *Client) GitCommitFiles(ctx context.Context, root, commit string) ([]GitCommitFile, error) {
	var response gitFilesResponse
	if err := c.Execute(ctx, "git.commitFiles", gitCommitRequest{Root: root, Commit: commit}, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Files), nil
}

// GitCommit returns one commit with the body of its message.
//
// GitCommit starts git and blocks; call it from a background goroutine.
func (c *Client) GitCommit(ctx context.Context, root, commit string) (GitCommitDetail, error) {
	var detail GitCommitDetail
	if err := c.Execute(ctx, "git.commit", gitCommitRequest{Root: root, Commit: commit}, &detail); err != nil {
		return GitCommitDetail{}, err
	}
	detail.Commit.ParentHashes = nonNil(detail.Commit.ParentHashes)
	return detail, nil
}

// GraphCommit is one commit the graph is laid out for: its identity, parents and the
// decorations its labels come from.
type GraphCommit struct {
	Hash         string   `json:"hash"`
	ParentHashes []string `json:"parentHashes"`
	Decorations  string   `json:"decorations"`
}

// GraphRequest asks the kernel to lay out a commit graph.
type GraphRequest struct {
	// Commits are the loaded commits, children before parents.
	Commits []GraphCommit `json:"commits"`
	// RemoteNames are the short names of the remote branches, which tell remote labels
	// from local ones.
	RemoteNames []string `json:"remoteNames"`
	// RepositoryCommits are the commits of the wider window the colors and lanes are kept
	// stable against.
	RepositoryCommits []GraphCommit `json:"repositoryCommits"`
	// VisibleHashes are the commits a filter keeps; nil shows all of them.
	VisibleHashes []string `json:"visibleHashes"`
	// Expanded draws long edges in full instead of cutting them with arrows.
	Expanded bool `json:"-"`
	// CurrentBranch is the branch whose commits get the current-branch background, empty
	// for none.
	CurrentBranch string `json:"currentBranch,omitempty"`
}

type graphRequestWire struct {
	Commits           []GraphCommit `json:"commits"`
	RemoteNames       []string      `json:"remoteNames"`
	RepositoryCommits []GraphCommit `json:"repositoryCommits"`
	VisibleHashes     []string      `json:"visibleHashes"`
	DisplayMode       string        `json:"displayMode"`
	CurrentBranch     string        `json:"currentBranch,omitempty"`
}

// GraphEdge is one edge from a row's commit to a parent.
type GraphEdge struct {
	ID         string `json:"id"`
	ParentHash string `json:"parentHash"`
	TargetLane *int   `json:"targetLane"`
	ColorID    int32  `json:"colorId"`
	IsMissing  bool   `json:"isMissing"`
	IsDotted   bool   `json:"isDotted"`
}

// GraphLabel is one reference label of a row.
type GraphLabel struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	// Kind is "head", "branch", "remote" or "tag".
	Kind string `json:"kind"`
}

// GraphElement is one line segment the row paints: from Position in this row toward
// AdjacentPosition in the row above (Direction "up") or below ("down").
type GraphElement struct {
	ID               string `json:"id"`
	Position         int    `json:"position"`
	AdjacentPosition int    `json:"adjacentPosition"`
	Direction        string `json:"direction"`
	ColorID          int32  `json:"colorId"`
	IsDotted         bool   `json:"isDotted"`
	IsMissing        bool   `json:"isMissing"`
	HasArrow         bool   `json:"hasArrow"`
	IsTerminal       bool   `json:"isTerminal"`
	// TargetHash is the commit an arrow leads to, empty for a plain segment.
	TargetHash string `json:"targetHash,omitempty"`
}

// GraphRow is the layout of one visible commit.
type GraphRow struct {
	CommitHash    string         `json:"commitHash"`
	Lane          int            `json:"lane"`
	LaneCount     int            `json:"laneCount"`
	ColorID       int32          `json:"colorId"`
	ParentEdges   []GraphEdge    `json:"parentEdges"`
	Labels        []GraphLabel   `json:"labels"`
	PrintElements []GraphElement `json:"printElements"`
}

// Graph is the laid out commit graph.
type Graph struct {
	Rows      []GraphRow `json:"rows"`
	LaneCount int        `json:"laneCount"`
	// RecommendedLaneCount is the width the graph column should keep however narrow the
	// visible rows are.
	RecommendedLaneCount int  `json:"recommendedLaneCount"`
	HasMissingParents    bool `json:"hasMissingParents"`
	// CurrentBranchHashes are the commits of the current branch.
	CurrentBranchHashes []string `json:"currentBranchHashes"`
}

// GitGraph lays out the commit graph of the commits in request. It runs no process.
func (c *Client) GitGraph(ctx context.Context, request GraphRequest) (Graph, error) {
	mode := "compact"
	if request.Expanded {
		mode = "expanded"
	}
	wire := graphRequestWire{
		Commits:           nonNil(request.Commits),
		RemoteNames:       nonNil(request.RemoteNames),
		RepositoryCommits: nonNil(request.RepositoryCommits),
		VisibleHashes:     request.VisibleHashes,
		DisplayMode:       mode,
		CurrentBranch:     request.CurrentBranch,
	}
	var graph Graph
	if err := c.Execute(ctx, "git.graphProjection", wire, &graph); err != nil {
		return Graph{}, err
	}
	graph.Rows = nonNil(graph.Rows)
	graph.CurrentBranchHashes = nonNil(graph.CurrentBranchHashes)
	return graph, nil
}

// ReferenceTreeNode is one node of the reference tree: a folder made of a name part
// ("feature/" in "feature/login"), or a reference.
type ReferenceTreeNode struct {
	Name string `json:"name"`
	Path string `json:"path"`
	// Reference is the index of the reference in the request, nil for a folder.
	Reference *int                `json:"reference"`
	Children  []ReferenceTreeNode `json:"children"`
}

type referenceTreeEntry struct {
	Name        string `json:"name"`
	Prioritized bool   `json:"prioritized,omitempty"`
}

type referenceTreeRequest struct {
	References []referenceTreeEntry `json:"references"`
}

type referenceTreeResponse struct {
	Nodes []ReferenceTreeNode `json:"nodes"`
}

// GitReferenceTree groups reference short names into folders by their "/" parts. A name
// in prioritized sorts first among its siblings. It runs no process.
func (c *Client) GitReferenceTree(ctx context.Context, names []string, prioritized map[string]bool) ([]ReferenceTreeNode, error) {
	request := referenceTreeRequest{References: make([]referenceTreeEntry, len(names))}
	for i, name := range names {
		request.References[i] = referenceTreeEntry{Name: name, Prioritized: prioritized[name]}
	}
	var response referenceTreeResponse
	if err := c.Execute(ctx, "git.referenceTree", request, &response); err != nil {
		return nil, err
	}
	return nonNil(response.Nodes), nil
}

// HistoryDateEntry is one commit a date filter is asked about.
type HistoryDateEntry struct {
	ID                  string `json:"id"`
	Date                string `json:"date"`
	UTCOffsetMinutes    *int   `json:"utcOffsetMinutes,omitempty"`
	FallbackUnixSeconds *int64 `json:"fallbackUnixSeconds,omitempty"`
}

type historyQueryRequest struct {
	Entries []HistoryDateEntry `json:"entries"`
	After   *int64             `json:"afterUnixSeconds,omitempty"`
	Before  *int64             `json:"beforeUnixSeconds,omitempty"`
}

type historyQueryResponse struct {
	MatchingIDs []string `json:"matchingIds"`
}

// GitHistoryDates returns the IDs of the entries authored at or after after and before
// before, in Unix seconds; a nil bound is open. At most 4096 entries are asked at once.
// It runs no process.
func (c *Client) GitHistoryDates(ctx context.Context, entries []HistoryDateEntry, after, before *int64) ([]string, error) {
	var response historyQueryResponse
	err := c.Execute(ctx, "git.historyQuery", historyQueryRequest{Entries: nonNil(entries), After: after, Before: before}, &response)
	return nonNil(response.MatchingIDs), err
}
