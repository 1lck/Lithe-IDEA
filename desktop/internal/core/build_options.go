package core

import (
	"context"
	"encoding/json"
)

// BuildDetectOptions are the stored option inputs of build.detect: values by build system and option ID,
// instance values by root, instance defaults and the explicit empty selections. Core merges them into each
// instance's options and names the rejected ones in droppedOptions. IgnoredPaths are the directories the
// scan does not enter; nil is Core's default, every directory whose name starts with a dot, and an empty
// list ignores nothing beyond the shared scan policy.
type BuildDetectOptions struct {
	Options          map[string]map[string]json.RawMessage            `json:"options,omitempty"`
	InstanceOptions  map[string]map[string]map[string]json.RawMessage `json:"instanceOptions,omitempty"`
	InstanceDefaults map[string]map[string]json.RawMessage            `json:"instanceDefaults,omitempty"`
	EmptySelections  map[string]map[string][]string                   `json:"emptySelections,omitempty"`
	IgnoredPaths     []string                                         `json:"ignoredPaths"`
}

// BuildStoredOptions is the checked merge of the team document and the platform-local document that
// build.resolveStoredOptions returns. Document is the merged document, Local the validated local one, and
// IgnoredPaths the list build detection uses with the layer it came from.
type BuildStoredOptions struct {
	Document        json.RawMessage                `json:"document"`
	Local           json.RawMessage                `json:"local"`
	EmptySelections map[string]map[string][]string `json:"emptySelections"`
	IgnoredPaths    BuildIgnoredPaths              `json:"ignoredPaths"`
}

// The layers an ignored-path list comes from: the local document, the team document, or neither, when
// Core's default applies.
const (
	BuildIgnoredPathsLocal   = "local"
	BuildIgnoredPathsTeam    = "team"
	BuildIgnoredPathsDefault = "default"
)

// BuildIgnoredPaths are the .gitignore patterns, relative to the workspace root, of the directories build
// detection does not enter, and the layer that set them: a local list replaces the team's whole.
type BuildIgnoredPaths struct {
	Patterns []string `json:"patterns"`
	Source   string   `json:"source"`
}

// BuildIgnoredPathsEditRequest replaces the local ignored-path list with Patterns, an empty list being the
// explicit choice to ignore nothing, or removes it when Inherit is set, so the team list or Core's default
// applies again.
type BuildIgnoredPathsEditRequest struct {
	Document json.RawMessage
	Local    json.RawMessage
	Patterns []string
	Inherit  bool
}

// BuildIgnoredPathsEdit is the local document after an ignored-path edit and the list that applies with it.
type BuildIgnoredPathsEdit struct {
	Local        json.RawMessage   `json:"local"`
	IgnoredPaths BuildIgnoredPaths `json:"ignoredPaths"`
}

// BuildOptionEditRequest changes one declared local preference of an instance. A nil Value (when
// HasSelectedChoices is false) removes the local override, so the team or declaration value applies
// again. When HasSelectedChoices is true, Core encodes SelectedChoices against the model's defaults
// and exclusion prefix, clearing the local override when no team override exists and the checked
// choices equal the defaults.
type BuildOptionEditRequest struct {
	Document             json.RawMessage
	Local                json.RawMessage
	Root                 string
	OptionID             string
	Value                any
	SelectedChoices      []string
	HasSelectedChoices   bool
	ModelValues          map[string][]string
	ModelDefaults        map[string][]string
	ModelExcludePrefixes map[string]string
	ModelSelection       *BuildModelOptionSelection
}

// BuildOptionEdit is the local document after an edit and the effective options Core checked against it.
type BuildOptionEdit struct {
	Local   json.RawMessage `json:"local"`
	Options json.RawMessage `json:"options"`
}

// BuildResolveOptionsRequest asks Core (build.resolveOptions) for a build system's declared options,
// their effective values, and the choices the UI should offer. SelectedChoices, when given, encodes
// the positive choices checked in an option editor into Options before resolution.
type BuildResolveOptionsRequest struct {
	Options              map[string]json.RawMessage `json:"options,omitempty"`
	InheritedOptions     map[string]json.RawMessage `json:"inheritedOptions,omitempty"`
	SelectedChoices      map[string][]string        `json:"selectedChoices,omitempty"`
	ModelValues          map[string][]string        `json:"modelValues,omitempty"`
	ModelDefaults        map[string][]string        `json:"modelDefaults,omitempty"`
	ModelExcludePrefixes map[string]string          `json:"modelExcludePrefixes,omitempty"`
	ModelSelection       *BuildModelOptionSelection `json:"modelSelection,omitempty"`
}

// BuildResolvedOptions is Core's answer to build.resolveOptions.
type BuildResolvedOptions struct {
	Options     []BuildResolvedOption `json:"options"`
	Dropped     []string              `json:"dropped"`
	Fingerprint string                `json:"fingerprint"`
}

// BuildResolvedOption is one declared build option as Core resolved it for display and editing.
type BuildResolvedOption struct {
	ID              string                `json:"id"`
	DisplayName     string                `json:"displayName"`
	Kind            string                `json:"kind"`
	Scope           string                `json:"scope,omitempty"`
	Value           json.RawMessage       `json:"value"`
	SelectedChoices []string              `json:"selectedChoices"`
	Source          string                `json:"source"`
	Choices         []BuildResolvedChoice `json:"choices"`
	AllowCustom     bool                  `json:"allowCustom"`
	// Description is what the option does, from the manifest, for the ⓘ next to it.
	Description string `json:"description,omitempty"`
	// ImplicitValue is what the build tool uses for an unset text, file or directory option, as the loaded
	// model reported it (Maven's user settings file). It is shown only; Core passes nothing for it.
	ImplicitValue string `json:"implicitValue,omitempty"`
}

