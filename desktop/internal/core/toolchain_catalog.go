package core

import (
	"context"
)

// ToolchainCatalog contains registrations owned by this machine, independent of project pins.
type ToolchainCatalog struct {
	Version int                              `json:"version"`
	Tools   map[string]ToolchainCatalogEntry `json:"tools"`
}

type ToolchainCatalogEntry struct {
	Homes       []string `json:"homes"`
	DefaultHome *string  `json:"defaultHome,omitempty"`
}

type ToolchainCatalogState struct {
	Document ToolchainCatalog `json:"document"`
	Storage  struct {
		RelativePath string `json:"relativePath"`
		MaximumBytes int64  `json:"maximumBytes"`
	} `json:"storage"`
}

type ToolchainCatalogEdit struct {
	Tool        string   `json:"tool"`
	Homes       []string `json:"homes"`
	DefaultHome *string  `json:"defaultHome"`
}

type ToolchainCatalogPublication struct {
	Changed  bool             `json:"changed"`
	Document *string          `json:"document"`
	Catalog  ToolchainCatalog `json:"catalog"`
}

func (c *Client) ReadToolchainCatalog(ctx context.Context, document *string, platform string) (ToolchainCatalogState, error) {
	return settingsSurfaceResult[ToolchainCatalogState](ctx, c, "toolchains.catalogState", "state", struct {
		Document *string `json:"document"`
		Platform string  `json:"platform"`
	}{document, platform})
}

func (c *Client) EditToolchainCatalog(ctx context.Context, document *string, platform string, edits []ToolchainCatalogEdit) (ToolchainCatalogPublication, error) {
	return settingsSurfaceResult[ToolchainCatalogPublication](ctx, c, "toolchains.editCatalog", "edit", struct {
		Document *string                `json:"document"`
		Platform string                 `json:"platform"`
		Edits    []ToolchainCatalogEdit `json:"edits"`
	}{document, platform, edits})
}
