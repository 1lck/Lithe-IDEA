//go:build windows

package workbench

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const nativeModelHelper = "LITHE_TEST_NATIVE_MODEL_COMMAND"

// A real .cmd forwards quoted paths to this synthetic build tool. It returns a
// contract model only if both arguments survived cmd.exe and the working
// directory is the project the model belongs to.
func TestWindowsModelCommandHelper(t *testing.T) {
	if os.Getenv(nativeModelHelper) != "1" {
		return
	}
	index := slices.Index(os.Args, "--")
	root, err := os.Getwd()
	if err != nil || index < 0 || len(os.Args[index+1:]) != 2 {
		os.Exit(21)
	}
	arguments := os.Args[index+1:]
	if !strings.EqualFold(filepath.Clean(arguments[0]), root) || !strings.EqualFold(filepath.Clean(arguments[1]), filepath.Join(root, "model out.json")) {
		os.Exit(22)
	}
	fmt.Print(`{"format":"litheBuildModel","version":0,"projects":[{"path":".","name":"native-path-model"}]}`)
	os.Exit(0)
}

func TestBuildModelLoadsFromPathOnlyBatchToolInUserProfiles(t *testing.T) {
	for _, profileName := range []string{"User With Spaces", "用户 甲"} {
		t.Run(profileName, func(t *testing.T) {
			profile := filepath.Join(t.TempDir(), profileName)
			bin := filepath.Join(profile, "Program Files", "Build Tool", "bin")
			workspace := filepath.Join(profile, "Projects", "sample project")
			for _, directory := range []string{bin, workspace} {
				if err := os.MkdirAll(directory, 0o755); err != nil {
					t.Fatal(err)
				}
			}
			helper := filepath.Join(bin, "model-helper.exe")
			copyTestBinary(t, helper)
			// Keep the script ASCII. cmd expands the Unicode helper path from its
			// Unicode environment, without depending on the machine's code page.
			body := "@echo off\r\n\"%LITHE_TEST_MODEL_HELPER%\" \"-test.run=^TestWindowsModelCommandHelper$\" -- %*\r\nexit /b %ERRORLEVEL%\r\n"
			if err := os.WriteFile(filepath.Join(bin, "fixture-build.cmd"), []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			t.Setenv(nativeModelHelper, "1")
			t.Setenv("LITHE_TEST_MODEL_HELPER", helper)
			t.Setenv("HOME", profile)
			t.Setenv("USERPROFILE", profile)
			t.Setenv("PATHEXT", ".COM;.EXE;.BAT;.CMD")
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			h, plugins, p := buildCommandHarnessAt(t, workspace)
			instance := buildCommandInstance(".", false)
			var manifest map[string]any
			if err := json.Unmarshal(instance.Manifest, &manifest); err != nil {
				t.Fatal(err)
			}
			system := manifest["buildSystems"].([]any)[0].(map[string]any)
			system["model"].(map[string]any)["arguments"] = []string{p.root, filepath.Join(p.root, "model out.json")}
			var err error
			instance.Manifest, err = json.Marshal(manifest)
			if err != nil {
				t.Fatal(err)
			}
			model, err := h.app.commandModel(buildLoadContext(t, "native-path-model", pluginOperationWait), p, instance, h.app.kernel, nil, h.app.text.Build)
			if err != nil {
				t.Fatal(err)
			}
			if len(model.Projects) != 1 || model.Projects[0].Name != "native-path-model" {
				t.Fatalf("model = %+v, want the model returned by the batch tool", model)
			}
			wantPluginOperation(t, plugins.next(t, "batch model decoded"), core.PluginOperation{
				PluginID: buildCommandPluginID, Operation: core.OperationBuildModel,
				Outcome: "finished", OperationID: "native-path-model",
			})
			plugins.none(t)
		})
	}
}
