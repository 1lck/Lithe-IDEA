package core

import "context"

// WorkspaceReplaceRequest asks Core for the replacements a project-wide Replace
// would make. Core reads the files itself; TextOverrides supplies the unsaved
// text of open documents by workspace-relative path. Nothing is written.
type WorkspaceReplaceRequest struct {
	Root              string            `json:"root"`
	Query             string            `json:"query"`
	Replacement       string            `json:"replacement"`
	CaseSensitive     bool              `json:"caseSensitive"`
	WholeWords        bool              `json:"wholeWords"`
	RegularExpression bool              `json:"regularExpression"`
	PreserveCase      bool              `json:"preserveCase"`
	FileMask          string            `json:"fileMask,omitempty"`
	Paths             []string          `json:"paths,omitempty"`
	TextOverrides     map[string]string `json:"textOverrides,omitempty"`
}

// WorkspaceReplaceMatch is one changed line of a file, before and after.
type WorkspaceReplaceMatch struct {
	Line            int    `json:"line"`
	Before          string `json:"before"`
	After           string `json:"after"`
	OccurrenceCount int    `json:"occurrenceCount"`
}

// WorkspaceReplaceFile is one file's changed lines and its complete replaced text.
type WorkspaceReplaceFile struct {
	Path            string                  `json:"path"`
	Matches         []WorkspaceReplaceMatch `json:"matches"`
	ReplacementText string                  `json:"replacementText"`
}

// PreviewWorkspaceReplace runs workspace.replacePreview.
func (c *Client) PreviewWorkspaceReplace(ctx context.Context, request WorkspaceReplaceRequest) ([]WorkspaceReplaceFile, error) {
	var response struct {
		Files []WorkspaceReplaceFile `json:"files"`
	}
	if err := c.Execute(ctx, "workspace.replacePreview", request, &response); err != nil {
		return nil, err
	}
	return response.Files, nil
}

// TextReplaceRequest replaces every match in one captured text (workspace.replaceText).
type TextReplaceRequest struct {
	Text              string `json:"text"`
	Query             string `json:"query"`
	Replacement       string `json:"replacement"`
	CaseSensitive     bool   `json:"caseSensitive"`
	WholeWords        bool   `json:"wholeWords"`
	RegularExpression bool   `json:"regularExpression"`
}

// ReplaceText runs workspace.replaceText and returns the replaced text and how
// many matches it replaced.
func (c *Client) ReplaceText(ctx context.Context, request TextReplaceRequest) (string, int, error) {
	var response struct {
		Text  string `json:"text"`
		Count int    `json:"count"`
	}
	if err := c.Execute(ctx, "workspace.replaceText", request, &response); err != nil {
		return "", 0, err
	}
	return response.Text, response.Count, nil
}
