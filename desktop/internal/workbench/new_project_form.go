package workbench

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// Field types of the contract. The host draws these and never branches on a
// generator ID; Core decides defaults, visibility and problems.
const (
	fieldText        = "text"
	fieldEnum        = "enum"
	fieldBoolean     = "boolean"
	fieldMultiSelect = "multiSelect"
	fieldRuntime     = "runtime"
	fieldTool        = "tool"
)

// toolInstall is an installation the toolchain found. Provider is kept for the
// pin the project saves; Core's form input has no place for it.
type toolInstall struct {
	core.ProjectToolInstallation
	Provider string
}

// toolList is what discovery found for one tool, and the installation the
// toolchain would use on its own.
type toolList struct {
	Installations []toolInstall
	Default       string
}

// formField holds the widgets of one declared field. The widgets bind to these
// values directly, so their addresses stay fixed for the life of the form.
type formField struct {
	decl core.ProjectGeneratorField
	// text is a text or enum value, or the home of a tool or runtime installation.
	text string
	flag bool
	// chosen is a multiSelect's checkboxes by option value.
	chosen map[string]*bool
	// shown is the canonical value the widgets last agreed with Core on. A
	// widget that differs from it was edited by the user since.
	shown  string
	edited bool
	state  core.ProjectFieldState
	// values and titles are the options of an enum field in order, kept so
	// painting does not rebuild them.
	values []string
	titles map[string]string
}

func (f *formField) canonical() string {
	switch f.decl.Type {
	case fieldBoolean:
		return fmt.Sprint(f.flag)
	case fieldMultiSelect:
		return strings.Join(f.selected(), "\x1f")
	}
	return f.text
}

// selected lists the checked options in declaration order, as Core keeps them.
func (f *formField) selected() []string {
	var values []string
	for _, option := range f.decl.Options {
		if box := f.chosen[option.Value]; box != nil && *box {
			values = append(values, option.Value)
		}
	}
	return values
}

// show puts a value Core answered into the widgets.
func (f *formField) show(value any) {
	switch f.decl.Type {
	case fieldBoolean:
		if flag, ok := value.(bool); ok {
			f.flag = flag
		}
	case fieldMultiSelect:
		wanted := map[string]bool{}
		if items, ok := value.([]any); ok {
			for _, item := range items {
				if text, ok := item.(string); ok {
					wanted[text] = true
				}
			}
		}
		for _, option := range f.decl.Options {
			*f.chosen[option.Value] = wanted[option.Value]
		}
	default:
		if text, ok := value.(string); ok {
			f.text = text
		}
	}
	f.shown = f.canonical()
}

// generatorForm is the window's state for the selected generator: the widget
// values, what discovery found for its tools, and Core's last evaluation.
type generatorForm struct {
	key    string
	entry  core.ProjectGeneratorEntry
	plugin pluginservice.GeneratorPlugin
	fields []*formField
	byID   map[string]*formField
	// tools is the discovery result by tool ID, set once loaded.
	tools       map[string]toolList
	toolsLoaded bool
	toolsFailed bool
	// form is Core's last answer; nil until the first evaluation arrives.
	form *core.ProjectGeneratorForm
	// formKey is the request key of the answer above; currentKey is the key of
	// what the user has entered now. They agree once Core has answered for it.
	formKey, currentKey string
}

func newGeneratorForm(key string, entry core.ProjectGeneratorEntry, plugin pluginservice.GeneratorPlugin) *generatorForm {
	g := &generatorForm{key: key, entry: entry, plugin: plugin, byID: map[string]*formField{}}
	for _, decl := range entry.Generator.Fields {
		f := &formField{decl: decl}
		if decl.Type == fieldEnum {
			f.titles = make(map[string]string, len(decl.Options))
			for _, option := range decl.Options {
				f.values = append(f.values, option.Value)
				f.titles[option.Value] = option.Title
			}
		}
		if decl.Type == fieldMultiSelect {
			f.chosen = make(map[string]*bool, len(decl.Options))
			for _, option := range decl.Options {
				f.chosen[option.Value] = new(bool)
			}
		}
		// Until Core answers, the widgets hold what they were made with, which is
		// not an edit.
		f.shown = f.canonical()
		g.fields = append(g.fields, f)
		g.byID[decl.ID] = f
	}
	return g
}

