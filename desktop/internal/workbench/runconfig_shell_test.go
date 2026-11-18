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
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shellkind"
)

// testTerminalShells is what the new-terminal menu finds on a machine with two POSIX shells,
// PowerShell, fish and a WSL distribution, so the interpreter lists do not depend on the shells
// the machine running the test has.
func testTerminalShells() []localshell.Choice {
	return []localshell.Choice{
		{Name: "zsh", Path: "/bin/zsh", Default: true},
		{Name: "bash", Path: "/bin/bash"},
		{Name: "pwsh", Path: "/usr/local/bin/pwsh"},
		{Name: "fish", Path: "/opt/homebrew/bin/fish"},
		{Name: "Ubuntu", Path: "wsl:Ubuntu"},
	}
}

// An interpreter list holds automatic, naming the program Core runs while the field is empty,
// the installed shells of the field's family in the terminal's order, the field's own value
// when it is none of them, and Custom… last. A family this host does not know is no list.
func TestRunConfigShellChoicesListTheFamilyAndCustom(t *testing.T) {
	language := i18n.English
	if _, ok := runConfigShellKind("fish"); ok {
		t.Fatal("an unknown family is drawn as a list")
	}
	kind, ok := runConfigShellKind("posix")
	if !ok || kind != shellkind.POSIX {
		t.Fatalf("posix = %v, %v", kind, ok)
	}
	shells := runConfigFamilyShells(testTerminalShells(), kind)
	if paths := []string{}; len(shells) != 2 || shells[0].Path != "/bin/zsh" || shells[1].Path != "/bin/bash" {
		for _, shell := range shells {
			paths = append(paths, shell.Path)
		}
		t.Fatalf("POSIX shells = %v", paths)
	}
	if shells := runConfigFamilyShells(testTerminalShells(), shellkind.PowerShell); len(shells) != 1 || shells[0].Name != "pwsh" {
		t.Fatalf("PowerShell shells = %+v", shells)
	}

	automatic := "/bin/sh"
	choices, labels, current := runConfigShellChoices(language, &automatic, shells, "/bin/bash")
	if want := []string{"", "/bin/zsh", "/bin/bash", runConfigShellCustom}; !slices.Equal(choices, want) || current != "/bin/bash" {
		t.Fatalf("choices = %q current %q, want %q", choices, current, want)
	}
	if labels[""] != "Automatic (/bin/sh)" || labels["/bin/bash"] != "bash (/bin/bash)" || labels[runConfigShellCustom] != "Custom…" {
		t.Fatalf("labels = %q", labels)
	}

	choices, labels, current = runConfigShellChoices(language, nil, shells, "tools/sh")
	if want := []string{"", "/bin/zsh", "/bin/bash", "tools/sh", runConfigShellCustom}; !slices.Equal(choices, want) || current != "tools/sh" {
		t.Fatalf("choices of a value of the user's own = %q current %q", choices, current)
	}
	if labels[""] != "Automatic" || labels["tools/sh"] != "tools/sh" {
		t.Fatalf("labels without an automatic value = %q", labels)
	}
	if _, _, current := runConfigShellChoices(language, &automatic, shells, ""); current != "" {
		t.Fatalf("an empty field stands for %q, want automatic", current)
	}
}

