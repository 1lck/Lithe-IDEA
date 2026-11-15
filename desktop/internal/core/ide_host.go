package core

import (
	"context"
	"encoding/json"
)

// IDEToolExposure is one canonical tool offered to a connection. Arguments
// narrows optional fields only; the host owns schemas and permissions.
type IDEToolExposure struct {
	Name      string   `json:"name"`
	Arguments []string `json:"arguments,omitempty"`
}

// IDEPermissions are the two independent grants of one connection. Both are
// false unless the user enables them, and they are fixed until the connection closes.
type IDEPermissions struct {
	Configure bool `json:"configure"`
	Execute   bool `json:"execute"`
}

// IDEHostOpenRequest is the open arguments. The Core rejects unknown fields.
// Directory is a private app-data directory; HelperPath must already exist.
type IDEHostOpenRequest struct {
	Directory    string            `json:"directory"`
	WorkspaceKey string            `json:"workspaceKey"`
	HelperPath   string            `json:"helperPath"`
	Permissions  IDEPermissions    `json:"permissions"`
	ToolExposure []IDEToolExposure `json:"toolExposure,omitempty"`
	OwnerID      string            `json:"ownerId,omitempty"`
}

// IDEHostOpenResult is the connection descriptor. Configuration holds the
// helper command and descriptor path only, never a bearer credential.
type IDEHostOpenResult struct {
	HostID        string          `json:"hostID"`
	Configuration json.RawMessage `json:"configuration"`
}

