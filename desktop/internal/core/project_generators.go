package core

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
)

// ProjectGeneratorPlugin is one installed plugin as the generator catalog
// reads it. Disabled plugins are listed too, so the host can offer to enable one.
type ProjectGeneratorPlugin struct {
	Manifest json.RawMessage `json:"manifest"`
	Enabled  bool            `json:"enabled"`
}

// ProjectGeneratorIcon is the icon a generator declares, relative to its package.
type ProjectGeneratorIcon struct {
	Path     string `json:"path"`
	DarkPath string `json:"darkPath,omitempty"`
	Mode     string `json:"mode,omitempty"`
}

// ProjectGeneratorOption is one choice of an enum or multiSelect field.
type ProjectGeneratorOption struct {
	Value string `json:"value"`
	Title string `json:"title"`
	Group string `json:"group,omitempty"`
}

// ProjectGeneratorField is one input a generator declares. Core evaluates
// defaults, visibility and problems; the host only draws what it describes.
type ProjectGeneratorField struct {
	ID             string                   `json:"id"`
	Type           string                   `json:"type"`
	Title          string                   `json:"title"`
	Description    string                   `json:"description,omitempty"`
	Advanced       bool                     `json:"advanced,omitempty"`
	Options        []ProjectGeneratorOption `json:"options,omitempty"`
	Presentation   string                   `json:"presentation,omitempty"`
	Placeholder    string                   `json:"placeholder,omitempty"`
	Optional       bool                     `json:"optional,omitempty"`
	Tool           string                   `json:"tool,omitempty"`
	MinimumVersion string                   `json:"minimumVersion,omitempty"`
}

// ProjectGeneratorDeclaration is the part of a generator the window draws.
type ProjectGeneratorDeclaration struct {
	ID          string                  `json:"id"`
	DisplayName string                  `json:"displayName"`
	Description string                  `json:"description,omitempty"`
	Section     string                  `json:"section"`
	Icon        *ProjectGeneratorIcon   `json:"icon,omitempty"`
	Order       int                     `json:"order"`
	Fields      []ProjectGeneratorField `json:"fields,omitempty"`
}

// ProjectGeneratorProvider is a plugin that provides a requirement or a tool.
type ProjectGeneratorProvider struct {
	PluginID   string `json:"pluginID"`
	PluginName string `json:"pluginName"`
	Enabled    bool   `json:"enabled"`
}

// ProjectGeneratorRequirement is a language or build system the result needs.
type ProjectGeneratorRequirement struct {
	LanguageID    string                     `json:"languageID,omitempty"`
	BuildSystemID string                     `json:"buildSystemID,omitempty"`
	Providers     []ProjectGeneratorProvider `json:"providers"`
}

// ProjectGeneratorToolRequirement names the plugins that declare a tool field's tool.
type ProjectGeneratorToolRequirement struct {
	FieldID   string                     `json:"fieldID"`
	Tool      string                     `json:"tool"`
	Providers []ProjectGeneratorProvider `json:"providers"`
}

// ProjectGeneratorEntry is one generator of one plugin, in list order.
type ProjectGeneratorEntry struct {
	PluginID      string                            `json:"pluginID"`
	PluginName    string                            `json:"pluginName"`
	PluginEnabled bool                              `json:"pluginEnabled"`
	Generator     ProjectGeneratorDeclaration       `json:"generator"`
	Requirements  []ProjectGeneratorRequirement     `json:"requirements"`
	Tools         []ProjectGeneratorToolRequirement `json:"tools"`
	UsesNetwork   bool                              `json:"usesNetwork"`
}

// ProjectGeneratorIssue is a plugin whose manifest Core rejected.
type ProjectGeneratorIssue struct {
	PluginID string            `json:"pluginID"`
	Error    *ProjectRejection `json:"error"`
}

// ProjectGeneratorCatalog is every generator Core accepted, sorted by section,
// order and name, plus the plugins it refused.
type ProjectGeneratorCatalog struct {
	Generators []ProjectGeneratorEntry `json:"generators"`
	Issues     []ProjectGeneratorIssue `json:"issues"`
}