// The interpreter of a shell script run is chosen from the shells the new-terminal menu finds:
// picking one writes its path into the field and saves it, Custom… shows a field for a program
// of the user's own that keeps the value until another entry is picked, and automatic empties
// the field again.
func TestRunConfigInterpreterListsTheTerminalShells(t *testing.T) {
	h, p, root := emptyProcessRunHarness(t)
	// Saving exercises Core's native path validation. Keep the WSL identifier and
	// give the file-backed shell choices absolute paths on the test host.
	shellDir := t.TempDir()
	writeTreeFiles(t, shellDir, "bash")
	shells := testTerminalShells()
	for i, shell := range shells {
		if !strings.HasPrefix(shell.Path, "wsl:") {
			shells[i].Path = filepath.Join(shellDir, shell.Name)
		}
	}
	h.app.listShells = func() []localshell.Choice { return slices.Clone(shells) }
	f := newRunConfigDraft(t, h, p, runProviderShell)
	fillScriptText(t, h, p, f, "Greet", "echo hi\n")
	awaitStateWithin(t, h, 10*time.Second, "the terminal's shells", func() bool { return len(h.app.term.shells.list) == len(shells) })
	h.settle()
	interpreter := f.texts["interpreter"]
	if interpreter == nil {
		t.Fatal("the shell script form has no interpreter field")
	}
	for _, field := range f.fields {
		if field.ID == "interpreter" && field.ShellFamily != "posix" {
			t.Fatalf("the interpreter field takes the %q family", field.ShellFamily)
		}
	}

	language := h.app.language()
	label, _ := runConfigFieldLabel(language, "interpreter")
	custom := i18n.Shared(language, "desktop.runConfig.interpreterCustomField")
	shell := func(name, path string) string {
		return i18n.SharedFormat(language, "desktop.runConfig.interpreterShell", map[string]string{"name": name, "path": path})
	}
	choose := func(entry string) {
		t.Helper()
		h.click(center(h.hitLabeled(label)))
		if h.hasPopupItem(shell("pwsh", filepath.Join(shellDir, "pwsh"))) || h.hasPopupItem(shell("fish", filepath.Join(shellDir, "fish"))) {
			t.Fatal("the list offers a shell of another family")
		}
		h.click(center(h.popupHit(entry)))
	}

	bashPath := filepath.Join(shellDir, "bash")
	choose(shell("bash", bashPath))
	if *interpreter != bashPath || h.hasPopupItem(custom) {
		t.Fatalf("interpreter %q, custom field shown %v", *interpreter, h.hasPopupItem(custom))
	}

	choose(i18n.Shared(language, "desktop.runConfig.interpreterCustom"))
	if *interpreter != bashPath || !h.hasPopupItem(custom) {
		t.Fatalf("Custom…: interpreter %q, custom field shown %v", *interpreter, h.hasPopupItem(custom))
	}
	h.typeInto(custom, func() { *interpreter = "" }, "tools/sh")
	if *interpreter != "tools/sh" || !h.hasPopupItem(custom) {
		t.Fatalf("typed interpreter %q, custom field shown %v", *interpreter, h.hasPopupItem(custom))
	}

	choose(shell("bash", bashPath))
	if *interpreter != bashPath || h.hasPopupItem(custom) {
		t.Fatalf("back to bash: interpreter %q, custom field shown %v", *interpreter, h.hasPopupItem(custom))
	}
	applyDialog(t, h, p, runConfigDialogApply)
	if _, err := os.Stat(filepath.Join(root, ".lithe", "run", "local.yaml")); err != nil {
		t.Fatalf("save local.yaml: %v, dialog failure %q, form failure %q, field errors %v", err, p.runConfigs.dialog.failure, f.failure, f.errors)
	}

	id := p.runConfigs.dialog.selected
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	saved, err := h.app.kernel.RunEditorForm(ctx, core.RunEditorFormRequest{Root: root, Provider: runProviderShell, ConfigurationID: id})
	if err != nil {
		t.Fatalf("load configuration %q: %v", id, err)
	}
	var savedInterpreter string
	if err := json.Unmarshal(saved.Values["interpreter"], &savedInterpreter); err != nil || savedInterpreter != bashPath {
		t.Fatalf("saved interpreter = %q, want %q: %v", savedInterpreter, bashPath, err)
	}

	f = p.runConfigs.dialog.drafts[id].form
	awaitStateWithin(t, h, 10*time.Second, "the saved configuration's form", func() bool { return f != nil && f.ready() })
	interpreter = f.texts["interpreter"]
	choose(i18n.SharedFormat(language, "desktop.runConfig.automaticValue", map[string]string{"value": automaticInterpreter(t, f)}))
	if *interpreter != "" || h.hasPopupItem(custom) {
		t.Fatalf("automatic: interpreter %q, custom field shown %v", *interpreter, h.hasPopupItem(custom))
	}
}

// automaticInterpreter is the program Core runs while the interpreter field of f is empty.
func automaticInterpreter(t *testing.T, f *runConfigForm) string {
	t.Helper()
	for _, field := range f.fields {
		if field.ID == "interpreter" && field.Automatic != nil {
			return *field.Automatic
		}
	}
	t.Fatal("the interpreter field names no automatic program")
	return ""
}