// IDEHostRequest is one request queued for the native dispatcher. Name and
// Arguments are untrusted client input.
type IDEHostRequest struct {
	RequestID string          `json:"requestID"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// IDEHostPollResult lists requests delivered by poll. Poll returns at most one.
type IDEHostPollResult struct {
	Requests []IDEHostRequest `json:"requests"`
}

// IDEHostClaimResult carries a nil Request when the request expired, was
// cancelled or was already claimed.
type IDEHostClaimResult struct {
	Request *IDEHostClaimedRequest `json:"request"`
}

// IDEHostClaimedRequest is a claimed request with the remaining deadline in
// milliseconds.
type IDEHostClaimedRequest struct {
	RequestID             string          `json:"requestID"`
	Name                  string          `json:"name"`
	Arguments             json.RawMessage `json:"arguments"`
	RemainingMilliseconds int64           `json:"remainingMilliseconds"`
}

// IDEHostRespondResult reports whether the broker still accepted the reply. A
// false value is not permission to replay the operation.
type IDEHostRespondResult struct {
	Delivered bool `json:"delivered"`
}

// IDEHostCloseResult is returned by close and closeOwner.
type IDEHostCloseResult struct {
	Closed bool `json:"closed"`
}

// IDEFailure is a tool-level failure with a shared error code (for example
// PERMISSION_DENIED or INVALID_ARGUMENTS).
type IDEFailure struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// IDEHostValidateResult is either {ok: true, mutation} or {error: {code, message}}.
type IDEHostValidateResult struct {
	OK       bool        `json:"ok"`
	Mutation bool        `json:"mutation"`
	Error    *IDEFailure `json:"error,omitempty"`
}

// IDEHostCatalogResult lists the tools admitted by a toolExposure selection.
type IDEHostCatalogResult struct {
	Version int               `json:"version"`
	Tools   []json.RawMessage `json:"tools"`
}

// IDEHostOpen opens a connection for one project. The owner is supplied by
// the native adapter, never by a client request.
func (c *Client) IDEHostOpen(ctx context.Context, request IDEHostOpenRequest) (IDEHostOpenResult, error) {
	var result IDEHostOpenResult
	raw, err := c.IDEHostControl(ctx, "open", request)
	if err != nil {
		return result, err
	}
	err = json.Unmarshal(raw, &result)
	return result, err
}

// IDEHostPoll returns the next queued request for one connection, if any.
func (c *Client) IDEHostPoll(ctx context.Context, hostID string) (IDEHostPollResult, error) {
	var result IDEHostPollResult
	raw, err := c.IDEHostControl(ctx, "poll", map[string]string{"hostID": hostID})
	if err != nil {
		return result, err
	}
	err = json.Unmarshal(raw, &result)
	return result, err
}

// IDEHostClaim atomically claims one unexpired, unclaimed request. Call it
// immediately before executing the application action.
func (c *Client) IDEHostClaim(ctx context.Context, hostID, requestID string) (IDEHostClaimResult, error) {
	var result IDEHostClaimResult
	raw, err := c.IDEHostControl(ctx, "claim", map[string]string{"hostID": hostID, "requestID": requestID})
	if err != nil {
		return result, err
	}
	err = json.Unmarshal(raw, &result)
	return result, err
}

// IDEHostRespond sends the result of a claimed request back to the broker.
func (c *Client) IDEHostRespond(ctx context.Context, hostID, requestID string, result any) (IDEHostRespondResult, error) {
	var out IDEHostRespondResult
	raw, err := c.IDEHostControl(ctx, "respond", map[string]any{"hostID": hostID, "requestID": requestID, "result": result})
	if err != nil {
		return out, err
	}
	err = json.Unmarshal(raw, &out)
	return out, err
}

// IDEHostClose revokes one connection.
func (c *Client) IDEHostClose(ctx context.Context, hostID string) (IDEHostCloseResult, error) {
	var out IDEHostCloseResult
	raw, err := c.IDEHostControl(ctx, "close", map[string]string{"hostID": hostID})
	if err != nil {
		return out, err
	}
	err = json.Unmarshal(raw, &out)
	return out, err
}

// IDEHostCloseOwner revokes the connection owned by ownerID. The field keeps
// the spelling "ownerID", as the Core contract does.
func (c *Client) IDEHostCloseOwner(ctx context.Context, ownerID string) (IDEHostCloseResult, error) {
	var out IDEHostCloseResult
	raw, err := c.IDEHostControl(ctx, "closeOwner", map[string]string{"ownerID": ownerID})
	if err != nil {
		return out, err
	}
	err = json.Unmarshal(raw, &out)
	return out, err
}

// IDEHostValidate checks one call against the grants before it is queued.
func (c *Client) IDEHostValidate(ctx context.Context, name string, arguments any, permissions IDEPermissions, toolExposure []IDEToolExposure) (IDEHostValidateResult, error) {
	var out IDEHostValidateResult
	args := map[string]any{"name": name, "arguments": arguments, "permissions": permissions}
	if toolExposure != nil {
		args["toolExposure"] = toolExposure
	}
	raw, err := c.IDEHostControl(ctx, "validate", args)
	if err != nil {
		return out, err
	}
	err = json.Unmarshal(raw, &out)
	return out, err
}

// IDEHostCatalog lists the tools a toolExposure selection admits.
func (c *Client) IDEHostCatalog(ctx context.Context, toolExposure []IDEToolExposure) (IDEHostCatalogResult, error) {
	var out IDEHostCatalogResult
	args := map[string]any{}
	if toolExposure != nil {
		args["toolExposure"] = toolExposure
	}
	raw, err := c.IDEHostControl(ctx, "catalog", args)
	if err != nil {
		return out, err
	}
	err = json.Unmarshal(raw, &out)
	return out, err
}

// IDEHostOutputPage returns one page of an operation snapshot's output. snapshot carries the
// operation's complete retained output in "output"; Core answers the same snapshot with at most
// 32 KiB of it after cursor and adds nextCursor, hasMore and reset. An empty cursor reads from
// the start, and a cursor whose consumed prefix changed reports reset.
func (c *Client) IDEHostOutputPage(ctx context.Context, snapshot any, cursor string) (json.RawMessage, error) {
	args := map[string]any{"snapshot": snapshot}
	if cursor != "" {
		args["cursor"] = cursor
	}
	return c.IDEHostControl(ctx, "output", args)
}

// IDEHostControl sends one ideHost.control action to the local capability
// broker and returns the raw result. Actions are open, close, closeOwner, poll,
// claim, respond, catalog, validate and output; see Lithe-core-rust rust/contracts/ide-api/v1.md.
func (c *Client) IDEHostControl(ctx context.Context, action string, arguments any) (json.RawMessage, error) {
	var result json.RawMessage
	err := c.Execute(ctx, "ideHost.control", struct {
		Action    string `json:"action"`
		Arguments any    `json:"arguments"`
	}{action, arguments}, &result)
	return result, err
}
