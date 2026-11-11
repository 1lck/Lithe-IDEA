package workbench

import (
	"encoding/json"
	"errors"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// ideAPIBuildConfigure sets one declared Build option of an instance through the same local-document edit
// the Build options dialog uses. The value is a string, a boolean, a list of strings or null, which removes
// the local override. Core checks the value before anything is stored; the answer arrives on the returned
// channel once the edit was refused or stored, with the option as Core read it back from the edited
// documents. The instance is detected again afterwards, which reloading reports.
func (a *App) ideAPIBuildConfigure(p *project, instanceID, optionID string, raw json.RawMessage) (<-chan any, any) {
	instance := p.buildInstanceByID(instanceID)
	if instance == nil {
		return nil, ideAPIFailure("NOT_FOUND", "Unknown build instance")
	}
	if p.build.operation != nil {
		return nil, ideAPIFailure("BUSY", "A Build execution is active")
	}
	if p.build.loading || instance.modelLoading {
		return nil, ideAPIFailure("BUSY", "The build model is loading")
	}
	if p.build.options.open || p.build.options.saving {
		return nil, ideAPIFailure("BUSY", "The Build options dialog is open")
	}
	declared := declaredOptionFields(instance.Manifest, instance.BuildSystemID, nil)
	if !slices.ContainsFunc(declared, func(field runOptionField) bool { return field.id == optionID }) {
		return nil, ideAPIFailure("NOT_FOUND", "Unknown build option")
	}
	var value any
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &value); err != nil {
			return nil, ideAPIFailure("INVALID_ARGUMENTS", "value must be a string, a boolean, a list of strings or null")
		}
	}
	answer := make(chan any, 1)
	a.saveBuildOptionChanges(p, *instance, []buildOptionChange{{optionID: optionID, value: value}}, func(options json.RawMessage, err error) {
		answer <- ideAPIConfiguredOption(instanceID, optionID, options, err)
	})
	return answer, nil
}

// ideAPIConfiguredOption is the answer of one option edit: the persisted value and its source as Core
// read them back, Core's refusal of the value, or why the edit could not be stored.
func ideAPIConfiguredOption(instanceID, optionID string, options json.RawMessage, err error) any {
	var rejection *core.MarketplaceRejection
	switch {
	case errors.As(err, &rejection):
		return ideAPIFailure("INVALID_ARGUMENTS", rejection.Message)
	case err != nil:
		return ideAPIFailure("OPERATION_FAILED", err.Error())
	}
	var described struct {
		Options []struct {
			ID     string `json:"id"`
			Value  any    `json:"value"`
			Source string `json:"source"`
		} `json:"options"`
	}
	if err := json.Unmarshal(options, &described); err != nil {
		return ideAPIFailure("OPERATION_FAILED", "The edited option could not be read back")
	}
	for _, state := range described.Options {
		if state.ID == optionID {
			return map[string]any{
				"instanceID": instanceID,
				"optionID":   optionID,
				"value":      state.Value,
				"source":     state.Source,
				"reloading":  true,
			}
		}
	}
	return ideAPIFailure("OPERATION_FAILED", "The edited option could not be read back")
}
