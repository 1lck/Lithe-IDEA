package core

import "context"

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
}

// WorkspaceSearchMatch is a file name or a content line returned by Core.
type WorkspaceSearchMatch struct {
	Kind    string `json:"kind"`
	Path    string `json:"path"`
	Line    *int   `json:"line"`
	Preview string `json:"preview"`
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
