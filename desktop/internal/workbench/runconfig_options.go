package workbench

import (
	"encoding/json"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The run configuration editor shows the build options its provider declares, so the user can override them
// for this run. The declarations are read from the plugin manifest of the run's detected instance, and the
// values are the configuration's own overrides, saved with the rest of the provider choices through the
// same updateOptions conflict check. A boolean is a checkbox; a single choice, a text, a file or a directory
// is a field. A multi-choice option is shown read-only as its JSON, since the editor has no list editor yet.

// runOptionChoice is one choice of a single-choice option.
type runOptionChoice struct {
	value, title string
}

// runOptionField is one declared option of the run's build system as the editor shows it. initial values are
// what the configuration held when the editor opened, so only a field the user changed is written back.
type runOptionField struct {
	id, title, kind string
	choices         []runOptionChoice
	flag, initFlag  bool
	text, initText  string
	// raw is the stored JSON of a kind the editor shows read-only.
	raw json.RawMessage
}

// runOptionDeclarations is the part of a plugin manifest the run option editor reads: the options of each
// build system, by ID.
type runOptionDeclarations struct {
	BuildSystems []struct {
		ID      string `json:"id"`
		Options []struct {
			ID          string `json:"id"`
			DisplayName string `json:"displayName"`
			Kind        string `json:"kind"`
			Choices     []struct {
				Value string `json:"value"`
				Title string `json:"title"`
			} `json:"choices"`
		} `json:"options"`
	} `json:"buildSystems"`
}

// runOptionFields makes the editor fields of a run's build system from its instance manifest, with the
// configuration's overrides as their values. Options the manifest does not declare are not shown; they stay
// in the configuration untouched.
func (p *project) runOptionFields(reference core.RunProviderReference, overrides map[string]json.RawMessage) []runOptionField {
	index := p.buildInstanceIndex(reference)
	if index < 0 {
		return nil
	}
	var declared runOptionDeclarations
	if json.Unmarshal(p.build.instances[index].Manifest, &declared) != nil {
		return nil
	}
	var fields []runOptionField
	for _, system := range declared.BuildSystems {
		if system.ID != reference.BuildSystemID {
			continue
		}
		for _, option := range system.Options {
			field := runOptionField{id: option.ID, title: option.DisplayName, kind: option.Kind}
			if field.title == "" {
				field.title = option.ID
			}
			for _, choice := range option.Choices {
				title := choice.Title
				if title == "" {
					title = choice.Value
				}
				field.choices = append(field.choices, runOptionChoice{value: choice.Value, title: title})
			}
			raw, stored := overrides[option.ID]
			switch {
			case option.Kind == "boolean" && stored:
				_ = json.Unmarshal(raw, &field.flag)
				field.initFlag = field.flag
			case (option.Kind == "text" || option.Kind == "file" || option.Kind == "directory" || option.Kind == "singleSelect") && stored:
				_ = json.Unmarshal(raw, &field.text)
				field.initText = field.text
			case option.Kind == "multiSelect" && stored:
				field.raw = raw
			}
			// A single choice without declared choices (they come from the model) cannot be edited here.
			if option.Kind == "singleSelect" && len(field.choices) == 0 || option.Kind == "multiSelect" {
				field.kind = "readonly"
				if field.raw == nil && stored {
					field.raw = raw
				}
			}
			fields = append(fields, field)
		}
	}
	return fields
}

// applyRunOptionFields writes the changed fields into the editor's overrides. A cleared text or choice removes
// the override, so the declaration applies again; a boolean is written once it differs from the stored value.
func applyRunOptionFields(e *runConfigEditor) {
	for _, field := range e.optionFields {
		switch field.kind {
		case "boolean":
			if field.flag == field.initFlag {
				continue
			}
			if e.options == nil {
				e.options = map[string]json.RawMessage{}
			}
			value, _ := json.Marshal(field.flag)
			e.options[field.id] = value
		case "text", "file", "directory", "singleSelect":
			if field.text == field.initText {
				continue
			}
			if field.text == "" {
				delete(e.options, field.id)
				continue
			}
			if e.options == nil {
				e.options = map[string]json.RawMessage{}
			}
			value, _ := json.Marshal(field.text)
			e.options[field.id] = value
		}
	}
}

// runOptionChoiceIDs splits the choices of a single-choice field into their values and a label lookup, with
// an empty first choice that removes the override.
func runOptionChoiceIDs(field runOptionField) ([]string, map[string]string) {
	values := []string{""}
	labels := map[string]string{"": ""}
	for _, choice := range field.choices {
		values = append(values, choice.value)
		labels[choice.value] = choice.title
	}
	return slices.Clip(values), labels
}
