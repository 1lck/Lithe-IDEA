package core

import (
	"context"
	"encoding/json"
)

// RunStartExecutable names the program of a plugin-started run. Kind is
// "toolchain" (Value is a tool definition ID the manifest requires) or
// "packaged" (Value is a normalized path inside the plugin package).
type RunStartExecutable struct {
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

// RunStartFile is a temporary file the host writes before the process starts.
type RunStartFile struct {
	Path     string `json:"path"`
	Contents string `json:"contents"`
}

// RunStartDebug makes a run a debug session. Target.Kind is "connection" (the
// process listens on Port and the host attaches) or "launch".
type RunStartDebug struct {
	ConfigurationType string `json:"configurationType"`
	Target            struct {
		Kind string `json:"kind"`
		Port int    `json:"port,omitempty"`
	} `json:"target"`
}

// RunStartRerun is the plugin function the host calls to restart a run.
type RunStartRerun struct {
	Function string          `json:"function"`
	Data     json.RawMessage `json:"data"`
}

// RunStart is the normalized `run/start` request Core decoded.
type RunStart struct {
	Label            string             `json:"label"`
	Executable       RunStartExecutable `json:"executable"`
	Arguments        []string           `json:"arguments"`
	WorkingDirectory string             `json:"workingDirectory"`
	Environment      map[string]string  `json:"environment"`
	TemporaryFiles   []RunStartFile     `json:"temporaryFiles"`
	Debug            *RunStartDebug     `json:"debug"`
	Rerun            *RunStartRerun     `json:"rerun"`
}

// DecodeRunStart validates the params of a backend's `lithe/host/run/start`
// against the plugin manifest. A refusal is a *MarketplaceRejection whose Code
// is plugin.run.invalidStart and whose Field names the offending member.
// temporaryDirectory is required only when the run has temporary files.
func (c *Client) DecodeRunStart(ctx context.Context, manifest json.RawMessage, workspaceRoot, temporaryDirectory string, params json.RawMessage) (RunStart, error) {
	const command = "run.decodeStart"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Start  RunStart              `json:"start"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest           json.RawMessage `json:"manifest"`
		WorkspaceRoot      string          `json:"workspaceRoot"`
		TemporaryDirectory string          `json:"temporaryDirectory,omitempty"`
		Params             json.RawMessage `json:"params"`
	}{manifest, workspaceRoot, temporaryDirectory, params}, &result); err != nil {
		return RunStart{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return RunStart{}, result.Error
	}
	if result.Status != "ok" {
		return RunStart{}, newParseError(command, "invalid run start outcome", "")
	}
	return result.Start, nil
}

// DebugTransportLimits are Core's deadlines and budgets for one IDE-to-adapter
// byte stream, in milliseconds, bytes and frame counts.
type DebugTransportLimits struct {
	DiscoveryMilliseconds int `json:"discoveryMilliseconds"`
	ConnectMilliseconds   int `json:"connectMilliseconds"`
	WriteMilliseconds     int `json:"writeMilliseconds"`
	BufferedBytes         int `json:"bufferedBytes"`
	BufferedWrites        int `json:"bufferedWrites"`
	DrainMilliseconds     int `json:"drainMilliseconds"`
}

// DebugTransportPolicy is Core's transport policy, including the session
// `initialize` deadline that must outlast a connect.
type DebugTransportPolicy struct {
	Limits                     DebugTransportLimits `json:"limits"`
	InitializationMilliseconds int                  `json:"initializationMilliseconds"`
}

// DebugTransportPolicy asks Core for the default byte-stream deadlines. It
// creates no state.
func (c *Client) DebugTransportPolicy(ctx context.Context) (DebugTransportPolicy, error) {
	var policy DebugTransportPolicy
	if err := c.Execute(ctx, "debug.transport.policy", nil, &policy); err != nil {
		return DebugTransportPolicy{}, err
	}
	return policy, nil
}
