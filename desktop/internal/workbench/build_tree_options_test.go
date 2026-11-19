package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// treeOptionsStaticManifest declares a synthetic build system whose static TOML model supplies
// choices and default-active choices for a tree-presented multi-select option with an exclusion
// prefix, plus a provider run so the Run Configuration editor also edits the option.
const treeOptionsStaticManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.tree-options",
  "displayName": "Tree Options Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"buildProviders": 0, "buildSystems": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["languageServer.launch", "process.build"],
  "activationEvents": ["onBuildSystem:fixture-profiles"],
  "languages": [],
  "buildSystems": [{
    "id": "fixture-profiles",
    "displayName": "Fixture Build",
    "detection": {"markers": ["fixture.toml"]},
    "invocation": {
      "executables": [{"kind": "command", "command": "fixture-build"}],
      "globalArguments": ["${optionArguments:profiles}"]
    },
    "provider": {
      "launch": {"kind": "packaged", "path": "provider"},
      "arguments": [],
      "executesProjectCode": false,
      "mayUseNetwork": false
    },
    "options": [{
      "id": "profiles",
      "displayName": "Profiles",
      "kind": "multiSelect",
      "choicesFromModel": true,
      "allowCustom": true,
      "excludePrefix": "-",
      "presentation": "tree",
      "arguments": ["-P", "${value}"]
    }],
    "model": {
      "source": "static",
      "file": "fixture.toml",
      "decoder": "toml",
      "map": {
        "projects": [{
          "each": "/package",
          "name": "/name",
          "targets": [{"each": "$/apps/*", "name": "/name", "tags": ["app"]}]
        }],
        "optionValues": {"profiles": {"each": "/profiles/*", "value": "@key"}},
        "optionDefaults": {"profiles": {"each": "/defaultProfiles/*", "value": "@key"}}
      }
    },
    "tasks": [{
      "id": "compile",
      "displayName": "compile",
      "group": "lifecycle",
      "category": ["Lifecycle"],
      "scopes": ["workspace", "project"],
      "arguments": ["compile"]
    }],
    "run": [{
      "id": "app",
      "name": "Run",
      "source": "provider",
      "execution": "service",
      "fromTargets": {"tags": ["app"]}
    }]
  }]
}`

const treeOptionsFixtureTOML = `[package]
name = "shop"
settings = "/home/me/.fixture/settings.xml"

[[apps]]
name = "ServerApp"

[profiles]
dev = true
local = false
prod = false

