package core

import "context"

// RenderMarkdown renders Markdown source to the sanitized HTML fragment of Core's shared
// dialect (Comrak and Ammonia). Closed leading front matter is omitted. A host that draws
// Markdown itself from the source does not need it; it is for the places that need HTML.
func (c *Client) RenderMarkdown(ctx context.Context, source string) (string, error) {
	var response struct {
		HTML string `json:"html"`
	}
	err := c.Execute(ctx, "markdown.render", struct {
		Source string `json:"source"`
	}{source}, &response)
	return response.HTML, err
}

// MarkdownReferencePurpose says whether a reference is a clicked link or an image the page loads.
type MarkdownReferencePurpose string

const (
	// MarkdownLink is a link the user clicked.
	MarkdownLink MarkdownReferencePurpose = "link"
	// MarkdownResource is an image a preview loads.
	MarkdownResource MarkdownReferencePurpose = "resource"
)

// MarkdownReference is what a link or an image of a rendered document points at. Kind is
// "external" or "remote" with URL, "anchor" with Anchor, "file" with Path (and MIME for a
// resource), or "none" when nothing is followed or loaded.
type MarkdownReference struct {
	Kind   string `json:"kind"`
	URL    string `json:"url,omitempty"`
	Anchor string `json:"anchor,omitempty"`
	Path   string `json:"path,omitempty"`
	MIME   string `json:"mime,omitempty"`
}

// ResolveMarkdownReference asks Core what one link destination or image src of the document at
// documentPath points at. workspaceRoot may be empty. A resource file is canonical, inside the
// document's scope and an image; a host reads it without following another link and loads
// nothing the answer refuses. Resources are checked on the file system, so it runs off the
// window thread.
func (c *Client) ResolveMarkdownReference(ctx context.Context, documentPath, workspaceRoot, reference string, purpose MarkdownReferencePurpose) (MarkdownReference, error) {
	var response MarkdownReference
	err := c.Execute(ctx, "markdown.resolveReference", struct {
		DocumentPath  string                   `json:"documentPath"`
		WorkspaceRoot string                   `json:"workspaceRoot,omitempty"`
		Reference     string                   `json:"reference"`
		Purpose       MarkdownReferencePurpose `json:"purpose"`
	}{documentPath, workspaceRoot, reference, purpose}, &response)
	return response, err
}
