package core

import (
	"context"
	"encoding/json"
)

// ToolchainPinStoragePlan describes bounded workspace-relative native reads.
type ToolchainPinStoragePlan struct {
	DocumentRelativePath string `json:"documentRelativePath"`
	IgnoreRelativePath   string `json:"ignoreRelativePath"`
	MaximumDocumentBytes int64  `json:"maximumDocumentBytes"`
	MaximumIgnoreBytes   int64  `json:"maximumIgnoreBytes"`
}

// ToolchainPinSourcesRequest carries exact captured sources; nil means absent.
type ToolchainPinSourcesRequest struct {
	Document       *string            `json:"document"`
	IgnoreDocument *string            `json:"ignoreDocument"`
	Directory      string             `json:"directory"`
	Edits          []ToolchainPinEdit `json:"edits"`
}

// ToolchainPinSourcesEdit is Core's complete publication plan, without native I/O.
type ToolchainPinSourcesEdit struct {
	Document        *string `json:"document"`
	DocumentChanged bool    `json:"documentChanged"`
	IgnoreDocument  *string `json:"ignoreDocument"`
	IgnoreChanged   bool    `json:"ignoreChanged"`
}

type toolchainSourceOutcome struct {
	toolchainOutcome
	Storage  *ToolchainPinStoragePlan `json:"storage"`
	Document json.RawMessage          `json:"document"`
}

// ToolchainPinStorage returns the Core-owned paths and source budgets.
func (c *Client) ToolchainPinStorage(ctx context.Context) (ToolchainPinStoragePlan, error) {
	const command = "toolchains.pinStoragePlan"
	var result toolchainSourceOutcome
	if err := c.Execute(ctx, command, struct{}{}, &result); err != nil {
		return ToolchainPinStoragePlan{}, err
	}
	if err := result.failure(command); err != nil {
		return ToolchainPinStoragePlan{}, err
	}
	if result.Storage == nil {
		return ToolchainPinStoragePlan{}, newParseError(command, "missing storage plan", "")
	}
	return *result.Storage, nil
}

// DecodeToolchainPinDocument validates all stored entries, including dormant tools.
func (c *Client) DecodeToolchainPinDocument(ctx context.Context, document *string) (json.RawMessage, error) {
	const command = "toolchains.decodePinDocument"
	var result toolchainSourceOutcome
	if err := c.Execute(ctx, command, struct {
		Document *string `json:"document"`
	}{document}, &result); err != nil {
		return nil, err
	}
	if err := result.failure(command); err != nil {
		return nil, err
	}
	if len(result.Document) == 0 {
		return nil, newParseError(command, "missing decoded document", "")
	}
	return result.Document, nil
}

// EditToolchainPinSources asks Core to edit complete captured text sources.
func (c *Client) EditToolchainPinSources(ctx context.Context, request ToolchainPinSourcesRequest) (ToolchainPinSourcesEdit, error) {
	const command = "toolchains.editPinSources"
	var result toolchainSourceOutcome
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return ToolchainPinSourcesEdit{}, err
	}
	if err := result.failure(command); err != nil {
		return ToolchainPinSourcesEdit{}, err
	}
	var edit ToolchainPinSourcesEdit
	if err := json.Unmarshal(result.Edit, &edit); err != nil {
		return edit, newParseError(command, "missing or invalid source edit", err.Error())
	}
	return edit, nil
}
