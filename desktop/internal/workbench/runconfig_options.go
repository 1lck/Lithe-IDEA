package workbench

import (
	"context"
	"encoding/json"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The run configuration editor and the Build options editor show the build options a plugin declares,
// resolved by Core against the instance's loaded model when one is present. A value is kept as the stored
// JSON; only a field the user changed is written back, through the same Core edit that the caller uses. A
// boolean is a checkbox, a single choice a picker, a text, file or directory a text field, and a
// multi-choice with declared or model choices a list of checkboxes. Options whose model choices have not
// been loaded yet, and kinds the editor cannot edit, show read-only.

// runOptionChoice is one choice of a single or multi choice option.
type runOptionChoice struct {
	value, title  string
	defaultActive bool
}

// runOptionField is one declared option as the editor shows it. The init fields are what the value was when
// the editor opened, so a change is detected by comparison.
type runOptionField struct {
	id, title, kind string
	// description is the manifest's text for the ⓘ next to the option.
	description string
	// implicit is what the build tool uses for a text, file or directory option left unset, as the model
	// reported it. Such a field is edited as IDEA's path overrides are: the effective value is shown greyed
	// until Override is checked, and unchecking it removes the stored value.
	implicit string
	// override says the user's text is the value; it starts checked when a value is stored. The checkbox
	// writes it after a frame, so overrideApplied is the state the text was last brought in line with.
	override, overrideApplied bool
	choices                   []runOptionChoice
	flag, initFlag            bool
	text, initText            string
	picks, initPick           []bool
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
			Description string `json:"description"`
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
			field := runOptionField{id: option.ID, title: option.DisplayName, kind: option.Kind, description: option.Description}
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

// resolvedOptionFields turns Core's build.resolveOptions answer into editor fields, including choices
// supplied by the loaded model and their default-active state.
func resolvedOptionFields(resolved core.BuildResolvedOptions) []runOptionField {
	fields := make([]runOptionField, 0, len(resolved.Options))
	for _, option := range resolved.Options {
		field := runOptionField{
			id: option.ID, title: option.DisplayName, kind: option.Kind,
			description: option.Description, implicit: option.ImplicitValue,
		}
		if field.title == "" {
			field.title = option.ID
		}
		for _, choice := range option.Choices {
			title := choice.Title
			if title == "" {
				title = choice.Value
			}
			field.choices = append(field.choices, runOptionChoice{
				value: choice.Value, title: title, defaultActive: choice.DefaultActive,
			})
		}
		stored := option.Source == "user" || option.Source == "default"
		switch {
		case option.Kind == "boolean" && stored:
			_ = json.Unmarshal(option.Value, &field.flag)
			field.initFlag = field.flag
		case (option.Kind == "text" || option.Kind == "file" || option.Kind == "directory") && option.Source == "user":
			_ = json.Unmarshal(option.Value, &field.text)
			field.initText = field.text
			field.override, field.overrideApplied = true, true
		case option.Kind == "singleSelect" && option.Source == "user":
			_ = json.Unmarshal(option.Value, &field.text)
			field.initText = field.text
		}
		if option.Kind == "multiSelect" && len(field.choices) > 0 {
			selected := option.SelectedChoices
			if selected == nil && stored {
				_ = json.Unmarshal(option.Value, &selected)
			}
			field.picks = make([]bool, len(field.choices))
			for index, choice := range field.choices {
				field.picks[index] = slices.Contains(selected, choice.value)
			}
			field.initPick = slices.Clone(field.picks)
		}
		if (option.Kind == "singleSelect" && len(field.choices) == 0) || (option.Kind == "multiSelect" && len(field.choices) == 0) {
			field.kind = "readonly"
		}
		if option.Kind == "multiSelect" && len(field.choices) == 0 && option.Source == "user" {
			field.raw = option.Value
		}
		if !slices.Contains([]string{"boolean", "singleSelect", "text", "file", "directory", "multiSelect"}, option.Kind) {
			field.kind = "readonly"
			if option.Source == "user" {
				field.raw = option.Value
			}
		}
		fields = append(fields, field)
	}
	return fields
}

// resolveInstanceOptionFields asks Core to resolve instance's options against values and its loaded model.
func resolveInstanceOptionFields(ctx context.Context, kernel Kernel, instance buildInstance, values map[string]json.RawMessage) ([]runOptionField, error) {
	request := core.BuildResolveOptionsRequest{Options: values, InheritedOptions: instance.Options}
	if instance.modelLoaded {
		request.ModelValues = instance.Model.OptionValues
		request.ModelDefaults = instance.Model.OptionDefaults
		request.ModelExcludePrefixes = instance.Model.OptionExcludePrefixes
		request.ModelSelection = instance.Model.OptionSelection
	}
	resolved, err := kernel.ResolveBuildOptions(ctx, instance.Manifest, instance.BuildSystemID, request)
	if err != nil {
		return nil, err
	}
	return resolvedOptionFields(resolved), nil
}

// syncOverride brings the text in line with Override after the user checked or unchecked it. Checking it
// starts the text from the effective value, as IDEA does, so the user edits the path the tool used;
// unchecking it clears the text, which removes the stored value on save.
func (field *runOptionField) syncOverride() {
	if field.override == field.overrideApplied {
		return
	}
	field.overrideApplied = field.override
	switch {
	case field.override && field.text == "":
		field.text = field.implicit
	case !field.override:
		field.text = ""
	}
}

// changedSelectedChoices reports the checked choice values of a multi-select field when the user changed it.
func changedSelectedChoices(field runOptionField) ([]string, bool) {
	if field.kind != "multiSelect" || slices.Equal(field.picks, field.initPick) {
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
