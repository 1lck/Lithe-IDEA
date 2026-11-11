package workbench

import (
	"encoding/json"
	"slices"
)

// ideAPIBuildConfigure sets one declared Build option of an instance through the same local-document edit
// the Build options dialog uses. The value is a string, a boolean, a list of strings or null, which removes
// the local override. The answer comes before the detection reads the value back; the instance shows it when
// the detection finishes.
func (a *App) ideAPIBuildConfigure(p *project, instanceID, optionID string, raw json.RawMessage) any {
	instance := p.buildInstanceByID(instanceID)
	if instance == nil {
		return ideAPIFailure("INVALID_ARGUMENTS", "Unknown build instance")
	}
	if p.build.operation != nil {
		return ideAPIFailure("BUSY", "A Build execution is running")
	}
	if p.build.loading {
		return ideAPIFailure("BUSY", "The build model is loading")
	}
	declared := declaredOptionFields(instance.Manifest, instance.BuildSystemID, nil)
	if !slices.ContainsFunc(declared, func(field runOptionField) bool { return field.id == optionID }) {
		return ideAPIFailure("INVALID_ARGUMENTS", "Unknown build option")
	}
	var value any
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &value); err != nil {
			return ideAPIFailure("INVALID_ARGUMENTS", "value must be a string, a boolean, a list of strings or null")
		}
	}
	a.saveBuildOptionChanges(p, *instance, []buildOptionChange{{optionID: optionID, value: value}}, func(err error) {
		if err != nil {
			p.build.status = err.Error()
		}
	})
	return map[string]any{"instanceID": instanceID, "optionID": optionID, "reloading": true}
}
