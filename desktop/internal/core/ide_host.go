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

// IDEHostOpenResult is the descriptor returned when a project connection opens.
// Configuration is the client configuration (helper path and descriptor path,
// never a bearer credential) that the user copies.
type IDEHostOpenResult struct {
	HostID        string          `json:"hostID"`
	Configuration json.RawMessage `json:"configuration"`
}

// IDEHostRequest is one request the broker has queued for the native
// dispatcher. Name and Arguments are untrusted client input.
type IDEHostRequest struct {
	RequestID string          `json:"requestID"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// IDEHostPollResult lists requests waiting for dispatch on one connection.
type IDEHostPollResult struct {
	Requests []IDEHostRequest `json:"requests"`
}

// IDEHostClaimResult carries a nil Request when the request expired, was
// cancelled or was already claimed. Claim before any application action.
type IDEHostClaimResult struct {
	Request *IDEHostClaimedRequest `json:"request"`
}

// IDEHostClaimedRequest is a claimed request with the remaining deadline in
// milliseconds. Execute only while RemainingMilliseconds is positive.
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

// IDEHostOpen opens a connection for one project. Permissions are the
// configure and execute grants, both disabled unless the user enables them.
// OwnerID is supplied by the native adapter, not by the client.
func (c *Client) IDEHostOpen(ctx context.Context, workspace, ownerID string, permissions map[string]bool, toolExposure []IDEToolExposure) (IDEHostOpenResult, error) {
	var result IDEHostOpenResult
	args := map[string]any{
		"workspace":   workspace,
		"ownerId":     ownerID,
		"permissions": permissions,
	}
	if toolExposure != nil {
		args["toolExposure"] = toolExposure
	}
	raw, err := c.IDEHostControl(ctx, "open", args)
	if err != nil {
		return result, err
	}
	err = json.Unmarshal(raw, &result)
	return result, err
}

// IDEHostPoll returns queued requests for one connection without claiming them.
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
func (c *Client) IDEHostClose(ctx context.Context, hostID string) error {
	_, err := c.IDEHostControl(ctx, "close", map[string]string{"hostID": hostID})
	return err
}