// BuildResolvedChoice is one choice of a single-select or multi-select build option.
type BuildResolvedChoice struct {
	Value         string `json:"value"`
	Title         string `json:"title"`
	FromModel     bool   `json:"fromModel"`
	Custom        bool   `json:"custom"`
	DefaultActive bool   `json:"defaultActive"`
}

// ResolveStoredBuildOptions checks the team document and the local document against each other. It reads
// and writes no file; the host supplies both documents as they are stored.
func (c *Client) ResolveStoredBuildOptions(ctx context.Context, document, local json.RawMessage) (BuildStoredOptions, error) {
	const command = "build.resolveStoredOptions"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Document json.RawMessage `json:"document"`
		Local    json.RawMessage `json:"local"`
	}{document, local}, &result); err != nil {
		return BuildStoredOptions{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildStoredOptions{}, err
	}
	if result.Storage == nil {
		return BuildStoredOptions{}, newParseError(command, "build.resolveStoredOptions returned no storage", "")
	}
	return *result.Storage, nil
}

// ResolveBuildOptions resolves the declared options of a build system against stored values and
// optional model facts (build.resolveOptions).
func (c *Client) ResolveBuildOptions(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildResolveOptionsRequest) (BuildResolvedOptions, error) {
	const command = "build.resolveOptions"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage            `json:"manifest"`
		BuildSystemID string                     `json:"buildSystemID"`
		Request       BuildResolveOptionsRequest `json:"request"`
	}{manifest, buildSystemID, request}, &result); err != nil {
		return BuildResolvedOptions{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildResolvedOptions{}, err
	}
	if result.Options == nil {
		return BuildResolvedOptions{}, newParseError(command, "build.resolveOptions returned no options", "")
	}
	return *result.Options, nil
}

// EditStoredBuildOption applies one option edit to the local document of an instance, in the standard
// manifest and build-system envelope. The host writes edit.Local itself, atomically, and reads it back.
func (c *Client) EditStoredBuildOption(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildOptionEditRequest) (BuildOptionEdit, error) {
	const command = "build.editStoredOption"
	payload := map[string]any{
		"document": request.Document,
		"local":    request.Local,
		"root":     request.Root,
		"optionID": request.OptionID,
	}
	if request.HasSelectedChoices {
		selected := request.SelectedChoices
		if selected == nil {
			selected = []string{}
		}
		payload["selectedChoices"] = selected
	} else {
		payload["value"] = request.Value
	}
	if request.ModelValues != nil {
		payload["modelValues"] = request.ModelValues
	}
	if request.ModelDefaults != nil {
		payload["modelDefaults"] = request.ModelDefaults
	}
	if request.ModelExcludePrefixes != nil {
		payload["modelExcludePrefixes"] = request.ModelExcludePrefixes
	}
	if request.ModelSelection != nil {
		payload["modelSelection"] = request.ModelSelection
	}
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage `json:"manifest"`
		BuildSystemID string          `json:"buildSystemID"`
		Request       map[string]any  `json:"request"`
	}{manifest, buildSystemID, payload}, &result); err != nil {
		return BuildOptionEdit{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildOptionEdit{}, err
	}
	if result.Edit == nil {
		return BuildOptionEdit{}, newParseError(command, "build.editStoredOption returned no edit", "")
	}
	return *result.Edit, nil
}

// EditBuildIgnoredPaths applies an ignored-path edit to the local document. It reads and writes no file: the
// team document is only read, and the host writes edit.Local itself, atomically, and reads it back. Core
// refuses a list it cannot use with plugin.build.invalidIgnoredPath at ignoredPaths[<index>], the first
// pattern not accepted, or at ignoredPaths when the patterns cannot be used together.
func (c *Client) EditBuildIgnoredPaths(ctx context.Context, request BuildIgnoredPathsEditRequest) (BuildIgnoredPathsEdit, error) {
	const command = "build.editIgnoredPaths"
	// patterns is null to remove the local list, and a list, empty or not, to replace it.
	var patterns any
	if !request.Inherit {
		patterns = append([]string{}, request.Patterns...)
	}
	// Both commands answer under edit; this one with the ignored paths in place of the options.
	var result struct {
		buildOutcome
		Edit *BuildIgnoredPathsEdit `json:"edit"`
	}
	if err := c.Execute(ctx, command, struct {
		Document json.RawMessage `json:"document"`
		Local    json.RawMessage `json:"local"`
		Patterns any             `json:"patterns"`
	}{request.Document, request.Local, patterns}, &result); err != nil {
		return BuildIgnoredPathsEdit{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildIgnoredPathsEdit{}, err
	}
	if result.Edit == nil {
		return BuildIgnoredPathsEdit{}, newParseError(command, "build.editIgnoredPaths returned no edit", "")
	}
	return *result.Edit, nil
}

// ResolveStoredInstanceOptions returns the declared effective options for one
// build root using Core's team/local preference resolution.
func (c *Client) ResolveStoredInstanceOptions(ctx context.Context, manifest json.RawMessage, systemID, root string, team, local json.RawMessage) (json.RawMessage, error) {
	const command = "build.resolveStoredInstanceOptions"
	var result struct {
		buildOutcome
		Values json.RawMessage `json:"options"`
	}
	payload := map[string]any{
		"manifest":      manifest,
		"buildSystemID": systemID,
		"request":       map[string]any{"root": root, "document": team, "local": local},
	}
	if err := c.Execute(ctx, command, payload, &result); err != nil {
		return nil, err
	}
	if err := result.failure(command); err != nil {
		return nil, err
	}
	if len(result.Values) == 0 {
		return nil, newParseError(command, "build.resolveStoredInstanceOptions returned no options", "")
	}
	return result.Values, nil
}
