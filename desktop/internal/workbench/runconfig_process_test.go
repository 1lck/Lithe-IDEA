package workbench

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// A bare command is found only in the absolute directories of the search path, in order; a
// relative entry such as the current directory is never searched.
func TestRunCommandOnPathSkipsRelativeDirectories(t *testing.T) {
	first, second := t.TempDir(), t.TempDir()
	name := "lithe-test-tool"
	file := name
	if runtime.GOOS == "windows" {
		file += ".exe"
	}
	for _, directory := range []string{first, second} {
		if err := os.WriteFile(filepath.Join(directory, file), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	relative, err := filepath.Rel(mustGetwd(t), first)
	if err != nil {
		relative = "relative-entry"
	}
	searchPath := strings.Join([]string{"", relative, second, first}, string(os.PathListSeparator))
	got, err := runCommandOnPath(name, searchPath)
	if err != nil || filepath.Dir(got) != second {
		t.Fatalf("found %q, %v; want the copy in %s", got, err, second)
	}
	if _, err := runCommandOnPath("lithe-test-missing", searchPath); !errors.Is(err, errRunProgramNotFound) || !errors.Is(err, exec.ErrNotFound) {
		t.Fatalf("missing command = %v", err)
	}
}

func mustGetwd(t *testing.T) string {
	t.Helper()
	directory, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return directory
}

// A script saved as text is written only as a new file directly in the run's temporary
// directory.
func TestWriteInlineScriptStaysInItsDirectory(t *testing.T) {
	scratch := t.TempDir()
	path := filepath.Join(scratch, "script.sh")
	if err := writeInlineScript(scratch, core.RunInlineScript{Path: path, Content: "echo hi\n"}); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != "echo hi\n" {
		t.Fatalf("script = %q, %v", data, err)
	}
	if err := writeInlineScript(scratch, core.RunInlineScript{Path: path, Content: "other"}); err == nil {
		t.Fatal("an existing script was overwritten")
	}
	for _, outside := range []string{filepath.Join(t.TempDir(), "script.sh"), filepath.Join(scratch, "nested", "script.sh")} {
		if err := writeInlineScript(scratch, core.RunInlineScript{Path: outside, Content: "x"}); err == nil {
			t.Fatalf("a script was written at %s", outside)
		}
	}
}

// The working directory Core plans is joined under the project; one that leaves it is
// refused here too.
func TestProjectRunDirectoryStaysInTheProject(t *testing.T) {
	root := t.TempDir()
	for directory, want := range map[string]string{"": root, ".": root, "app/server": filepath.Join(root, "app", "server")} {
		if got, err := projectRunDirectory(root, directory); err != nil || got != want {
			t.Fatalf("%q = %q, %v; want %q", directory, got, err, want)
		}
	}
	for _, directory := range []string{"..", "../other", "app/../../other"} {
		if got, err := projectRunDirectory(root, directory); err == nil {
			t.Fatalf("%q = %q, want a refusal", directory, got)
		}
	}
}

// A browsed path inside the project shows project-relative with '/'; a program directly in
// the project root keeps "./" so it is not looked up on PATH; anything else stays absolute.
func TestRunConfigFieldPathIsProjectRelative(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "tool")
	cases := []struct{ path, kind, want string }{
		{filepath.Join(root, "scripts", "build.sh"), runFieldFile, "scripts/build.sh"},
		{filepath.Join(root, "tool"), runFieldExecutable, "./tool"},
		{filepath.Join(root, "bin", "tool"), runFieldExecutable, "bin/tool"},
		{root, runFieldDirectory, "."},
		{outside, runFieldExecutable, outside},
	}
	for _, c := range cases {
		if got := runConfigFieldPath(root, c.path, c.kind); got != c.want {
			t.Fatalf("%s (%s) = %q, want %q", c.path, c.kind, got, c.want)
		}
	}
}

// A field with a condition shows only while the other field holds the value; one without
// always shows.
func TestVisibleRunConfigFieldFollowsItsCondition(t *testing.T) {
	script := core.RunEditorField{ID: "script", Kind: runFieldFile, VisibleWhen: &core.RunFieldCondition{Field: "source", Equals: "file"}}
	name := core.RunEditorField{ID: "name", Kind: runFieldText}
	for source, want := range map[string]bool{`"file"`: true, `"text"`: false} {
		values := map[string]json.RawMessage{"source": json.RawMessage(source)}
		if got := visibleRunConfigField(script, values); got != want {
			t.Fatalf("script with source %s visible = %v", source, got)
		}
		if !visibleRunConfigField(name, values) {
			t.Fatal("a field without a condition is hidden")
		}
	}
	if visibleRunConfigField(script, map[string]json.RawMessage{}) {
		t.Fatal("a field whose condition has no value is shown")
	}
}

// The values a save sends are Core's values with every edit over them; a value of a field
// this host does not draw goes back unchanged.
func TestRunConfigFormCollectKeepsValuesItDoesNotDraw(t *testing.T) {
	f := &runConfigForm{values: map[string]json.RawMessage{}, texts: map[string]*string{}, flags: map[string]*bool{}}
	f.fields = []core.RunEditorField{
		{ID: "name", Kind: runFieldText},
		{ID: "storeAsProjectFile", Kind: runFieldCheckbox},
		{ID: "environment", Kind: runFieldEnvironment},
	}
	f.readValues(f.fields, map[string]json.RawMessage{
		"name":               json.RawMessage(`"Old"`),
		"storeAsProjectFile": json.RawMessage(`false`),
		"environment":        json.RawMessage(`[{"name":"A","value":"1"}]`),
		"future":             json.RawMessage(`{"kept":true}`),
	})
	f.values["future"] = json.RawMessage(`{"kept":true}`)
	*f.texts["name"] = "New"
	*f.flags["storeAsProjectFile"] = true
	f.environment = append(f.environment, &runConfigVariable{name: "B", value: "2"})
	got := f.collect()
	want := map[string]string{
		"name":               `"New"`,
		"storeAsProjectFile": `true`,
		"environment":        `[{"name":"A","value":"1"},{"name":"B","value":"2"}]`,
		"future":             `{"kept":true}`,
	}
	for id, value := range want {
		if string(got[id]) != value {
			t.Fatalf("%s = %s, want %s", id, got[id], value)
		}
	}
}

// A project without any build plugin creates a built-in run from the editor, saves it to the
// project file and starts it with Run; the output reaches the Run window and the temporary
// script is removed. The title bar's Run button starts it again. The script runs under the
// system's own shell (cmd on Windows), so no developer tool is needed.
func TestBuiltInRunIsCreatedAndRunWithoutAnyPlugin(t *testing.T) {
	temporary := t.TempDir()
	for _, variable := range []string{"TMPDIR", "TMP", "TEMP"} {
		t.Setenv(variable, temporary)
	}
	provider, text := runProviderShell, "echo hello-from-lithe\n"
	if runtime.GOOS == "windows" {
		provider, text = runProviderBatch, "@echo hello-from-lithe\r\n"
	}
	root := t.TempDir()
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
	awaitStateWithin(t, h, 10*time.Second, "the empty configuration list", func() bool {
		s := &p.runConfigs
		return s.generation > 0 && !s.loading && s.types != nil
	})
	if s := &p.runConfigs; s.failure != "" || len(s.list) != 0 {
		t.Fatalf("configurations = %+v failure %q", s.list, s.failure)
	}

	f := newRunConfigDraft(t, h, p, provider)
	h.app.post(func(a *App) {
		*f.texts["name"] = "Greet"
		*f.texts["source"] = "text"
		*f.flags["storeAsProjectFile"] = true
		a.runConfigFormEdited(p, f)
	})
	awaitStateWithin(t, h, 10*time.Second, "the text field", func() bool { return !f.refreshing && f.texts["text"] != nil })
	h.app.post(func(a *App) {
		*f.texts["text"] = text
		a.applyRunConfigDialog(p, runConfigDialogRun)
	})
	d := &p.runConfigs.dialog
	awaitStateWithin(t, h, 10*time.Second, "the save", func() bool { return !d.open || len(f.errors) > 0 || f.failure != "" })
	if d.open {
		t.Fatalf("the dialog stayed open: errors %v failure %q", f.errors, f.failure)
	}
	first := awaitProcessRun(t, h, p, "Greet", nil)
	if !strings.Contains(first.output.all(), "hello-from-lithe") {
		t.Fatalf("console:\n%s", first.output.all())
	}
	if !h.app.chrome.isOpen(catalogIndex[itemRun]) || p.build.view != first.id {
		t.Fatalf("the Run window is not showing the run: open %v, view %q", h.app.chrome.isOpen(catalogIndex[itemRun]), p.build.view)
	}
	data, err := os.ReadFile(filepath.Join(root, ".lithe", "run", "configurations.yaml"))
	if err != nil || !strings.Contains(string(data), "Greet") || !strings.Contains(string(data), provider) {
		t.Fatalf("configurations.yaml = %s, %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(root, ".lithe", "run", "local.yaml")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the local layer was written: %v", err)
	}
	if left, _ := filepath.Glob(filepath.Join(temporary, inlineScriptDirectoryPattern+"*")); len(left) != 0 {
		t.Fatalf("temporary scripts left behind: %v", left)
	}

	if c := p.titleConfiguration(); c == nil || c.Name != "Greet" {
		t.Fatalf("title configuration = %+v", c)
	}
	h.app.post(func(a *App) { a.titleRun(p) })
	again := awaitProcessRun(t, h, p, "Greet", first)
	if !strings.Contains(again.output.all(), "hello-from-lithe") {
		t.Fatalf("the title bar's Run did not run it again; console:\n%s", again.output.all())
	}
}

// newRunConfigDraft opens the Run/Debug Configurations dialog, adds a configuration of
// provider as the + menu does and waits for its form.
func newRunConfigDraft(t *testing.T, h *harness, p *project, provider string) *runConfigForm {
	t.Helper()
	d := &p.runConfigs.dialog
	h.app.post(func(a *App) {
		a.openRunConfigDialog(p, "")
		a.addRunConfigDraft(p, builtInKind(provider), nil)
	})
	var f *runConfigForm
	awaitStateWithin(t, h, 10*time.Second, "the new configuration's form", func() bool {
		if draft := d.drafts[d.selected]; d.open && draft != nil && draft.form != nil {
			f = draft.form
		}
		return f != nil && f.open && !f.loading && f.fields != nil
	})
	return f
}

// awaitProcessRun waits for an ended run session labeled label other than previous and
// requires it to have succeeded. A new run replaces the ended tab of the same label and the
// harness clock does not advance by itself, so the session is told apart by identity, not by
// its start time.
func awaitProcessRun(t *testing.T, h *harness, p *project, label string, previous *runEntry) *runEntry {
	t.Helper()
	var found *runEntry
	defer func() {
		if found == nil {
			for _, entry := range p.build.runs {
				t.Logf("session %q running %v outcome %v summary %q console:\n%s", entry.label, entry.running, entry.outcome, entry.summary, entry.output.all())
			}
			t.Logf("configurations %+v failure %q notice %q", p.runConfigs.list, p.runConfigs.failure, lastNotice(h))
		}
	}()
	awaitStateWithin(t, h, 20*time.Second, "the run of "+label, func() bool {
		for _, entry := range p.build.runs {
			if entry != previous && entry.label == label && !entry.running && !p.build.active() {
				found = entry
				return true
			}
		}
		return false
	})
	if found.outcome != runSucceeded || found.summary != h.app.text.Run.Exited(0) {
		t.Fatalf("run %s ended %v: %s; console:\n%s", label, found.outcome, found.summary, found.output.all())
	}
	return found
}

// A plugin's run configuration file that cannot be read leaves the built-in runs listed, and
// the run menu names the file whose configurations are missing.
func TestUnreadablePluginRunDocumentKeepsBuiltInRunsListed(t *testing.T) {
	root := t.TempDir()
	plugins := filepath.Join(root, ".lithe", "run", "plugin")
	if err := os.MkdirAll(plugins, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(plugins, "dev.example.engine.toml"), []byte("["), 0o600); err != nil {
		t.Fatal(err)
	}
	saved := "version: 2\nconfigurations:\n- id: user:greet\n  name: Greet\n  provider: " + runProviderShell + "\n"
	if err := os.WriteFile(filepath.Join(root, ".lithe", "run", "configurations.yaml"), []byte(saved), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(root)
	p := h.app.project
	h.app.post(func(a *App) { a.refreshRunConfigurations(p) })
	awaitStateWithin(t, h, 10*time.Second, "the run configurations", func() bool {
		return p.runConfigs.generation > 0 && !p.runConfigs.loading
	})
	s := &p.runConfigs
	if s.failure != "" || s.configuration("user:greet") == nil {
		t.Fatalf("configurations = %+v failure %q", s.list, s.failure)
	}
	path := ".lithe/run/plugin/dev.example.engine.toml"
	if len(s.ignored) != 1 || s.ignored[0] != path {
		t.Fatalf("ignored = %v, want [%s]", s.ignored, path)
	}
	h.click(center(h.button(itemRunConfig)))
	h.settle()
	text := i18n.SharedFormat(h.app.language(), "desktop.runConfig.documentIgnored", map[string]string{"file": "dev.example.engine.toml"})
	if !h.shows(text) {
		t.Fatalf("the run menu does not show %q", text)
	}
	h.clickNamed(text)
	file := filepath.Join(plugins, "dev.example.engine.toml")
	awaitStateWithin(t, h, 10*time.Second, "the unread file in the editor", func() bool { return p.docs.byPath(file) != nil })
}
