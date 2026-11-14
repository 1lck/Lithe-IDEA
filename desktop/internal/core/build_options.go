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

// BuildOptionEditRequest changes one declared local preference of an instance. A nil Value removes the local
// override, so the team or declaration value applies again. A list is sent as given, an empty list being the
// explicit empty selection.
type BuildOptionEditRequest struct {
	Document json.RawMessage
	Local    json.RawMessage
	Root     string
	OptionID string
	Value    any
}

// BuildOptionEdit is the local document after an edit and the effective options Core checked against it.
type BuildOptionEdit struct {
	Local   json.RawMessage `json:"local"`
	Options json.RawMessage `json:"options"`
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

// EditStoredBuildOption applies one option edit to the local document of an instance, in the standard
// manifest and build-system envelope. The host writes edit.Local itself, atomically, and reads it back.
func (c *Client) EditStoredBuildOption(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildOptionEditRequest) (BuildOptionEdit, error) {
	const command = "build.editStoredOption"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage `json:"manifest"`
		BuildSystemID string          `json:"buildSystemID"`
		Request       struct {
			Document json.RawMessage `json:"document"`
			Local    json.RawMessage `json:"local"`
			Root     string          `json:"root"`
			OptionID string          `json:"optionID"`
			Value    any             `json:"value"`
		} `json:"request"`
	}{manifest, buildSystemID, struct {
		Document json.RawMessage `json:"document"`
		Local    json.RawMessage `json:"local"`
		Root     string          `json:"root"`
		OptionID string          `json:"optionID"`
		Value    any             `json:"value"`
	}{request.Document, request.Local, request.Root, request.OptionID, request.Value}}, &result); err != nil {
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
