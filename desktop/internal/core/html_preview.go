package core

import "context"

// HTMLPreviewSite is where the static site an HTML file is previewed as lies: Root is the folder
// the page may load from, Address the file's path from it as a relative URL, its segments
// percent-encoded, and MIME the content type the file is served as.
type HTMLPreviewSite struct {
	Root    string `json:"root"`
	Address string `json:"address"`
	MIME    string `json:"mime"`
}

// HTMLPreviewSite asks Core for the site of the HTML file at documentPath: the workspace when the
// file lies in workspaceRoot, which may be empty, and the file's folder otherwise.
func (c *Client) HTMLPreviewSite(ctx context.Context, documentPath, workspaceRoot string) (HTMLPreviewSite, error) {
	var response HTMLPreviewSite
	err := c.Execute(ctx, "htmlPreview.site", htmlPreviewDocument{documentPath, workspaceRoot}, &response)
	return response, err
}

// HTMLPreviewResource is what one request of an HTML file's site serves. Kind is "document", the
// file itself, served from the editor's text; "file" with the canonical Path to read without
// following another link and the MIME to serve it as; "directory", a folder whose index.html the
// page goes on to; "denied", a hidden file or a key the site refuses (HTTP 403); or "none", which
// is not served (HTTP 404).
type HTMLPreviewResource struct {
	Kind string `json:"kind"`
	Path string `json:"path,omitempty"`
	MIME string `json:"mime,omitempty"`
}

// ResolveHTMLPreviewRequest asks Core what the request for path, from the root of the site of the
// HTML file at documentPath, serves. path is as the web engine reports it: percent-decoded,
// without a query, and empty for the root. The answer is checked on the file system, so it runs
// off the window thread.
func (c *Client) ResolveHTMLPreviewRequest(ctx context.Context, documentPath, workspaceRoot, path string) (HTMLPreviewResource, error) {
	var response HTMLPreviewResource
	err := c.Execute(ctx, "htmlPreview.resolveRequest", struct {
		htmlPreviewDocument
		Path string `json:"path"`
	}{htmlPreviewDocument{documentPath, workspaceRoot}, path}, &response)
	return response, err
}

// htmlPreviewDocument names the HTML file a preview command is about.
type htmlPreviewDocument struct {
	DocumentPath  string `json:"documentPath"`
	WorkspaceRoot string `json:"workspaceRoot,omitempty"`
}
