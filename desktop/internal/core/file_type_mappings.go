package core

import "context"

// FileTypeMapping maps a file name, relative path, or glob pattern to a Lithe language ID.
type FileTypeMapping struct {
	Pattern    string `json:"pattern"`
	LanguageID string `json:"languageID"`
}

// FileTypeMappingIssue describes a validation error returned by Core while normalizing mappings.
type FileTypeMappingIssue struct {
	Scope      string `json:"scope"`
	Index      int    `json:"index"`
	Code       string `json:"code"`
	Pattern    string `json:"pattern"`
	LanguageID string `json:"languageID"`
}

// NormalizedFileTypeMappings holds Core's built-in mappings alongside validated global and project entries.
type NormalizedFileTypeMappings struct {
	Builtins []FileTypeMapping      `json:"builtins"`
	Global   []FileTypeMapping      `json:"global"`
	Project  []FileTypeMapping      `json:"project"`
	Issues   []FileTypeMappingIssue `json:"issues"`
}

// ResolvedFileTypeMapping is the winning language mapping for a single file path.
type ResolvedFileTypeMapping struct {
	LanguageID string `json:"languageID"`
	Source     string `json:"source"`
	Pattern    string `json:"pattern"`
}

// NormalizeFileTypeMappings validates, deduplicates, and normalizes global and project mappings via Core.
func (c *Client) NormalizeFileTypeMappings(ctx context.Context, global, project []FileTypeMapping, knownLanguageIDs []string) (NormalizedFileTypeMappings, error) {
	var result NormalizedFileTypeMappings
	err := c.Execute(ctx, "editor.fileTypeMappings.normalize", struct {
		Global           []FileTypeMapping `json:"global"`
		Project          []FileTypeMapping `json:"project"`
		KnownLanguageIDs []string          `json:"knownLanguageIDs,omitempty"`
	}{
		Global:           nonNilMappings(global),
		Project:          nonNilMappings(project),
		KnownLanguageIDs: knownLanguageIDs,
	}, &result)
	return result, err
}

// ResolveFileTypeMapping resolves path against project, global, and optionally built-in mappings via Core.
func (c *Client) ResolveFileTypeMapping(ctx context.Context, path string, global, project []FileTypeMapping, includeBuiltins bool) (ResolvedFileTypeMapping, error) {
	var result ResolvedFileTypeMapping
	err := c.Execute(ctx, "editor.fileTypeMappings.resolve", struct {
		Path            string            `json:"path"`
		Global          []FileTypeMapping `json:"global"`
		Project         []FileTypeMapping `json:"project"`
		IncludeBuiltins bool              `json:"includeBuiltins"`
	}{
		Path:            path,
		Global:          nonNilMappings(global),
		Project:         nonNilMappings(project),
		IncludeBuiltins: includeBuiltins,
	}, &result)
	return result, err
}

func nonNilMappings(entries []FileTypeMapping) []FileTypeMapping {
	if entries == nil {
		return []FileTypeMapping{}
	}
	return entries
}
