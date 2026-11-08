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
