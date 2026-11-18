package core

import (
	"context"
	"encoding/json"
)

// BuildRunEntrypoint is one entrypoint a provider found in a source file (buildProviders 1).
// Core checked that Run is an entrypoint run of the build system and that Project is inside
// the instance root; Entrypoint is opaque to the host and goes back as launchOptions.entrypoint.
type BuildRunEntrypoint struct {
	Run        string         `json:"run"`
	Name       string         `json:"name"`
	Entrypoint string         `json:"entrypoint"`
	Project    BuildSelection `json:"project"`
}

// BuildRunEntrypoints is Core's answer to build.decodeRunEntrypoints.
type BuildRunEntrypoints struct {
	Entrypoints []BuildRunEntrypoint `json:"entrypoints"`
}

// BuildDecodeRunEntrypointsRequest carries the plan context the request ran with and the
// litheRunEntrypoints document the provider answered.
type BuildDecodeRunEntrypointsRequest struct {
	Root                    string                     `json:"root"`
	Options                 map[string]json.RawMessage `json:"options,omitempty"`
	PluginDirectory         string                     `json:"pluginDirectory,omitempty"`
	WorkspaceStateDirectory string                     `json:"workspaceStateDirectory,omitempty"`
	Result                  json.RawMessage            `json:"result"`
}

// PlanBuildRunEntrypoints plans the provider request that names the entrypoints of
// request.File. Only a declaration with an entrypoint run accepts it; the request names a file,
// never a project or target.
func (c *Client) PlanBuildRunEntrypoints(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildPlanRequest) (BuildPlan, error) {
	return c.planBuild(ctx, "build.runEntrypointsPlan", manifest, buildSystemID, request)
}

// DecodeBuildRunEntrypoints validates a provider's entrypoints, in the provider's order without
// duplicates. Core rejects the whole document rather than offer a partial list.
func (c *Client) DecodeBuildRunEntrypoints(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildDecodeRunEntrypointsRequest) ([]BuildRunEntrypoint, error) {
	const command = "build.decodeRunEntrypoints"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage                  `json:"manifest"`
		BuildSystemID string                           `json:"buildSystemID"`
		Request       BuildDecodeRunEntrypointsRequest `json:"request"`
	}{manifest, buildSystemID, request}, &result); err != nil {
		return nil, err
	}
	if err := result.failure(command); err != nil {
		return nil, err
	}
	if result.Entrypoints == nil {
		return nil, newParseError(command, "run entrypoints returned no entrypoints", "")
	}
	return result.Entrypoints.Entrypoints, nil
}

// RunEntrypointConfigurationRequest saves the configuration that starts one entrypoint: a
// local build provider configuration whose reference names no target and whose
// extensions.build-run.entrypoint is Entrypoint. Saving the same entrypoint again answers the
// configuration already saved.
type RunEntrypointConfigurationRequest struct {
	Root       string               `json:"root"`
	Name       string               `json:"name"`
	Build      RunProviderReference `json:"build"`
	Entrypoint string               `json:"entrypoint"`
	Plugins    []RunInstalledPlugin `json:"plugins,omitempty"`
}

// CreateRunEntrypointConfiguration returns the ID of the configuration that starts the
// entrypoint and the file changes that save it. Core writes nothing.
func (c *Client) CreateRunEntrypointConfiguration(ctx context.Context, request RunEntrypointConfigurationRequest) (string, []RunConfigChange, error) {
	var result struct {
		ID      string            `json:"id"`
		Changes []RunConfigChange `json:"changes"`
	}
	err := c.Execute(ctx, "runConfig.createUserConfiguration", struct {
		RunEntrypointConfigurationRequest
		Scope string `json:"scope"`
		Kind  string `json:"type"`
	}{request, "local", "buildProvider"}, &result)
	return result.ID, result.Changes, err
}
