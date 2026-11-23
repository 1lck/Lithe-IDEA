package core

import "context"

// PluginWorkflow runs the shared workflow validator or a bounded projection.
// Callers send only one request, candidate set, or output increment.
func (c *Client) PluginWorkflow(ctx context.Context, request any, result any) error {
	return c.Execute(ctx, "plugins.workflow", request, result)
}
