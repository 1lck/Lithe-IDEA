package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

var projectGeneratorFixtures = contractfixture.Path("fixtures/project-generators")

func projectFixture(t *testing.T, name string) json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(projectGeneratorFixtures, name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func projectContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// The wrappers must agree with the golden answers every host shares: each case
// is decoded into the wrapper's own types on both sides, so a field the host
// reads cannot drift from the contract.
func TestProjectGeneratorWrappersMatchTheSharedGoldenCases(t *testing.T) {
	var golden struct {
		Cases []struct {
			Name        string          `json:"name"`
			Operation   string          `json:"operation"`
			Manifest    string          `json:"manifest"`
			GeneratorID string          `json:"generatorID"`
			ProjectName string          `json:"projectName"`
			Form        json.RawMessage `json:"form"`
			Expected    json.RawMessage `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(projectFixture(t, "project-plans.json"), &golden); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, test := range golden.Cases {
		t.Run(test.Name, func(t *testing.T) {
			manifestName := test.Manifest
			if manifestName == "" {
				manifestName = "project-generator.plugin.json"
			}
			manifest := projectFixture(t, manifestName)
			var input ProjectGeneratorFormInput
			if test.Form != nil {
				if err := json.Unmarshal(test.Form, &input); err != nil {
					t.Fatal(err)
				}
			}
			var expected struct {
				Status string            `json:"status"`
				Error  *ProjectRejection `json:"error"`
				Form   *ProjectGeneratorForm
				Plan   *ProjectGenerationPlan
				Name   *struct {
					Problem *string `json:"problem"`
				} `json:"name"`
			}
			if err := json.Unmarshal(test.Expected, &expected); err != nil {
				t.Fatal(err)
			}
			var raw map[string]json.RawMessage
			_ = json.Unmarshal(test.Expected, &raw)
			if raw["form"] != nil {
				expected.Form = new(ProjectGeneratorForm)
				if err := json.Unmarshal(raw["form"], expected.Form); err != nil {
					t.Fatal(err)
				}
			}
			if raw["plan"] != nil {
				expected.Plan = new(ProjectGenerationPlan)
				if err := json.Unmarshal(raw["plan"], expected.Plan); err != nil {
					t.Fatal(err)
				}
			}
			switch test.Operation {
			case "generatorForm":
				form, err := client.ProjectGeneratorFormOf(projectContext(t), manifest, test.GeneratorID, input)
				if err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(form, *expected.Form) {
					t.Fatalf("form = %+v\nwant %+v", form, *expected.Form)
				}
			case "generationPlan":
				plan, err := client.ProjectGenerationPlanOf(projectContext(t), manifest, test.GeneratorID, projectGeneratorFixtures, input)
				if expected.Status == "rejected" {
					var rejection *ProjectRejection
					if !errors.As(err, &rejection) || rejection.Code != expected.Error.Code {
						t.Fatalf("err = %v, want rejection %s", err, expected.Error.Code)
					}
					return
				}
				if err != nil {
					t.Fatal(err)
				}
				// The fixture's absent lists decode as nil, ours as empty.
				if !reflect.DeepEqual(normalizePlan(plan), normalizePlan(*expected.Plan)) {
					t.Fatalf("plan = %+v\nwant %+v", plan, *expected.Plan)
				}
			case "checkName":
				// Name validation is exercised through the form; the command itself
				// has no wrapper because the form already reports the same problem.
				t.Skip("covered by TestProjectGeneratorFormReportsNameProblems")
			default:
				t.Fatalf("unknown operation %q", test.Operation)
			}
		})
	}
}

func normalizePlan(plan ProjectGenerationPlan) ProjectGenerationPlan {
	if len(plan.Steps) == 0 {
		plan.Steps = nil
	}
	if len(plan.OpenFiles) == 0 {
		plan.OpenFiles = nil
	}
	if len(plan.ToolPins) == 0 {
		plan.ToolPins = nil
	}
	return plan
}

func TestProjectGeneratorCatalogListsSectionsInOrderWithProviders(t *testing.T) {
	plugins := []ProjectGeneratorPlugin{
		{Manifest: projectFixture(t, "project-generator.plugin.json"), Enabled: true},
		{Manifest: json.RawMessage(`{"not":"a manifest"}`), Enabled: true},
	}
	catalog, err := NewClient().ProjectGeneratorCatalogOf(projectContext(t), plugins)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, entry := range catalog.Generators {
		ids = append(ids, entry.Generator.Section+":"+entry.Generator.ID)
		if !entry.PluginEnabled || entry.PluginID != "dev.lithe.fixture.project-generator" {
			t.Fatalf("entry = %+v", entry)
		}
	}
	// "New Project" entries come first; the generators follow by order, then name.
	if want := []string{"project:app", "generator:initializr", "generator:archetype"}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("catalog order = %v, want %v", ids, want)
	}
	if len(catalog.Issues) != 1 || catalog.Issues[0].Error == nil {
		t.Fatalf("a plugin Core refuses must be reported as an issue: %+v", catalog.Issues)
	}
	if !catalog.Generators[1].UsesNetwork || catalog.Generators[0].UsesNetwork {
		t.Fatal("usesNetwork does not follow the declared steps")
	}
	app := catalog.Generators[0]
	if len(app.Generator.Fields) != 4 || app.Generator.Fields[1].Tool != "java" || app.Generator.Fields[0].Presentation != "segmented" {
		t.Fatalf("fields = %+v", app.Generator.Fields)
	}
	if len(app.Requirements) != 2 || app.Requirements[0].LanguageID != "java" || len(app.Requirements[0].Providers) != 0 {
		t.Fatalf("requirements = %+v", app.Requirements)
	}
}

// A condition decides whether a field is shown, and a hidden field is not
// validated: the host never evaluates conditions itself.
func TestProjectGeneratorFormShowsConditionalFieldsAndNameProblems(t *testing.T) {
	manifest := projectFixture(t, "project-generator.plugin.json")
	client := NewClient()
	input := ProjectGeneratorFormInput{ProjectName: "demo", Values: map[string]any{"buildSystem": "none"}}
	form, err := client.ProjectGeneratorFormOf(projectContext(t), manifest, "app", input)
	if err != nil {
		t.Fatal(err)
	}
	if form.Fields[3].ID != "groupId" || form.Fields[3].Visible {
		t.Fatalf("groupId is visible without Maven: %+v", form.Fields[3])
	}
	input.Values["buildSystem"] = "maven"
	form, err = client.ProjectGeneratorFormOf(projectContext(t), manifest, "app", input)
	if err != nil {
		t.Fatal(err)
	}
	if !form.Fields[3].Visible || form.Fields[3].Value != "com.example" || !reflect.DeepEqual(form.ActiveRequirements, []int{0, 1}) {
		t.Fatalf("form = %+v", form)
	}
	input.ProjectName = "a/b"
	form, err = client.ProjectGeneratorFormOf(projectContext(t), manifest, "app", input)
	if err != nil {
		t.Fatal(err)
	}
	if form.ProjectName.Problem == nil || *form.ProjectName.Problem != "invalidFormat" || form.Valid {
		t.Fatalf("project name problem = %+v, valid %v", form.ProjectName, form.Valid)
	}
	if _, err := client.ProjectGeneratorFormOf(projectContext(t), manifest, "missing", input); err == nil {
		t.Fatal("an unknown generator must be rejected")
	}
}

func TestExtractProjectArchiveRejectsANonArchive(t *testing.T) {
	directory := t.TempDir()
	archive := filepath.Join(directory, "not.zip")
	if err := os.WriteFile(archive, []byte("plain text"), 0o600); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(directory, "project")
	if err := os.Mkdir(destination, 0o755); err != nil {
		t.Fatal(err)
	}
	_, err := NewClient().ExtractProjectArchive(projectContext(t), archive, destination)
	var rejection *ProjectRejection
	if !errors.As(err, &rejection) || rejection.Code != "plugin.project.archiveInvalid" {
		t.Fatalf("err = %v", err)
	}
}
