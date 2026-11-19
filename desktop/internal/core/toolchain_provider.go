package core

import (
	"context"
	"encoding/json"
)

// ToolchainQueryContext is the captured identity of the open workspace.
type ToolchainQueryContext struct {
	ID         string `json:"contextID"`
	Generation uint64 `json:"generation"`
}

// ToolchainQueryWorkspace identifies the directory for one provider query.
type ToolchainQueryWorkspace struct {
	RootID    string `json:"rootID"`
	Root      string `json:"root"`
	Directory string `json:"directory"`
}

// ToolchainQueryParams remain the same from submission to reply validation.
type ToolchainQueryParams struct {
	OperationID string                   `json:"operationID"`
	Generation  uint64                   `json:"generation"`
	ProviderID  string                   `json:"providerID"`
	Authority   map[string]string        `json:"authority"`
	Context     *ToolchainQueryContext   `json:"context"`
	Workspace   *ToolchainQueryWorkspace `json:"workspace"`
	Tools       []string                 `json:"tools"`
}

// ToolchainProviderReply preserves the real wire identity and raw response.
type ToolchainProviderReply struct {
	ID       json.RawMessage `json:"id"`
	Response json.RawMessage `json:"response"`
}

// ToolchainProviderSnapshot contains the reply facts validated by Core.
type ToolchainProviderSnapshot struct {
	Installations []ToolchainProviderInstallation `json:"installations"`
	Watch         []string                        `json:"watch"`
}

const (
	ToolchainProviderUnavailable = "plugin.toolchain.providerUnavailable"
	ToolchainProviderTimeout     = "plugin.toolchain.timeout"
)

// RequestPluginToolchain queues a query on the plugin's initialized backend.
func (c *Client) RequestPluginToolchain(ctx context.Context, sessionID string, params ToolchainQueryParams, timeoutMS int) error {
	return c.Execute(ctx, "lsp.toolchainRequest", struct {
		SessionID   string               `json:"sessionId"`
		OperationID string               `json:"operationId"`
		Params      ToolchainQueryParams `json:"params"`
		TimeoutMS   int                  `json:"timeoutMilliseconds"`
	}{sessionID, params.OperationID, params, timeoutMS}, nil)
}

// ToolchainFailureReply asks Core to encode a missing transport reply.
func (c *Client) ToolchainFailureReply(ctx context.Context, params ToolchainQueryParams, code string) (ToolchainProviderReply, error) {
	const command = "toolchains.failureReply"
	var result struct {
		Status string                  `json:"status"`
		Reply  *ToolchainProviderReply `json:"reply"`
		Error  *MarketplaceRejection   `json:"error"`
	}
	request := struct {
		Params ToolchainQueryParams `json:"params"`
		Code   string               `json:"code"`
	}{params, code}
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return ToolchainProviderReply{}, err
	}
	if result.Error != nil {
		return ToolchainProviderReply{}, result.Error
	}
	if result.Status != "ok" || result.Reply == nil {
		return ToolchainProviderReply{}, newParseError(command, "toolchains.failureReply returned no reply", "")
	}
	return *result.Reply, nil
}

// DecodeToolchainReply verifies the raw reply against authority-local facts.
func (c *Client) DecodeToolchainReply(ctx context.Context, query ToolchainQuery) (ToolchainProviderSnapshot, error) {
	const command = "toolchains.decodeReply"
	var result struct {
		Status   string                     `json:"status"`
		Snapshot *ToolchainProviderSnapshot `json:"snapshot"`
		Error    *MarketplaceRejection      `json:"error"`
	}
	if err := c.Execute(ctx, command, query, &result); err != nil {
		return ToolchainProviderSnapshot{}, err
	}
	if result.Error != nil {
		return ToolchainProviderSnapshot{}, result.Error
	}
	if result.Status != "ok" || result.Snapshot == nil {
		return ToolchainProviderSnapshot{}, newParseError(command, "toolchains.decodeReply returned no snapshot", "")
	}
	return *result.Snapshot, nil
}
