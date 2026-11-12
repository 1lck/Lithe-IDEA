package core

import (
	"context"
	"encoding/json"
)

// DecodeEditorActions has Core validate an independent editor action message: a registration, the
// actions a collection function answered for a document, or the result of a clicked action. The
// payload is the contract's `{kind, value, ...}` shape; the answer is returned as Core shaped it.
func (c *Client) DecodeEditorActions(ctx context.Context, payload any) (json.RawMessage, error) {
	var result json.RawMessage
	if err := c.Execute(ctx, "plugins.editorActions.decode", payload, &result); err != nil {
		return nil, err
	}
	return result, nil
}

// DecodeEditorProviders has Core validate an editor provider message: a registration, or one provider
// function's answer. It is the same contract shape as DecodeEditorActions.
func (c *Client) DecodeEditorProviders(ctx context.Context, payload any) (json.RawMessage, error) {
	var result json.RawMessage
	if err := c.Execute(ctx, "plugins.editorProviders.decode", payload, &result); err != nil {
		return nil, err
	}
	return result, nil
}
