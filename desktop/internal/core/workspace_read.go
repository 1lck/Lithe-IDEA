package core

import "context"

// WorkspaceDirectoryRequest asks Core for one bounded disk directory page (API-06).
type WorkspaceDirectoryRequest struct {
	Root                 string   `json:"root"`
	Path                 string   `json:"path"`
	Cursor               *string  `json:"cursor,omitempty"`
	Limit                *int     `json:"limit,omitempty"`
	HiddenDirectoryNames []string `json:"hiddenDirectoryNames,omitempty"`
	HiddenFilePatterns   []string `json:"hiddenFilePatterns,omitempty"`
}

// WorkspaceDirectoryEntry is a child path in Core's directory page.
type WorkspaceDirectoryEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Kind string `json:"kind"`
}

// WorkspaceDirectoryPage contains entries and an opaque continuation, nil at the end.
type WorkspaceDirectoryPage struct {
	Entries    []WorkspaceDirectoryEntry `json:"entries"`
	NextCursor *string                   `json:"nextCursor"`
}

// WorkspaceStat describes the leaf itself, without following ancestor links.
type WorkspaceStat struct {
	Path                 string  `json:"path"`
	Kind                 string  `json:"kind"`
	Size                 uint64  `json:"size"`
	ModifiedMilliseconds *uint64 `json:"modifiedMilliseconds"`
}

// WorkspaceReadIdentity describes exactly the returned bytes, including truncation.
type WorkspaceReadIdentity struct {
	SHA256      string `json:"sha256"`
	ByteCount   int    `json:"byteCount"`
	IsTruncated bool   `json:"isTruncated"`
}

// WorkspaceFileRead is a bounded disk prefix. Exactly one of Text and Base64 is present.
type WorkspaceFileRead struct {
	Path        string                `json:"path"`
	Source      string                `json:"source"`
	ByteCount   int                   `json:"byteCount"`
	IsTruncated bool                  `json:"isTruncated"`
	Identity    WorkspaceReadIdentity `json:"identity"`
	Text        *string               `json:"text,omitempty"`
	Encoding    *string               `json:"encoding,omitempty"`
	Base64      *string               `json:"base64,omitempty"`
}

// ReadWorkspaceDirectory blocks on a no-follow disk listing; call off the window thread.
func (c *Client) ReadWorkspaceDirectory(ctx context.Context, request WorkspaceDirectoryRequest) (WorkspaceDirectoryPage, error) {
	var page WorkspaceDirectoryPage
	err := c.Execute(ctx, "workspace.readDirectory", request, &page)
	return page, err
}

// StatWorkspaceEntry blocks on disk metadata; call off the window thread.
func (c *Client) StatWorkspaceEntry(ctx context.Context, root, path string) (WorkspaceStat, error) {
	var result WorkspaceStat
	err := c.Execute(ctx, "workspace.stat", struct {
		Root string `json:"root"`
		Path string `json:"path"`
	}{root, path}, &result)
	return result, err
}

// ReadWorkspaceFile blocks on a bounded no-follow disk read; it never reads a live buffer.
func (c *Client) ReadWorkspaceFile(ctx context.Context, root, path string, maximumBytes *int) (WorkspaceFileRead, error) {
	var result WorkspaceFileRead
	err := c.Execute(ctx, "workspace.readFile", struct {
		Root         string `json:"root"`
		Path         string `json:"path"`
		MaximumBytes *int   `json:"maximumBytes,omitempty"`
	}{root, path, maximumBytes}, &result)
	return result, err
}
