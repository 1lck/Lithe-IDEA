package core

import (
	"context"
	"encoding/json"
)

// RunConfigDiagnostic is one finding of a run configuration inspection, such as
// staleFingerprint, staleProviderModel or incompleteProjectScan.
type RunConfigDiagnostic struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// RunConfigGenerated is Core's detected run configuration layer. The entries
// stay raw: their fields differ by type and the host only lists and forwards
// them, so Core remains the one place that knows their shape.
type RunConfigGenerated struct {
	Version        int               `json:"version"`
	Configurations []json.RawMessage `json:"configurations"`
}

// RunConfigInspection is what `runConfig.inspect` reports about a workspace.
// Inspecting never writes a file.
type RunConfigInspection struct {
	// Status is "ready" when a detected or saved run exists, else "missing".
	Status             string                `json:"status"`
	RequiresGeneration bool                  `json:"requiresGeneration"`
	Generated          *RunConfigGenerated   `json:"generated"`
	Diagnostics        []RunConfigDiagnostic `json:"diagnostics"`
	Paths              struct {
		Configurations string `json:"configurations"`
		Local          string `json:"local"`
	} `json:"paths"`
	ToolchainRequirements json.RawMessage `json:"toolchainRequirements"`
	LocalToolchains       json.RawMessage `json:"localToolchains"`
}

// InspectRunConfigurations inspects the `.lithe` run documents of root: their
// versions and whether the detected layer is stale. providerRuns is the
// complete generic run selector list of the build providers, or nil for older
// callers; checkFingerprint false skips source hashing for a settings-only read.
func (c *Client) InspectRunConfigurations(ctx context.Context, root string, providerRuns json.RawMessage, checkFingerprint *bool) (RunConfigInspection, error) {
	var result RunConfigInspection
	request := struct {
		Root             string          `json:"root"`
		CheckFingerprint *bool           `json:"checkFingerprint,omitempty"`
		ProviderRuns     json.RawMessage `json:"providerRuns,omitempty"`
	}{root, checkFingerprint, providerRuns}
	if err := c.Execute(ctx, "runConfig.inspect", request, &result); err != nil {
		return RunConfigInspection{}, err
	}
	return result, nil
}

// RunConfigGeneration is the outcome of detecting runnable entries.
type RunConfigGeneration struct {
	Generated             RunConfigGenerated `json:"generated"`
	ToolchainRequirements json.RawMessage    `json:"toolchainRequirements"`
	EntryCount            int                `json:"entryCount"`
}

// GenerateRunConfigurations detects the runnable entries of root and replaces
// the in-memory detected layer. Nothing is written into the workspace; a
// non-empty cacheDirectory (outside it) lets the next session list the entries
// before the providers answer.
func (c *Client) GenerateRunConfigurations(ctx context.Context, root, cacheDirectory string, providerRuns json.RawMessage) (RunConfigGeneration, error) {
	var result RunConfigGeneration
	request := struct {
		Root           string          `json:"root"`
		ProviderRuns   json.RawMessage `json:"providerRuns,omitempty"`
		CacheDirectory string          `json:"cacheDirectory,omitempty"`
	}{root, providerRuns, cacheDirectory}
	if err := c.Execute(ctx, "runConfig.generate", request, &result); err != nil {
		return RunConfigGeneration{}, err
	}
	return result, nil
}

// ExecutionEnvironmentRequest is the input of the launch environment merge.
// Overrides values are either a string or a {toolchain, property} binding; a
// binding the host could not resolve to text contributes nothing. A runtime
// home such as JAVA_HOME is not chosen here: it comes from the toolchain
// installation the step selected (applyToolchainSelection in the workbench).
type ExecutionEnvironmentRequest struct {
	Inherited       map[string]string `json:"inherited"`
	Overrides       map[string]any    `json:"overrides"`
	CaseInsensitive bool              `json:"caseInsensitive"`
}

// ResolveExecutionEnvironment merges inherited values and the explicit
// overrides into the environment a launch uses; overrides win.
func (c *Client) ResolveExecutionEnvironment(ctx context.Context, request ExecutionEnvironmentRequest) (map[string]string, error) {
	if request.Inherited == nil {
		request.Inherited = map[string]string{}
	}
	if request.Overrides == nil {
		request.Overrides = map[string]any{}
	}
	var result struct {
		Environment map[string]string `json:"environment"`
	}
	if err := c.Execute(ctx, "execution.resolveEnvironment", request, &result); err != nil {
		return nil, err
	}
	return result.Environment, nil
}

// SearchPathCandidate is one directory a platform wants on the search path.
type SearchPathCandidate struct {
	Priority int    `json:"priority"`
	ID       string `json:"id"`
	Path     string `json:"path"`
}

// ResolveSearchPath keeps the existing entries' precedence, adds the candidates
// sorted by priority then identity and drops duplicates under the case policy.
func (c *Client) ResolveSearchPath(ctx context.Context, existing []string, candidates []SearchPathCandidate, caseInsensitive bool) ([]string, error) {
	if existing == nil {
		existing = []string{}
	}
	if candidates == nil {
		candidates = []SearchPathCandidate{}
	}
	var result []string
	if err := c.Execute(ctx, "execution.resolveSearchPath", struct {
		Existing        []string              `json:"existing"`
		Candidates      []SearchPathCandidate `json:"candidates"`
		CaseInsensitive bool                  `json:"caseInsensitive"`
	}{existing, candidates, caseInsensitive}, &result); err != nil {
		return nil, err
	}
	return result, nil
}