[defaultProfiles]
dev = true
`

func openTreeOptionsProject(t *testing.T, kernel Kernel) (*harness, *project) {
	t.Helper()
	return openTreeOptionsProjectWith(t, kernel, treeOptionsStaticManifest)
}

// openTreeOptionsProjectWith is openTreeOptionsProject with the plugin's manifest.
func openTreeOptionsProjectWith(t *testing.T, kernel Kernel, manifest string) (*harness, *project) {
	t.Helper()
	preferences, pluginRoot, root := treeOptionsWorkspace(t, manifest, "dark")
	h := newHarnessWithOptions(t, Options{
		Kernel:       kernel,
		PluginKernel: &testKernel{Client: core.NewClient()},
		PluginRoot:   pluginRoot,
		Store:        preferences,
		Languages:    []string{"en-US"},
	})
	return h, showTreeOptionsProject(t, h, root)
}

// treeOptionsWorkspace installs and enables the fixture plugin with manifest, in preferences of
// the given theme, and makes a project it detects.
func treeOptionsWorkspace(t *testing.T, manifest, theme string) (preferences *store.Store, pluginRoot, root string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"`+theme+`"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	preferences = store.At(dir)
	pluginRoot = t.TempDir()
	installed := filepath.Join(pluginRoot, "dev.lithe.test.tree-options", "1.0.0")
	if err := os.MkdirAll(filepath.Join(installed, "icons"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(installed, "plugin.json"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	// The icon a toolbar option of the fixture may name.
	if err := os.WriteFile(filepath.Join(installed, "icons", "offline.svg"), []byte(treeOptionsToggleIcon), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(preferences).SetEnabled("dev.lithe.test.tree-options", true); err != nil {
		t.Fatal(err)
	}
	root = t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "fixture.toml"), []byte(treeOptionsFixtureTOML), 0o600); err != nil {
		t.Fatal(err)
	}
	return preferences, pluginRoot, root
}

// showTreeOptionsProject opens root in h with the Build window shown and waits for its tree.
func showTreeOptionsProject(t *testing.T, h *harness, root string) *project {
	t.Helper()
	h.open(root)
	p := h.app.project
	if p == nil {
		t.Fatal("the project did not open")
	}
	h.app.reduceChrome(core.ToggleChrome(itemBuild))
	h.awaitBuildDetection(p)
	h.settleUntil("initial tree and run configurations", func() bool {
		return !p.runConfigs.loading && p.build.instances[0].trees.whole != nil && !p.build.instances[0].trees.wholeOut
	})
	h.settle()
	return p
}

func storedProfileTokens(t *testing.T, h *harness, p *project) ([]string, bool) {
	t.Helper()
	docs, err := h.app.readBuildOptionDocuments(context.Background(), p.root)
	if err != nil {
		t.Fatal(err)
	}
	storage, err := core.NewClient().ResolveStoredBuildOptions(context.Background(), docs.team, docs.local)
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := buildDetectOptions(storage)
	if err != nil {
		t.Fatal(err)
	}
	raw, ok := inputs.Options["fixture-profiles"]["profiles"]
	if !ok {
		return nil, false
	}
	var tokens []string
	if err := json.Unmarshal(raw, &tokens); err != nil {
		t.Fatal(err)
	}
	return tokens, true
}

// A tree-presented multi-select option starts closed with its active choices in its detail, opens
// to show checkboxes with default-active markers, keeps hidden checked choices when toggled under a
// filter, encodes exclusions when a default-active choice is unchecked, and prunes the local
// override once the user returns to the default selection.
func TestBuildTreePresentsAndTogglesModelOptionChoices(t *testing.T) {
	h, p := openTreeOptionsProject(t, &testKernel{Client: core.NewClient()})
	language := h.app.language()
	defaultBadge := i18n.Shared(language, "desktop.build.optionChoiceDefault")
	targets := h.app.text.Build.Targets

	expectBuildTree(t, h, p, "initial collapsed options", []string{
		"group Fixture Build: shop",
		"  folder Profiles (dev)",
		"  folder Lifecycle",
		"  folder " + targets,
	})

	// Click Profiles in the Build window to expand it and verify default-active choice is checked.
	h.click(center(h.labelBounds("Profiles")))
	h.settle()
	expectBuildTree(t, h, p, "expanded Profiles", []string{
		"group Fixture Build: shop",
		"  folder Profiles (dev)",
		"    choice [x] dev (" + defaultBadge + ")",
		"    choice [ ] local",
		"    choice [ ] prod",
		"  folder Lifecycle",
		"  folder " + targets,
	})

	toggleChoice := func(choice string) {
		t.Helper()
		h.settleUntil("tree layout before toggling "+choice, func() bool {
			trees := &p.build.instances[0].trees
			return !trees.wholeOut && !trees.filteredOut
		})
		h.settle()
		label := i18n.SharedFormat(language, "desktop.build.toggleOptionChoice", map[string]string{
			"option": "Profiles",
			"choice": choice,
		})
		h.clickNamed(label)
		h.settleUntil("option toggle "+choice, func() bool {
			return !p.build.optionSaving && p.build.loaded && !p.build.loading && !p.build.reloadPending
		})
	}

	// Checking prod alongside default dev stores ["dev", "prod"] and keeps Profiles open across reload.
	toggleChoice("prod")
	if got, ok := storedProfileTokens(t, h, p); !ok || !slices.Equal(got, []string{"dev", "prod"}) {
		t.Fatalf("stored tokens after checking prod = %q (%v), want [dev prod]", got, ok)
	}
	expectBuildTree(t, h, p, "after checking prod", []string{
		"group Fixture Build: shop",
		"  folder Profiles (dev, prod)",
		"    choice [x] dev (" + defaultBadge + ")",
		"    choice [ ] local",
		"    choice [x] prod",
		"  folder Lifecycle",
		"  folder " + targets,
	})

	// Filtering by "dev" hides "prod"; unchecking "dev" while filtered preserves hidden "prod" and
	// encodes "-dev" so the default-active choice stays off.
	h.app.post(func(*App) { p.panels.buildFilter = "dev" })
	h.settle()
	expectBuildTree(t, h, p, "filtered to dev", []string{
		"group Fixture Build: shop",
		"  folder Profiles (dev, prod)",
		"    choice [x] dev (" + defaultBadge + ")",
	})
	toggleChoice("dev")
	if got, ok := storedProfileTokens(t, h, p); !ok || !slices.Equal(got, []string{"-dev", "prod"}) {
		t.Fatalf("stored tokens after unchecking dev under filter = %q (%v), want [-dev prod]", got, ok)
	}

	// Clearing the filter shows dev unchecked (still marked default) and prod checked.
	h.app.post(func(*App) { p.panels.buildFilter = "" })
	h.settle()
	expectBuildTree(t, h, p, "after clearing filter", []string{
		"group Fixture Build: shop",
		"  folder Profiles (prod)",
		"    choice [ ] dev (" + defaultBadge + ")",
		"    choice [ ] local",
		"    choice [x] prod",
		"  folder Lifecycle",
		"  folder " + targets,
	})

	// Unchecking prod leaves zero active choices, encoded as ["-dev"] so default dev does not come back.
	toggleChoice("prod")
	if got, ok := storedProfileTokens(t, h, p); !ok || !slices.Equal(got, []string{"-dev"}) {
		t.Fatalf("stored tokens with all choices unchecked = %q (%v), want [-dev]", got, ok)
	}
	expectBuildTree(t, h, p, "all choices unchecked", []string{
		"group Fixture Build: shop",
		"  folder Profiles",
		"    choice [ ] dev (" + defaultBadge + ")",
		"    choice [ ] local",
		"    choice [ ] prod",
		"  folder Lifecycle",
		"  folder " + targets,
	})

	// Re-checking dev returns to the model's default active set and prunes the local override.
	toggleChoice("dev")
	if got, ok := storedProfileTokens(t, h, p); ok {
		t.Fatalf("restoring default selection still stored %q, want pruned", got)
	}
	expectBuildTree(t, h, p, "restored default selection", []string{
		"group Fixture Build: shop",
		"  folder Profiles (dev)",
		"    choice [x] dev (" + defaultBadge + ")",
		"    choice [ ] local",
		"    choice [ ] prod",
		"  folder Lifecycle",
		"  folder " + targets,
	})
}

// Both the Build options dialog and the Run Configuration options editor resolve model choices and
// default-active markers through Core and encode exclusions when saving changes.
func TestBuildAndRunOptionEditorsResolveAndSaveModelChoices(t *testing.T) {
	gate := &captureBuildPlan{Kernel: &testKernel{Client: core.NewClient()}, requests: make(chan core.BuildPlanRequest, 1)}
	h, p := openTreeOptionsProject(t, gate)
	language := h.app.language()

	// Open the Build options dialog on the selected instance.
	h.clickNamed(h.instanceOptions(p))
	h.settleUntil("build options dialog resolved", func() bool {
		e := &p.build.options
		return e.open && e.ignored.loaded && len(e.fields) == 1 && e.fields[0].kind == "multiSelect"
	})
	field := p.build.options.fields[0]
	if len(field.choices) != 3 || !field.choices[0].defaultActive || !slices.Equal(field.picks, []bool{true, false, false}) {
		t.Fatalf("build options dialog field = %+v", field)
	}
	defaultLabel := i18n.SharedFormat(language, "desktop.build.optionChoiceDefaultLabel", map[string]string{"title": "dev"})
	h.clickNamed(defaultLabel)
	h.clickNamed("local")
	h.clickNamed(h.shared("ui.save"))
	h.settleUntil("build options dialog closed", func() bool { return !p.build.options.open })
	h.awaitBuildDetection(p)
	if got, ok := storedProfileTokens(t, h, p); !ok || !slices.Equal(got, []string{"-dev", "local"}) {
		t.Fatalf("stored tokens after Build options save = %q (%v), want [-dev local]", got, ok)
	}

	// Open the Run Configuration editor on "Run ServerApp" and override Profiles for that run alone.
	awaitStateWithin(t, h, 10*time.Second, "provider run configuration", func() bool {
		return !p.runConfigs.loading && len(p.runConfigs.list) == 1
	})
	configID := p.runConfigs.list[0].ID
	dialog := &p.runConfigs.dialog
	h.app.post(func(a *App) { a.openRunConfigDialog(p, configID) })
	awaitStateWithin(t, h, 10*time.Second, "run configuration editor resolved", func() bool {
		draft := dialog.drafts[configID]
		return draft != nil && draft.editor != nil && draft.editor.ready() && len(draft.editor.optionFields) == 1
	})
	editor := dialog.drafts[configID].editor
	runField := &editor.optionFields[0]
	if runField.kind != "multiSelect" || len(runField.choices) != 3 || !runField.choices[0].defaultActive || !slices.Equal(runField.picks, []bool{false, true, false}) {
		t.Fatalf("run configuration option field = %+v", *runField)
	}
	if editor.dirty() {
		t.Fatal("resolved choices mark an untouched run configuration dirty")
	}
	saveChoices := func(picks []bool, step runConfigDialogStep, want []string) {
		t.Helper()
		h.app.post(func(*App) { runField.picks = picks })
		applyDialog(t, h, p, step)
		if dialog.open != (step == runConfigDialogApply) || editor.failure != "" {
			t.Fatalf("dialog open %v, save failure %q", dialog.open, editor.failure)
		}
		config := p.runConfigs.configuration(configID)
		if config == nil {
			t.Fatal("the saved run configuration was not read back")
		}
		state, _ := providerRunEditorState(*config)
		var tokens []string
		if err := json.Unmarshal(state.options["profiles"], &tokens); err != nil || !slices.Equal(tokens, want) {
			t.Fatalf("run configuration profile override = %q (err %v), want %q", tokens, err, want)
		}
	}
	// Apply keeps the editor alive. Editing back to its original selection must replace the saved draft.
	saveChoices([]bool{false, false, true}, runConfigDialogApply, []string{"-dev", "prod"})
	saveChoices([]bool{false, true, false}, runConfigDialogApply, []string{"-dev", "local"})
	saveChoices([]bool{false, false, true}, runConfigDialogOK, []string{"-dev", "prod"})

	h.app.post(func(a *App) { a.runConfiguration(p, configID) })
	awaitStateWithin(t, h, 10*time.Second, "provider run plan", func() bool { return len(gate.requests) == 1 })
	request := <-gate.requests
	var runTokens []string
	if err := json.Unmarshal(request.OptionOverrides["profiles"], &runTokens); err != nil || !slices.Equal(runTokens, []string{"-dev", "prod"}) {
		t.Fatalf("profiles passed to the run plan = %q (err %v), want [-dev prod]", runTokens, err)
	}
	if err := json.Unmarshal(request.Options["profiles"], &runTokens); err != nil || !slices.Equal(runTokens, []string{"-dev", "local"}) {
		t.Fatalf("instance profiles passed to the run plan = %q (err %v), want [-dev local]", runTokens, err)
	}
}

// treeOptionsDirectoryFirstManifest declares a directory option, as a JDK is, before the
// multi-select Profiles option.
var treeOptionsDirectoryFirstManifest = strings.Replace(treeOptionsStaticManifest, `"options": [{
      "id": "profiles",`, `"options": [{"id": "home", "displayName": "Home", "kind": "directory", "environment": {"FIXTURE_HOME": "${value}"}}, {
      "id": "profiles",`, 1)

// A multi-select option after another option opens in both editors, and a text option shows its
// name: a text field's label only names it to accessibility. Its choices were keyed among
// the editor's fields, so the first choice took the key of the first field and the paint panicked:
// opening the Build options of a Maven project with profiles closed the application.
func TestOptionEditorsShowAMultiSelectAfterAnotherOption(t *testing.T) {
	h, p := openTreeOptionsProjectWith(t, &testKernel{Client: core.NewClient()}, treeOptionsDirectoryFirstManifest)

	h.clickNamed(h.instanceOptions(p))
	h.settleUntil("build options dialog resolved", func() bool {
		e := &p.build.options
		return e.open && e.ignored.loaded && len(e.fields) == 2 && e.fields[1].kind == "multiSelect"
	})
	h.settle()
	if !h.shows("local") || !h.shows("prod") {
		t.Fatal("the Build options dialog does not show the profile choices")
	}
	if !h.shows("Home") {
		t.Fatal("the Build options dialog does not name its directory option")
	}
	// The directory is chosen with the system's dialog too, and the dialog is the build system's own.
	h.hitLabeled(i18n.Shared(h.app.language(), "desktop.runConfig.browse"))
	if !h.shows(h.instanceOptions(p)) {
		t.Fatalf("the dialog is not titled %q", h.instanceOptions(p))
	}
	h.app.post(func(a *App) { p.build.options.open = false })
	h.settle()

	awaitStateWithin(t, h, 10*time.Second, "provider run configuration", func() bool {
		return !p.runConfigs.loading && len(p.runConfigs.list) == 1
	})
	configID := p.runConfigs.list[0].ID
	dialog := &p.runConfigs.dialog
	h.app.post(func(a *App) { a.openRunConfigDialog(p, configID) })
	awaitStateWithin(t, h, 10*time.Second, "run configuration editor resolved", func() bool {
		draft := dialog.drafts[configID]
		return draft != nil && draft.editor != nil && draft.editor.ready() && len(draft.editor.optionFields) == 2
	})
	h.settle()
	if !h.shows("local") || !h.shows("prod") {
		t.Fatal("the run configuration editor does not show the profile choices")
	}
	if !h.shows("Home") {
		t.Fatal("the run configuration editor does not name its directory option")
	}
}

// treeOptionsToggleIcon is the package icon of the fixture's toolbar option.
const treeOptionsToggleIcon = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><polygon fill="#6E6E6E" points="10.5 1 12 1 9 15 7.5 15"/></svg>`

// treeOptionsToolbarManifest adds a boolean option presented on the toolbar, as Maven's Offline.
var treeOptionsToolbarManifest = strings.Replace(treeOptionsStaticManifest, `"options": [{
      "id": "profiles",`, `"options": [{"id": "offline", "displayName": "Offline", "kind": "boolean", "presentation": "toolbar", "icon": {"path": "icons/offline.svg"}, "arguments": ["-o"]}, {
      "id": "profiles",`, 1)

// A boolean option a plugin presents on the toolbar is a toggle there, with the plugin's icon,
// as IDEA's Maven window has Toggle Offline Mode: a click stores the option in the local options
// the Build options dialog edits, the toggle stays pressed, and a second click turns it off.
func TestBuildToolbarTogglesABooleanOption(t *testing.T) {
	h, p := openTreeOptionsProjectWith(t, &testKernel{Client: core.NewClient()}, treeOptionsToolbarManifest)
	language := h.app.language()
	toggle := func(on bool) string {
		state := i18n.Shared(language, "desktop.build.toggleOff")
		if on {
			state = i18n.Shared(language, "desktop.build.toggleOn")
		}
		return i18n.SharedFormat(language, "desktop.build.toggleOption", map[string]string{"option": "Offline", "state": state})
	}
	instance := p.selectedBuildInstance()
	awaitStateWithin(t, h, 10*time.Second, "the toggle's icon", func() bool {
		_, ok := h.app.pluginIcons.Lookup(instance.PluginID, pluginicons.Declaration{Path: "icons/offline.svg"})
		return ok
	})
	h.settle()

	for _, on := range []bool{true, false} {
		h.clickNamed(toggle(!on))
		awaitStateWithin(t, h, 10*time.Second, "the option to be stored and the instance detected again", func() bool {
			instance := p.selectedBuildInstance()
			return !p.build.optionSaving && !p.build.loading && instance != nil && instance.optionOn("offline") == on
		})
		h.settle()
		if !h.shows(toggle(on)) && h.hitLabeled(toggle(on)).Width == 0 {
			t.Fatalf("the toggle is not shown as %v", on)
		}
		docs, err := h.app.readBuildOptionDocuments(context.Background(), p.root)
		if err != nil {
			t.Fatal(err)
		}
		if stored := strings.Contains(strings.Join(strings.Fields(string(docs.local)), ""), `"offline":true`); stored != on {
			t.Fatalf("local options %s, want offline stored as %v", docs.local, on)
		}
	}
}

// treeOptionsPathOverrideManifest declares a file option the model reports the tool's own value
// for, as Maven's user settings file is, with a description for its ⓘ.
var treeOptionsPathOverrideManifest = strings.NewReplacer(
	`"options": [{
      "id": "profiles",`, `"options": [{"id": "settingsFile", "displayName": "User settings file", "kind": "file",
      "description": "The settings file passed to the tool.", "arguments": ["-s", "${value}"]}, {
      "id": "profiles",`,
	`"optionDefaults": {"profiles": {"each": "/defaultProfiles/*", "value": "@key"}}`,
	`"optionDefaults": {"profiles": {"each": "/defaultProfiles/*", "value": "@key"},
          "settingsFile": {"each": "/package", "value": "/settings"}}`,
).Replace(treeOptionsStaticManifest)

// A path option the tool fills itself shows the tool's value greyed until Override is checked, as
// IDEA's Maven settings do. Checking it starts from that value, the edited path is stored, and
// unchecking it removes the stored path so the tool decides again.
func TestPathOptionShowsTheToolValueUntilOverridden(t *testing.T) {
	h, p := openTreeOptionsProjectWith(t, &testKernel{Client: core.NewClient()}, treeOptionsPathOverrideManifest)
	const implicit = "/home/me/.fixture/settings.xml"
	language := h.app.language()
	settingsField := func() *runOptionField {
		for index := range p.build.options.fields {
			if field := &p.build.options.fields[index]; field.id == "settingsFile" {
				return field
			}
		}
		return nil
	}
	openDialog := func() *runOptionField {
		h.clickNamed(h.instanceOptions(p))
		h.settleUntil("build options dialog resolved", func() bool {
			e := &p.build.options
			return e.open && !e.loading && e.ignored.loaded && settingsField() != nil && settingsField().implicit != ""
		})
		h.settle()
		return settingsField()
	}
	storedSettings := func() string {
		docs, err := h.app.readBuildOptionDocuments(context.Background(), p.root)
		if err != nil {
			t.Fatal(err)
		}
		return strings.Join(strings.Fields(string(docs.local)), "")
	}
	save := func(what string) {
		h.clickShared("ui.save")
		awaitStateWithin(t, h, 10*time.Second, what, func() bool {
			return !p.build.options.open && !p.build.loading && !p.build.instances[0].modelLoading
		})
		h.settle()
	}

	field := openDialog()
	if field.implicit != implicit || field.override || field.text != "" {
		t.Fatalf("the unset option = implicit %q, override %v, text %q; want the tool's %q, not overridden", field.implicit, field.override, field.text, implicit)
	}
	// The dialog's ignored paths have an ⓘ of their own; the option adds a second.
	infos := 0
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == i18n.Shared(language, "native.moreInformation") && !hit.IsLabel {
			infos++
		}
	}
	if field.description != "The settings file passed to the tool." || infos != 2 {
		t.Fatalf("the option's description %q shows %d ⓘ in the dialog, want 2", field.description, infos)
	}

	h.clickShared("desktop.build.optionOverride")
	h.settle()
	if field = settingsField(); !field.override || field.text != implicit {
		t.Fatalf("checking Override = override %v, text %q; want the tool's path to edit", field.override, field.text)
	}
	field.text = "/work/settings.xml"
	save("the overridden path to be stored")
	if stored := storedSettings(); !strings.Contains(stored, `"settingsFile":"/work/settings.xml"`) {
		t.Fatalf("local options %s, want the overridden path", stored)
	}

	field = openDialog()
	if !field.override || field.text != "/work/settings.xml" {
		t.Fatalf("reopened, the option = override %v, text %q; want the stored path", field.override, field.text)
	}
	h.clickShared("desktop.build.optionOverride")
	h.settle()
	if field = settingsField(); field.override || field.text != "" {
		t.Fatalf("unchecking Override = override %v, text %q; want the path cleared", field.override, field.text)
	}
	save("the override to be removed")
	if stored := storedSettings(); strings.Contains(stored, "settingsFile") {
		t.Fatalf("local options %s still hold the path after Override was unchecked", stored)
	}
}
