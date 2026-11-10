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