// ProjectRejection is a refusal of a declaration or an input by Core.
type ProjectRejection struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Field   string `json:"field,omitempty"`
}

func (r *ProjectRejection) Error() string { return fmt.Sprintf("%s: %s", r.Code, r.Message) }

// ProjectToolInstallation is an installation the host found for a tool field.
type ProjectToolInstallation struct {
	Home       string `json:"home"`
	Executable string `json:"executable"`
	Version    string `json:"version"`
}

// ProjectGeneratorFormInput is what the user has entered so far. A text value
// counts only when its ID is in Edited; a tool field's value is its home.
type ProjectGeneratorFormInput struct {
	ProjectName string                               `json:"projectName"`
	Values      map[string]any                       `json:"values"`
	Edited      []string                             `json:"edited"`
	Tools       map[string][]ProjectToolInstallation `json:"tools"`
}

// normalized returns a copy whose maps and slices are never nil and whose
// edited list is sorted, so the request is deterministic.
func (input ProjectGeneratorFormInput) normalized() ProjectGeneratorFormInput {
	if input.Values == nil {
		input.Values = map[string]any{}
	}
	edited := append([]string{}, input.Edited...)
	sort.Strings(edited)
	input.Edited = edited
	if input.Tools == nil {
		input.Tools = map[string][]ProjectToolInstallation{}
	}
	return input
}

// ProjectToolChoice is one installation a tool field offers, with Core's
// verdict on its version.
type ProjectToolChoice struct {
	Home         string `json:"home"`
	Executable   string `json:"executable"`
	Version      string `json:"version"`
	MeetsMinimum bool   `json:"meetsMinimum"`
}

// ProjectFieldState is Core's evaluation of one field.
type ProjectFieldState struct {
	ID            string              `json:"id"`
	Visible       bool                `json:"visible"`
	Value         any                 `json:"value"`
	Problem       string              `json:"problem,omitempty"`
	Installations []ProjectToolChoice `json:"installations,omitempty"`
}

// ProjectGeneratorForm is the evaluated form: derived defaults, visibility and problems.
type ProjectGeneratorForm struct {
	ProjectName struct {
		Problem *string `json:"problem"`
	} `json:"projectName"`
	Fields             []ProjectFieldState `json:"fields"`
	ActiveRequirements []int               `json:"activeRequirements"`
	Valid              bool                `json:"valid"`
}

// ProjectPlanFile is one expanded template file.
type ProjectPlanFile struct {
	Path       string `json:"path"`
	Contents   string `json:"contents"`
	Executable bool   `json:"executable"`
}

// ProjectPlanStep is one step of a generation plan. Kind selects which fields
// are set: writeFiles, command or archive.
type ProjectPlanStep struct {
	Kind           string            `json:"kind"`
	Files          []ProjectPlanFile `json:"files,omitempty"`
	Command        string            `json:"command,omitempty"`
	Arguments      []string          `json:"arguments,omitempty"`
	Environment    map[string]string `json:"environment,omitempty"`
	Collect        *string           `json:"collect,omitempty"`
	MayUseNetwork  bool              `json:"mayUseNetwork,omitempty"`
	TimeoutSeconds int               `json:"timeoutSeconds,omitempty"`
	URL            string            `json:"url,omitempty"`
	Host           string            `json:"host,omitempty"`
	Format         string            `json:"format,omitempty"`
}

// ProjectPlanToolPin is a tool selection the host saves as the project's pin.
type ProjectPlanToolPin struct {
	Field      string `json:"field"`
	Tool       string `json:"tool"`
	PinAs      string `json:"pinAs"`
	Home       string `json:"home"`
	Executable string `json:"executable"`
}

// ProjectGenerationPlan is the expanded steps of a filled-in form.
type ProjectGenerationPlan struct {
	ProjectName string               `json:"projectName"`
	Steps       []ProjectPlanStep    `json:"steps"`
	OpenFiles   []string             `json:"openFiles"`
	ToolPins    []ProjectPlanToolPin `json:"toolPins"`
	UsesNetwork bool                 `json:"usesNetwork"`
}

// projectOutcome is the {status, error, <key>} envelope of the project.* commands.
type projectOutcome struct {
	Status string            `json:"status"`
	Error  *ProjectRejection `json:"error"`
}

