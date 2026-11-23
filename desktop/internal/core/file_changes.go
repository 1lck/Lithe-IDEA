package core

import "context"

// The file changes a plugin asks for (plan API-11) are made by Core: it checks the path, resolves
// the directory holding the entry inside the root, never follows the last component and never
// replaces an entry. The window keeps what only it owns: saving and moving the open documents
// under an entry, the system trash and refreshing the project tree. Every call reads or writes
// the file system and blocks; call it from a background goroutine.

// WorkspaceEntry names an entry below a workspace root that a file change acted on.
type WorkspaceEntry struct {
	// Path is the entry's "/"-separated path below the root, as the request named it.
	Path string `json:"path"`
	// FullPath is the entry's absolute path spelled from the root the window sent, which is how
	// its open documents name it.
	FullPath string `json:"fullPath"`
	// Kind is "file", "directory", "symlink" or "other" (a socket, pipe or device).
	Kind string `json:"kind"`
}

// WorkspaceEntryCreation is one entry to create below Root, the workspace root as the window
// spells it. Kind is "file", "directory" or "symlink"; only a file takes Text, and only a link
// takes LinkTarget, which it stores verbatim.
type WorkspaceEntryCreation struct {
	Root       string  `json:"root"`
	Path       string  `json:"path"`
	Kind       string  `json:"kind"`
	Text       *string `json:"text,omitempty"`
	LinkTarget *string `json:"linkTarget,omitempty"`
}

// CreateWorkspaceEntry creates one file, directory or symbolic link without replacing anything
// (workspace.createEntry).
func (c *Client) CreateWorkspaceEntry(ctx context.Context, creation WorkspaceEntryCreation) (WorkspaceEntry, error) {
	var entry WorkspaceEntry
	err := c.Execute(ctx, "workspace.createEntry", creation, &entry)
	return entry, err
}

type workspaceEntryMove struct {
	Root   string `json:"root"`
	Path   string `json:"path"`
	Target string `json:"target"`
}

// RenameWorkspaceEntry moves path to target in the same root without replacing an entry, and
// returns the target (workspace.renameEntry). A target that changes only the case of the name on
// a file system that ignores case is not a collision.
func (c *Client) RenameWorkspaceEntry(ctx context.Context, root, path, target string) (WorkspaceEntry, error) {
	var entry WorkspaceEntry
	err := c.Execute(ctx, "workspace.renameEntry", workspaceEntryMove{root, path, target}, &entry)
	return entry, err
}

// CopyWorkspaceEntry copies path to target in the same root without replacing an entry, and
// returns the target (workspace.copyEntry). A directory is copied with everything in it, links
// stay links, and a copy that fails part way leaves nothing behind.
func (c *Client) CopyWorkspaceEntry(ctx context.Context, root, path, target string) (WorkspaceEntry, error) {
	var entry WorkspaceEntry
	err := c.Execute(ctx, "workspace.copyEntry", workspaceEntryMove{root, path, target}, &entry)
	return entry, err
}

// ResolveWorkspaceEntry names the existing entry at path without following it
// (workspace.resolveEntry).
func (c *Client) ResolveWorkspaceEntry(ctx context.Context, root, path string) (WorkspaceEntry, error) {
	var entry WorkspaceEntry
	err := c.Execute(ctx, "workspace.resolveEntry", struct {
		Root string `json:"root"`
		Path string `json:"path"`
	}{root, path}, &entry)
	return entry, err
}
