package core

import (
	"context"
	"encoding/json"
)

// BuildDetectOptions are the stored option inputs of build.detect: values by build system and option ID,
// instance values by root, instance defaults and the explicit empty selections. Core merges them into each
// instance's options and names the rejected ones in droppedOptions.
type BuildDetectOptions struct {
	Options          map[string]map[string]json.RawMessage            `json:"options,omitempty"`
	InstanceOptions  map[string]map[string]map[string]json.RawMessage `json:"instanceOptions,omitempty"`
	InstanceDefaults map[string]map[string]json.RawMessage            `json:"instanceDefaults,omitempty"`
	EmptySelections  map[string]map[string][]string                   `json:"emptySelections,omitempty"`
}

// BuildStoredOptions is the checked merge of the team document and the platform-local document that
// build.resolveStoredOptions returns. Document is the merged document, Local the validated local one.
type BuildStoredOptions struct {
	Document        json.RawMessage                `json:"document"`
	Local           json.RawMessage                `json:"local"`
	EmptySelections map[string]map[string][]string `json:"emptySelections"`
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