func (o projectOutcome) failure(command string) error {
	if o.Status == "rejected" && o.Error != nil {
		return o.Error
	}
	if o.Status != "ok" {
		return newParseError(command, "project generator returned an invalid outcome", "")
	}
	return nil
}

// ProjectGeneratorCatalogOf lists the generators of the given plugins.
func (c *Client) ProjectGeneratorCatalogOf(ctx context.Context, plugins []ProjectGeneratorPlugin) (ProjectGeneratorCatalog, error) {
	const command = "project.generatorCatalog"
	if plugins == nil {
		plugins = []ProjectGeneratorPlugin{}
	}
	var result struct {
		projectOutcome
		Catalog *ProjectGeneratorCatalog `json:"catalog"`
	}
	if err := c.Execute(ctx, command, struct {
		Plugins []ProjectGeneratorPlugin `json:"plugins"`
	}{plugins}, &result); err != nil {
		return ProjectGeneratorCatalog{}, err
	}
	if err := result.failure(command); err != nil {
		return ProjectGeneratorCatalog{}, err
	}
	if result.Catalog == nil {
		return ProjectGeneratorCatalog{}, newParseError(command, "missing catalog", "")
	}
	return *result.Catalog, nil
}

// ProjectGeneratorFormOf evaluates one generator's form: derived defaults,
// which fields are visible and what is wrong with each value.
func (c *Client) ProjectGeneratorFormOf(ctx context.Context, manifest json.RawMessage, generatorID string, input ProjectGeneratorFormInput) (ProjectGeneratorForm, error) {
	const command = "project.generatorForm"
	var result struct {
		projectOutcome
		Form *ProjectGeneratorForm `json:"form"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest    json.RawMessage           `json:"manifest"`
		GeneratorID string                    `json:"generatorID"`
		Form        ProjectGeneratorFormInput `json:"form"`
	}{manifest, generatorID, input.normalized()}, &result); err != nil {
		return ProjectGeneratorForm{}, err
	}
	if err := result.failure(command); err != nil {
		return ProjectGeneratorForm{}, err
	}
	if result.Form == nil {
		return ProjectGeneratorForm{}, newParseError(command, "missing form", "")
	}
	return *result.Form, nil
}

// ProjectGenerationPlanOf expands a valid form into files, argv and URLs.
// packagePath is the installed package directory the template files come from.
func (c *Client) ProjectGenerationPlanOf(ctx context.Context, manifest json.RawMessage, generatorID, packagePath string, input ProjectGeneratorFormInput) (ProjectGenerationPlan, error) {
	const command = "project.generationPlan"
	var result struct {
		projectOutcome
		Plan *ProjectGenerationPlan `json:"plan"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest    json.RawMessage           `json:"manifest"`
		GeneratorID string                    `json:"generatorID"`
		PackagePath string                    `json:"packagePath"`
		Form        ProjectGeneratorFormInput `json:"form"`
	}{manifest, generatorID, packagePath, input.normalized()}, &result); err != nil {
		return ProjectGenerationPlan{}, err
	}
	if err := result.failure(command); err != nil {
		return ProjectGenerationPlan{}, err
	}
	if result.Plan == nil {
		return ProjectGenerationPlan{}, newParseError(command, "missing plan", "")
	}
	return *result.Plan, nil
}

// ExtractProjectArchive extracts a downloaded zip into an existing staging
// directory. Core refuses entries outside it, symbolic links and overwrites.
func (c *Client) ExtractProjectArchive(ctx context.Context, archivePath, destination string) (int, error) {
	const command = "project.extractArchive"
	var result struct {
		projectOutcome
		Extracted *struct {
			Files int `json:"files"`
		} `json:"extracted"`
	}
	if err := c.Execute(ctx, command, struct {
		ArchivePath string `json:"archivePath"`
		Destination string `json:"destination"`
	}{archivePath, destination}, &result); err != nil {
		return 0, err
	}
	if err := result.failure(command); err != nil {
		return 0, err
	}
	if result.Extracted == nil {
		return 0, newParseError(command, "missing extraction result", "")
	}
	return result.Extracted.Files, nil
}
