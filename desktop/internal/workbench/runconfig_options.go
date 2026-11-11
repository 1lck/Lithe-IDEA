package workbench

import (
	"encoding/json"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The run configuration editor and the Build options editor show the build options a plugin declares, from
// the plugin manifest of the detected instance. A value is kept as the stored JSON; only a field the user
// changed is written back, through the same Core edit that the caller uses. A boolean is a checkbox, a single
// choice a picker, a text, file or directory a text field, and a multi-choice with declared choices a list of
// checkboxes. Options whose choices come from the model, and kinds the editor cannot edit, show read-only.

// runOptionChoice is one declared choice of a single or multi choice option.
type runOptionChoice struct {
	value, title string
}

// runOptionField is one declared option as the editor shows it. The init fields are what the value was when
// the editor opened, so a change is detected by comparison.
type runOptionField struct {
	id, title, kind string
	choices         []runOptionChoice
	flag, initFlag  bool
	text, initText  string
	picks, initPick []bool
	// raw is the stored JSON of a kind the editor shows read-only.
	raw json.RawMessage
}

// runOptionDeclarations is the part of a plugin manifest the option editors read: the options of each build
// system, by ID.
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

// declaredOptionFields makes the fields of one build system's declared options from its manifest, with the
// stored values as their values. Options the manifest does not declare are not shown.
func declaredOptionFields(manifest json.RawMessage, buildSystemID string, values map[string]json.RawMessage) []runOptionField {
	var declared runOptionDeclarations
	if json.Unmarshal(manifest, &declared) != nil {
		return nil
	}
	var fields []runOptionField
	for _, system := range declared.BuildSystems {
		if system.ID != buildSystemID {
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
			raw, stored := values[option.ID]
			switch {
			case option.Kind == "boolean" && stored:
				_ = json.Unmarshal(raw, &field.flag)
				field.initFlag = field.flag
			case (option.Kind == "text" || option.Kind == "file" || option.Kind == "directory" || option.Kind == "singleSelect") && stored:
				_ = json.Unmarshal(raw, &field.text)
				field.initText = field.text
			}
			if option.Kind == "multiSelect" && len(field.choices) > 0 {
				var selected []string
				if stored && json.Unmarshal(raw, &selected) == nil {
					field.picks = make([]bool, len(field.choices))
					for index, choice := range field.choices {
						field.picks[index] = slices.Contains(selected, choice.value)
					}
				} else {
					field.picks = make([]bool, len(field.choices))
				}
				field.initPick = slices.Clone(field.picks)
			}
			if (option.Kind == "singleSelect" && len(field.choices) == 0) || (option.Kind == "multiSelect" && len(field.choices) == 0) {
				field.kind = "readonly"
			}
			if option.Kind == "multiSelect" && len(field.choices) == 0 && stored {
				field.raw = raw
			}
			if !slices.Contains([]string{"boolean", "singleSelect", "text", "file", "directory", "multiSelect"}, option.Kind) {
				field.kind = "readonly"
				field.raw = raw
			}
			fields = append(fields, field)
		}
	}
	return fields
}

// changedOptionValue reports the value a field's change sends, and whether the field changed. A cleared text
// or choice sends nil, which removes the override; a multi choice sends the selected values, an empty list
// being an explicit empty selection.
func changedOptionValue(field runOptionField) (any, bool) {
	switch field.kind {
	case "boolean":
		return field.flag, field.flag != field.initFlag
	case "text", "file", "directory", "singleSelect":
		if field.text == field.initText {
			return nil, false
		}
		if field.text == "" {
			return nil, true
		}
		return field.text, true
	case "multiSelect":
		if slices.Equal(field.picks, field.initPick) {
			return nil, false
		}
		selected := []string{}
		for index, choice := range field.choices {
			if field.picks[index] {
				selected = append(selected, choice.value)
			}
		}
		return selected, true
	}
	return nil, false
}

// runOptionFields makes the editor fields of a run's build system from its instance manifest, with the
// configuration's overrides as their values.
func (p *project) runOptionFields(reference core.RunProviderReference, overrides map[string]json.RawMessage) []runOptionField {
	index := p.buildInstanceIndex(reference)
	if index < 0 {
		return nil
	}
	return declaredOptionFields(p.build.instances[index].Manifest, reference.BuildSystemID, overrides)
}

// applyRunOptionFields writes the changed fields into the editor's overrides: a changed value replaces the
// override, and a cleared one removes it, so the declaration applies again.
func applyRunOptionFields(e *runConfigEditor) {
	for _, field := range e.optionFields {
		value, changed := changedOptionValue(field)
		if !changed {
			continue
		}
		if value == nil {
			delete(e.options, field.id)
			continue
		}
		if e.options == nil {
			e.options = map[string]json.RawMessage{}
		}
		raw, _ := json.Marshal(value)
		e.options[field.id] = raw
	}
}

// runOptionChoiceIDs splits the choices of a single-choice field into their values and a label lookup, with
// an empty first choice that removes the override.
func runOptionChoiceIDs(field runOptionField) ([]string, map[string]string) {
	values := []string{""}
	labels := map[string]string{}
	for _, choice := range field.choices {
		values = append(values, choice.value)
		labels[choice.value] = choice.title
	}
	return values, labels
}
