package core

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Core lists a folder's devcontainer.json files with their names in the specification's order, and
// refuses a relative folder before reading anything.
func TestRemoteDevcontainerConfigsListTheFolder(t *testing.T) {
	folder := t.TempDir()
	write := func(path, text string) {
		t.Helper()
		full := filepath.Join(folder, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(".devcontainer/devcontainer.json", "{\n  // the default\n  \"name\": \"Go\",\n}\n")
	write(".devcontainer/node/devcontainer.json", `{"image": "node"}`)
	client := NewClient()
	configs, err := client.RemoteDevcontainerConfigs(testContext(t), folder)
	want := []DevcontainerConfig{
		{Path: ".devcontainer/devcontainer.json", Name: "Go"},
		{Path: ".devcontainer/node/devcontainer.json"},
	}
	if err != nil || !reflect.DeepEqual(configs, want) {
		t.Fatalf("configs = %+v, %v; want %d configurations", configs, err, len(want))
	}
	empty, err := client.RemoteDevcontainerConfigs(testContext(t), t.TempDir())
	if err != nil || empty == nil || len(empty) != 0 {
		t.Fatalf("configs of an empty folder = %+v, %v; want an empty list", empty, err)
	}
	var coreErr *Error
	if _, err := client.RemoteDevcontainerConfigs(testContext(t), "relative"); !errors.As(err, &coreErr) || coreErr.Code != CodeInvalidRequest {
		t.Fatalf("configs of a relative folder = %v, want invalid_request", err)
	}
}

// An untrusted folder runs nothing, and a config the folder does not list is refused before the
// CLI starts; neither depends on what this machine has installed.
func TestRemoteDevcontainerUpRefusesBeforeTheCLIRuns(t *testing.T) {
	folder := t.TempDir()
	client := NewClient()
	output := func(DevcontainerOutput) { t.Error("the CLI's log reached the window although nothing ran") }
	var coreErr *Error
	_, err := client.RemoteDevcontainerUp(testContext(t), DevcontainerUpRequest{Folder: folder, Engine: ContainerEngineDocker}, output)
	if !errors.As(err, &coreErr) || coreErr.Code != CodeDevcontainerUntrustedFolder {
		t.Fatalf("up of an untrusted folder = %v, want devcontainer_untrusted_folder", err)
	}
	request := DevcontainerUpRequest{Folder: folder, Config: "../devcontainer.json", Engine: ContainerEngineDocker, ProjectCodeAllowed: true}
	if _, err := client.RemoteDevcontainerUp(testContext(t), request, output); !errors.As(err, &coreErr) || coreErr.Code != CodeInvalidRequest {
		t.Fatalf("up with an unlisted config = %v, want invalid_request", err)
	}
	wire, err := json.Marshal(DevcontainerUpRequest{Folder: "/f", Engine: ContainerEnginePodman})
	if err != nil || string(wire) != `{"folder":"/f","engine":"podman","projectCodeAllowed":false}` {
		t.Fatalf("request = %s, %v", wire, err)
	}
}

// Only devcontainerOutput events reach the window, in order, with the truncation note.
func TestDevcontainerOutputObserverPassesTheCLIsLog(t *testing.T) {
	if devcontainerOutputObserver(nil) != nil {
		t.Fatal("a nil output must observe nothing")
	}
	var got []DevcontainerOutput
	observe := devcontainerOutputObserver(func(line DevcontainerOutput) { got = append(got, line) })
	for _, raw := range []string{
		`{"type":"remoteStage","stage":"connecting","operationId":"a"}`,
		`{"type":"devcontainerOutput","text":"Step 1/3","operationId":"a"}`,
		`{"type":"other","text":"devcontainerOutput"}`,
		`{"type":"devcontainerOutput","truncated":true,"operationId":"a"}`,
		`not json "devcontainerOutput"`,
	} {
		observe(json.RawMessage(raw))
	}
	want := []DevcontainerOutput{{Text: "Step 1/3"}, {Truncated: true}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("output = %+v, want %d events", got, len(want))
	}
	connection := Devcontainer{Engine: ContainerEngineDocker, Container: "web", ContainerID: "abc", User: "dev", WorkspaceFolder: "/workspaces/app"}.Connection()
	if connection != (ContainerConnection{Engine: ContainerEngineDocker, Container: "web", User: "dev"}) {
		t.Fatalf("connection = %+v", connection)
	}
}