// toolIDs lists the tools the generator's fields pick installations of.
func (g *generatorForm) toolIDs() []string {
	var ids []string
	for _, f := range g.fields {
		id := f.toolID()
		if id != "" && !slices.Contains(ids, id) {
			ids = append(ids, id)
		}
	}
	return ids
}

// toolID is the tool definition a tool or runtime field selects an installation of.
func (f *formField) toolID() string {
	switch f.decl.Type {
	case fieldTool:
		return f.decl.Tool
	case fieldRuntime:
		return f.decl.Runtime
	}
	return ""
}

// setTools records what discovery found. A runtime field the user has not
// chosen for starts on the installation the toolchain would use itself.
func (g *generatorForm) setTools(tools map[string]toolList, failed bool) {
	g.tools, g.toolsLoaded, g.toolsFailed = tools, true, failed
	for _, f := range g.fields {
		if f.decl.Type != fieldRuntime || f.edited || f.text != "" {
			continue
		}
		list := tools[f.toolID()]
		switch {
		case list.Default != "":
			f.text = list.Default
		case len(list.Installations) > 0:
			f.text = list.Installations[0].Home
		}
		f.shown = f.text
	}
}

func (g *generatorForm) installation(tool, home string) (toolInstall, bool) {
	for _, installation := range g.tools[tool].Installations {
		if installation.Home == home {
			return installation, true
		}
	}
	return toolInstall{}, false
}

// input collects what the user has entered into Core's request. A widget that
// differs from what Core last showed counts as an edit; the rest keep following
// Core's derived defaults.
func (g *generatorForm) input(name string) core.ProjectGeneratorFormInput {
	input := core.ProjectGeneratorFormInput{
		ProjectName: name,
		Values:      map[string]any{},
		Runtimes:    map[string]core.ProjectRuntimeSelection{},
		Tools:       map[string][]core.ProjectToolInstallation{},
	}
	for _, f := range g.fields {
		if current := f.canonical(); current != f.shown {
			f.edited, f.shown = true, current
		}
		id := f.decl.ID
		switch f.decl.Type {
		case fieldText:
			if f.edited {
				input.Values[id] = f.text
				input.Edited = append(input.Edited, id)
			}
		case fieldEnum:
			if f.edited {
				input.Values[id] = f.text
			}
		case fieldBoolean:
			if f.edited {
				input.Values[id] = f.flag
			}
		case fieldMultiSelect:
			if f.edited {
				input.Values[id] = append([]string{}, f.selected()...)
			}
		case fieldRuntime:
			if installation, ok := g.installation(f.toolID(), f.text); ok {
				input.Runtimes[id] = core.ProjectRuntimeSelection{Home: installation.Home, Version: installation.Version}
			}
		case fieldTool:
			list := g.tools[f.toolID()].Installations
			installations := make([]core.ProjectToolInstallation, 0, len(list))
			for _, installation := range list {
				installations = append(installations, installation.ProjectToolInstallation)
			}
			input.Tools[id] = installations
			if f.edited && f.text != "" {
				input.Values[id] = f.text
			}
		}
	}
	return input
}

// apply takes Core's evaluation: derived values go into the widgets the user has
// not edited, and every field keeps its visibility and problem.
func (g *generatorForm) apply(form core.ProjectGeneratorForm) {
	g.form = &form
	for _, state := range form.Fields {
		f := g.byID[state.ID]
		if f == nil {
			continue
		}
		f.state = state
		if f.edited || f.decl.Type == fieldRuntime {
			continue
		}
		f.show(state.Value)
	}
}

// ready reports whether the form can be submitted: tools were discovered, Core
// answered for the current input and found nothing wrong.
func (g *generatorForm) ready() bool {
	return g.toolsLoaded && g.form != nil && g.form.Valid && g.formKey == g.currentKey
}

// requestKey names the form request, so an unchanged form is not asked again.
func requestKey(generator string, input core.ProjectGeneratorFormInput) string {
	data, err := json.Marshal(input)
	if err != nil {
		return generator
	}
	return generator + "\x00" + string(data)
}
