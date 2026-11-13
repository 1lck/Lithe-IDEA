package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugintrust"
	"github.com/vivaui/viva/app"
)

// These opt-in integration tests install the released archives of the Lithe-IDEA
// Go and Maven plugins through the real installer, enable them and drive the
// workbench as a user does: detection, the model the plugin's command prints, a
// real build, the dependency tree, and live gopls diagnostics. They run the
// user's own go, gopls and mvn, so they skip unless an archive is named, and
// each fails rather than skips once a named archive cannot do its work.

// installOfficialPluginArchive installs and enables archive in an isolated
// plugin root and returns the installed package directory.
func installOfficialPluginArchive(t *testing.T, h *harness, archive, id string) string {
	t.Helper()
	service, err := pluginservice.Open(core.NewClient(), h.store, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.app.plugins = service
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	plan, err := service.Installer.Prepare(ctx, plugininstall.Request{ArchivePath: archive, Root: service.Root, Source: plugintrust.Disk})
	if err != nil {
		t.Fatalf("prepare %s: %v", archive, err)
	}
	if plan.ID != id {
		_ = service.Installer.Discard(plan)
		t.Fatalf("archive holds %s, want %s", plan.ID, id)
	}
	installed, err := service.Installer.Commit(plan)
	if err != nil {
		_ = service.Installer.Discard(plan)
		t.Fatalf("install %s: %v", id, err)
	}
	if err := service.Manager.SetEnabled(id, true); err != nil {
		t.Fatal(err)
	}
	return installed.Path
}

// packageDigest hashes every file of an installed package, so a test can prove a
// workflow left the package byte-for-byte as installed.
func packageDigest(t *testing.T, root string) map[string]string {
	t.Helper()
	digest := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		// JDK module images are large; stream the unchanged-package proof so
		// test buffers do not inflate the headless host's memory observations.
		sum := sha256.New()
		_, readErr := io.Copy(sum, file)
		closeErr := file.Close()
		if readErr != nil {
			return readErr
		}
		if closeErr != nil {
			return closeErr
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		digest[relative] = hex.EncodeToString(sum.Sum(nil))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return digest
}

func assertPackageUnchanged(t *testing.T, root string, before map[string]string) {
	t.Helper()
	after := packageDigest(t, root)
	if len(after) != len(before) {
		t.Fatalf("the installed package now has %d files, it had %d", len(after), len(before))
	}
	for name, sum := range before {
		if after[name] != sum {
			t.Fatalf("the workflow changed the installed package file %s", name)
		}
	}
}

// writeFixture writes files (relative path to content) below root.
func writeFixture(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for name, content := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// awaitBuildModel waits until detection found an instance of buildSystemID and its
// model is loaded, failing with the model error when the plugin's command failed.
func awaitBuildModel(t *testing.T, h *harness, p *project, buildSystemID string, limit time.Duration) *buildInstance {
	t.Helper()
	var instance *buildInstance
	awaitStateWithin(t, h, limit, buildSystemID+" detection and model", func() bool {
		for index := range p.build.instances {
			candidate := &p.build.instances[index]
			if candidate.BuildSystemID != buildSystemID {
				continue
			}
			if candidate.modelError != "" {
				t.Fatalf("the %s model failed: %s", buildSystemID, candidate.modelError)
			}
			if candidate.modelLoaded {
				p.build.selected = index
				instance = candidate
				return true
			}
		}
		if p.build.failed != "" {
			t.Fatalf("build detection failed: %s", p.build.failed)
		}
		return false
	})
	return instance
}

// runBuildTaskToEnd runs one task of the selected instance and waits for it to end.
func runBuildTaskToEnd(t *testing.T, h *harness, p *project, projectID, taskID string, limit time.Duration) string {
	t.Helper()
	p.build.projectID, p.build.targetID, p.build.taskID = projectID, "", taskID
	if _, err := h.app.runBuildTask(p, projectID, "", taskID, nil); err != nil {
		t.Fatalf("start %s: %v", taskID, err)
	}
	awaitStateWithin(t, h, limit, "the "+taskID+" task", func() bool { return p.build.operation == nil })
	output := strings.Join(p.build.output, "")
	if p.build.status != h.app.text.Build.Succeeded {
		t.Fatalf("%s did not succeed: status=%q output=%q", taskID, p.build.status, output)
	}
	return output
}

// runTargetEntryToEnd runs the target's only command Run entry, as its Run button in the
// Build window does, waits for the program to exit and returns the window output.
func runTargetEntryToEnd(t *testing.T, h *harness, p *project, instance *buildInstance, targetID string, limit time.Duration) string {
	t.Helper()
	entries := buildTargetRunEntries(instance, targetID)
	if len(entries) != 1 {
		t.Fatalf("the target has %d Run entries, want 1: %+v", len(entries), instance.Model.Run)
	}
	entry := entries[0]
	h.app.runBuildEntry(p, entry.ID)
	if p.build.operation == nil {
		t.Fatalf("run %s did not start", entry.Name)
	}
	awaitStateWithin(t, h, limit, "the "+entry.Name+" run", func() bool { return p.build.operation == nil })
	output := strings.Join(p.build.output, "")
	if p.build.status != h.app.text.Build.Succeeded {
		t.Fatalf("run %s did not succeed: status=%q output=%q", entry.Name, p.build.status, output)
	}
	return output
}

func modelProjectNamed(model core.BuildModel, name string) *core.BuildProject {
	for index := range model.Projects {
		if model.Projects[index].Name == name {
			return &model.Projects[index]
		}
	}
	return nil
}

// markingWrapper writes an executable script that records each start in a marker file and
// then runs the named tool found on PATH, so a test can tell that a configured path ran.
func markingWrapper(t *testing.T, name string) (wrapper, marker string) {
	t.Helper()
	target, err := exec.LookPath(name)
	if err != nil {
		t.Fatalf("%s is not on PATH: %v", name, err)
	}
	dir := t.TempDir()
	marker = filepath.Join(dir, name+".started")
	wrapper = filepath.Join(dir, name)
	script := "#!/bin/sh\n: > '" + marker + "'\nexec '" + target + "' \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	return wrapper, marker
}

// saveGlobalPluginSettings saves values to the plugin's global settings layer the way the
// settings window does, then dispatches the effects Core answered for the change.
func saveGlobalPluginSettings(t *testing.T, h *harness, instance *buildInstance, values map[string]any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	store := pluginsettings.New(h.app.kernel, h.store.Dir())
	snapshot, err := store.Load(ctx, instance.Manifest, h.app.project.root)
	if err != nil {
		t.Fatalf("load the plugin settings: %v", err)
	}
	ids := make([]string, 0, len(values))
	for id := range values {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	edits := make([]core.PluginSettingEdit, 0, len(ids))
	for _, id := range ids {
		value, err := json.Marshal(values[id])
		if err != nil {
			t.Fatal(err)
		}
		edits = append(edits, core.PluginSettingEdit{ID: id, Value: value})
	}
	result, err := store.Save(ctx, snapshot, "global", edits, nil)
	if err != nil || !result.Committed {
		t.Fatalf("save the plugin settings: committed=%v err=%v", result.Committed, err)
	}
	h.app.applyPluginSettingsEffects(core.PluginSettingsOwner{PluginID: instance.PluginID, Version: instance.Version}, result.Effects)
}

// TestOfficialGoPluginBuildsAndServesAModule covers the Go Support archive: the
// Go Modules build system detects go.mod, `go list -json` becomes the model with
// the main package as an application target, `go build` and `go vet` succeed,
// the target's Run entry runs the program, and an edit in main.go reaches the
// user's gopls, whose diagnostic is stored.
func TestOfficialGoPluginBuildsAndServesAModule(t *testing.T) {
	archive := os.Getenv("LITHE_TEST_GO_PLUGIN_ARCHIVE")
	if archive == "" {
		t.Skip("set LITHE_TEST_GO_PLUGIN_ARCHIVE to a go-support-<version>-darwin.zip")
	}
	for _, command := range []string{"go", "gopls"} {
		if _, err := exec.LookPath(command); err != nil {
			t.Fatalf("%s is not on PATH: %v", command, err)
		}
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	installed := installOfficialPluginArchive(t, h, archive, "io.github.lithe-idea.go-support")
	before := packageDigest(t, installed)
	h.app.reloadPluginLanguages()
	root := t.TempDir()
	writeFixture(t, root, map[string]string{
		"go.mod":  "module example.com/hello\n\ngo 1.21\n",
		"main.go": "package main\n\nfunc main() {\n\tprintln(\"hello from lithe\")\n}\n",
	})
	h.open(root)
	p := h.app.project
	if p == nil {
		t.Fatal("the module did not open")
	}
	h.app.loadBuildSystems(p)
	instance := awaitBuildModel(t, h, p, "go", time.Minute)
	if modelProjectNamed(instance.Model, "example.com/hello") == nil {
		t.Fatalf("the go list model has no example.com/hello module: %+v", instance.Model.Projects)
	}
	application := ""
	for _, target := range instance.Model.Targets {
		for _, tag := range target.Tags {
			if tag == "application" {
				application = target.ID
			}
		}
	}
	if application == "" {
		t.Fatalf("the main package is not an application target: %+v", instance.Model.Targets)
	}
	// Both Go tasks run on a module, so they need the module selected as in the Build window.
	module := modelProjectNamed(instance.Model, "example.com/hello")
	runBuildTaskToEnd(t, h, p, module.ID, "build", 2*time.Minute)
	runBuildTaskToEnd(t, h, p, module.ID, "vet", 2*time.Minute)
	// The main package's Run entry is a command run: `go run` builds and starts it.
	if output := runTargetEntryToEnd(t, h, p, instance, application, 2*time.Minute); !strings.Contains(output, "hello from lithe") {
		t.Fatalf("go run did not print the program's output: %q", output)
	}

	// The Go executable setting reloads the model, and later builds run the chosen go.
	goWrapper, goMarker := markingWrapper(t, "go")
	saveGlobalPluginSettings(t, h, instance, map[string]any{"goExecutable": goWrapper})
	instance = awaitBuildModel(t, h, p, "go", time.Minute)
	if _, err := os.Stat(goMarker); err != nil {
		t.Fatalf("the model reload did not run the configured go: %v", err)
	}
	if err := os.Remove(goMarker); err != nil {
		t.Fatal(err)
	}
	module = modelProjectNamed(instance.Model, "example.com/hello")
	runBuildTaskToEnd(t, h, p, module.ID, "build", 2*time.Minute)
	if _, err := os.Stat(goMarker); err != nil {
		t.Fatalf("the build did not run the configured go: %v", err)
	}

	path := filepath.Join(root, "main.go")
	h.app.openFileAt(p, path, 1)
	var d *document
	awaitStateWithin(t, h, time.Minute, "gopls to open main.go", func() bool {
		d = p.docs.byPath(path)
		return d != nil && d.sync.opened
	})
	if !d.view.GoToNavigation(2, len("func main() {"), false) {
		t.Fatal("could not place the caret in main")
	}
	input := d.view.TextInput(app.TextInputContext{ID: d.hit})
	if _, err := input.OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "\n\tmissingCall()"}); err != nil {
		t.Fatal(err)
	}
	awaitStateWithin(t, h, time.Minute, "a gopls diagnostic after the edit", func() bool {
		return problemMessagesContain(h.app, "missingCall")
	})
	t.Logf("gopls diagnostics: %q", problemMessages(h.app))
	if diagnosticsForFile(h.app, path) == 0 {
		t.Fatal("gopls's diagnostic was not stored for main.go")
	}

	// gopls options take effect at once: gofumpt reaches the running server through
	// workspace/configuration, and its formatting drops the blank line that opens main's
	// body, which gofmt keeps. The change arrives asynchronously, so formatting repeats
	// until the server formats with it.
	if !d.view.GoToNavigation(2, len("func main() {"), false) {
		t.Fatal("could not place the caret in main")
	}
	if _, err := d.view.TextInput(app.TextInputContext{ID: d.hit}).OnEvent(app.TextEvent{Kind: app.TextInsert, Text: "\n"}); err != nil {
		t.Fatal(err)
	}
	saveGlobalPluginSettings(t, h, instance, map[string]any{"gofumpt": true})
	gofumpted := func() bool {
		text, _ := d.view.Text()
		return strings.Contains(string(text), "func main() {\n\tmissingCall()")
	}
	if gofumpted() {
		t.Fatal("the blank line at the start of main's body was not inserted")
	}
	deadline := time.NewTimer(time.Minute)
	defer deadline.Stop()
	retry := time.NewTicker(2 * time.Second)
	defer retry.Stop()
	h.app.startPluginFormatting(p, d)
	for !gofumpted() {
		select {
		case <-h.driver.Wakes():
			if err := h.driver.Pump(); err != nil {
				t.Fatal(err)
			}
		case <-retry.C:
			h.app.startPluginFormatting(p, d)
		case <-deadline.C:
			text, _ := d.view.Text()
			t.Fatalf("gopls did not format with gofumpt: %q", text)
		}
	}
	h.app.closeProject()
	awaitStateWithin(t, h, 30*time.Second, "the closed project", func() bool { return h.app.project == nil })
	h.settle()
	assertPackageUnchanged(t, installed, before)
}

// TestOfficialMavenPluginBuildsAReactor covers the Maven archive: the user's mvn
// loads the packaged core extension from the read-only package, which prints the
// reactor model (projects with their aggregator, plugin goals as model tasks)
// and a module's dependency tree, and a lifecycle task compiles the reactor. It
// uses the user's local repository, so the first run may download Maven plugins.
func TestOfficialMavenPluginBuildsAReactor(t *testing.T) {
	archive := os.Getenv("LITHE_TEST_MAVEN_PLUGIN_ARCHIVE")
	if archive == "" {
		t.Skip("set LITHE_TEST_MAVEN_PLUGIN_ARCHIVE to a maven-build-<version>-darwin.zip")
	}
	if _, err := exec.LookPath("mvn"); err != nil {
		t.Fatalf("mvn is not on PATH: %v", err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	installed := installOfficialPluginArchive(t, h, archive, "io.github.lithe-idea.maven-build")
	before := packageDigest(t, installed)
	root := t.TempDir()
	module := func(name, dependencies string) string {
		return "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n  <modelVersion>4.0.0</modelVersion>\n" +
			"  <parent><groupId>demo</groupId><artifactId>reactor</artifactId><version>1.0.0-SNAPSHOT</version></parent>\n" +
			"  <artifactId>" + name + "</artifactId>\n" + dependencies + "</project>\n"
	}
	writeFixture(t, root, map[string]string{
		"pom.xml": "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n  <modelVersion>4.0.0</modelVersion>\n" +
			"  <groupId>demo</groupId><artifactId>reactor</artifactId><version>1.0.0-SNAPSHOT</version><packaging>pom</packaging>\n" +
			"  <properties><maven.compiler.release>11</maven.compiler.release><project.build.sourceEncoding>UTF-8</project.build.sourceEncoding></properties>\n" +
			"  <modules><module>core</module><module>app</module></modules>\n</project>\n",
		"core/pom.xml": module("core", ""),
		"core/src/main/java/demo/core/Greeter.java": "package demo.core;\n\npublic final class Greeter {\n    public static String greet(String name) { return \"Hello, \" + name; }\n}\n",
		"app/pom.xml":                          module("app", "  <dependencies><dependency><groupId>demo</groupId><artifactId>core</artifactId><version>${project.version}</version></dependency></dependencies>\n"),
		"app/src/main/java/demo/app/Main.java": "package demo.app;\n\npublic final class Main {\n    public static void main(String[] args) { System.out.println(demo.core.Greeter.greet(\"Lithe\")); }\n}\n",
	})
	h.open(root)
	p := h.app.project
	if p == nil {
		t.Fatal("the reactor did not open")
	}
	h.app.loadBuildSystems(p)
	instance := awaitBuildModel(t, h, p, "maven", 3*time.Minute)
	reactor, library, application := modelProjectNamed(instance.Model, "reactor"), modelProjectNamed(instance.Model, "core"), modelProjectNamed(instance.Model, "app")
	if reactor == nil || library == nil || application == nil {
		t.Fatalf("the reactor model is missing a project: %+v", instance.Model.Projects)
	}
	if library.ParentID != reactor.ID || application.ParentID != reactor.ID || library.Path != "core" {
		t.Fatalf("the modules are not below their aggregator: %+v", instance.Model.Projects)
	}
	goals := 0
	for _, task := range instance.Model.Tasks {
		if task.Template == "plugin-goal" {
			goals++
		}
	}
	if goals == 0 {
		t.Fatalf("the model lists no plugin goals: %+v", instance.Model.Tasks)
	}

	p.build.projectID = application.ID
	deps := h.app.dependenciesOf(p, instance, application.ID)
	awaitStateWithin(t, h, 3*time.Minute, "the app dependency tree", func() bool { return !deps.loading })
	if deps.failed != "" {
		t.Fatalf("the app dependencies failed: %s", deps.failed)
	}
	if len(deps.tree.Dependencies) != 1 || deps.tree.Dependencies[0].Name != "core" || deps.tree.Dependencies[0].Scope != "compile" {
		t.Fatalf("the app dependency tree = %+v", deps.tree.Dependencies)
	}

	// The Maven executable setting is the first candidate: a path set there reloads the
	// model and runs every later command instead of mvn on PATH.
	mvnWrapper, mvnMarker := markingWrapper(t, "mvn")
	saveGlobalPluginSettings(t, h, instance, map[string]any{"mavenExecutable": mvnWrapper})
	instance = awaitBuildModel(t, h, p, "maven", 3*time.Minute)
	if _, err := os.Stat(mvnMarker); err != nil {
		t.Fatalf("the model reload did not run the configured mvn: %v", err)
	}
	if err := os.Remove(mvnMarker); err != nil {
		t.Fatal(err)
	}
	output := runBuildTaskToEnd(t, h, p, "", "compile", 5*time.Minute)
	if !strings.Contains(output, "BUILD SUCCESS") {
		t.Fatalf("mvn compile printed no success: %q", output)
	}
	if _, err := os.Stat(mvnMarker); err != nil {
		t.Fatalf("compile did not run the configured mvn: %v", err)
	}
	for _, class := range []string{"core/target/classes/demo/core/Greeter.class", "app/target/classes/demo/app/Main.class"} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(class))); err != nil {
			t.Fatalf("mvn compile did not produce %s: %v", class, err)
		}
	}
	h.app.closeProject()
	awaitStateWithin(t, h, 30*time.Second, "the closed project", func() bool { return h.app.project == nil })
	h.settle()
	assertPackageUnchanged(t, installed, before)
}
