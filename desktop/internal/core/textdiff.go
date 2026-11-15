package core

import "context"

// CompareTexts has Core compare two texts the host already holds, line by line, and returns
// the comparison as the file diff the Diff tab shows, its path and status left for the caller.
// Core never reads a file for it; each text is at most 16 MiB.
func (c *Client) CompareTexts(ctx context.Context, oldText, newText string) (GitDiffFile, error) {
	const command = "diff.compareTexts"
	var result struct {
		Rows  []GitDiffRow `json:"rows"`
		Lines []struct {
			Kind    string `json:"kind"`
			Content string `json:"content"`
			OldLine *int   `json:"oldLine"`
			NewLine *int   `json:"newLine"`
		} `json:"lines"`
		Additions int `json:"additions"`
		Deletions int `json:"deletions"`
	}
	if err := c.Execute(ctx, command, struct {
		OldText string `json:"oldText"`
		NewText string `json:"newText"`
	}{oldText, newText}, &result); err != nil {
		return GitDiffFile{}, err
	}
	file := GitDiffFile{Additions: result.Additions, Deletions: result.Deletions, Rows: result.Rows, Lines: make([]GitDiffLine, len(result.Lines))}
	if file.Rows == nil {
		file.Rows = []GitDiffRow{}
	}
	// The unified kinds of the comparison are the line types of a Git diff.
	for index, line := range result.Lines {
		switch line.Kind {
		case "context", "removed", "added":
		default:
			return GitDiffFile{}, newParseError(command, "the comparison returned an unknown line kind", line.Kind)
		}
		file.Lines[index] = GitDiffLine{LineType: line.Kind, Content: line.Content, OldLine: line.OldLine, NewLine: line.NewLine}
	}
	return file, nil
}
