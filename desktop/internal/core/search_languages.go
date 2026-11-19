package core

import "context"

// SearchLanguageSource contains selectors read from an enabled provider manifest.
type SearchLanguageSource struct {
	LanguageID     string   `json:"languageId"`
	FileExtensions []string `json:"fileExtensions,omitempty"`
	FileNames      []string `json:"fileNames,omitempty"`
}

func (c *Client) SearchWorkspaceLanguages(ctx context.Context, root string, sources []SearchLanguageSource) ([]string, error) {
	var result struct {
		Languages []string `json:"languages"`
	}
	err := c.Execute(ctx, "workspace.search", struct {
		Root            string                 `json:"root"`
		Query           string                 `json:"query"`
		LanguageSources []SearchLanguageSource `json:"languageSources"`
	}{root, "", nonNil(sources)}, &result)
	return result.Languages, err
}
