package core

import (
	"context"
	"encoding/json"
)

// MarketplaceDeltaRequest binds a companion index to the approved local base and
// the full archive already selected from the main index.
type MarketplaceDeltaRequest struct {
	Index       json.RawMessage `json:"index"`
	PluginID    string          `json:"pluginID"`
	Platform    string          `json:"platform"`
	Repository  string          `json:"repository"`
	FromVersion string          `json:"fromVersion"`
	FromSHA256  string          `json:"fromSHA256"`
	ToVersion   string          `json:"toVersion"`
	ToSHA256    string          `json:"toSHA256"`
	ArchiveURL  string          `json:"archiveURL"`
}

// MarketplaceDelta is the optional patch accepted by Core for the exact input.
type MarketplaceDelta struct {
	PluginID    string `json:"pluginID"`
	Platform    string `json:"platform"`
	FromVersion string `json:"fromVersion"`
	FromSHA256  string `json:"fromSHA256"`
	ToVersion   string `json:"toVersion"`
	ToSHA256    string `json:"toSHA256"`
	ToSize      int64  `json:"toSize"`
	Format      string `json:"format"`
	DownloadURL string `json:"downloadURL"`
	SHA256      string `json:"sha256"`
	Size        int64  `json:"size"`
}

func (c *Client) SelectMarketplaceDelta(ctx context.Context, request MarketplaceDeltaRequest) (*MarketplaceDelta, error) {
	const command = "plugins.marketplace.selectDelta"
	var result struct {
		marketplaceOutcome
		Patch *MarketplaceDelta `json:"patch"`
	}
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return nil, err
	}
	if err := result.failure(command); err != nil {
		return nil, err
	}
	return result.Patch, nil
}

// ApplyMarketplaceDelta writes a verified ZIP to an empty path owned by the caller.
// The caller removes the staging directory on failure or cancellation.
func (c *Client) ApplyMarketplaceDelta(ctx context.Context, patch MarketplaceDelta, basePath, patchPath, outputPath string) error {
	const command = "plugins.marketplace.applyDelta"
	var result struct {
		marketplaceOutcome
		Applied bool `json:"applied"`
	}
	request := struct {
		Patch      MarketplaceDelta `json:"patch"`
		BasePath   string           `json:"basePath"`
		PatchPath  string           `json:"patchPath"`
		OutputPath string           `json:"outputPath"`
	}{patch, basePath, patchPath, outputPath}
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return err
	}
	if err := result.failure(command); err != nil {
		return err
	}
	if !result.Applied {
		return newParseError(command, "marketplace returned no reconstructed archive", "")
	}
	return nil
}
