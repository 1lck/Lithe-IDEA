package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

type invocationKernel struct {
	*testKernel
	invocation core.BuildInvocation
}

func (k *invocationKernel) PlanBuildInvocation(context.Context, json.RawMessage, string, core.BuildInvocationRequest) (core.BuildInvocation, error) {
	return k.invocation, nil
}

// These candidate-execution tests inject the invocation independently of a manifest.
func (k *invocationKernel) ReadPluginSettingsState(context.Context, json.RawMessage, *string, *string, *core.PluginSettingsLocalizationRequest) (core.PluginSettingsState, error) {
	return core.PluginSettingsState{}, nil
}

func TestApplyToolchainSelectionKeepsConsumerValues(t *testing.T) {
	environment := applyToolchainSelection(map[string]string{
		"JAVA_HOME": "/plan/jdk",
		"PATH":      "/usr/bin",
	}, core.ToolchainSelection{
		Environment: map[string]string{
			"JAVA_HOME": "/tool/jdk",
			"VM_HOME":   "/tool/vm",
		},
		PathPrepend: []string{"/tool/jdk/bin"},
	})
	if environment["JAVA_HOME"] != "/plan/jdk" {
		t.Fatalf("consumer value was overwritten: %q", environment["JAVA_HOME"])
	}
	if environment["VM_HOME"] != "/tool/vm" {
		t.Fatalf("tool export missing: %q", environment["VM_HOME"])
	}
	want := "/tool/jdk/bin" + string(filepath.ListSeparator) + "/usr/bin"
	if environment["PATH"] != want {
		t.Fatalf("PATH = %q, want %q", environment["PATH"], want)
	}
}

func TestResolveBuildExecutableUsesToolchainSelection(t *testing.T) {
	kernel := &invocationKernel{
		testKernel: &testKernel{Client: core.NewClient()},
		invocation: core.BuildInvocation{Executables: []core.BuildExecutableCandidate{
			{Kind: "toolchain", ToolchainID: "dev.example:compiler"},
		}},
	}
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	p := h.app.project
	executable := filepath.Join(t.TempDir(), "bin", "cc")
	if err := writeFakeExecutable(executable); err != nil {
		t.Fatal(err)
	}
	h.app.toolchainResolve = func(_ context.Context, _, directory, tool, _ string) (core.ToolchainSelection, error) {
		if directory != "." {
			t.Fatalf("directory = %q, want the build root", directory)
		}
		if tool != "dev.example:compiler" {
			t.Fatalf("tool = %q", tool)
		}
		return core.ToolchainSelection{
			Executable:  executable,
			Environment: map[string]string{"FICTIONAL_CC_HOME": "/tool"},
			PathPrepend: []string{"/tool/bin"},
		}, nil
	}
	execution, err := h.app.resolveBuildExecutable(context.Background(), p, buildInstance{
		BuildInstance: core.BuildInstance{Root: "."},
	}, h.app.text.Build)
	if err != nil {
		t.Fatal(err)
	}
	if execution.Executable != executable {
		t.Fatalf("executable = %q, want %q", execution.Executable, executable)
	}
	if execution.Environment["FICTIONAL_CC_HOME"] != "/tool" {
		t.Fatalf("environment = %+v", execution.Environment)
	}
	if len(execution.PathPrepend) != 1 || execution.PathPrepend[0] != "/tool/bin" {
		t.Fatalf("path prepend = %+v", execution.PathPrepend)
	}
}

func TestResolveBuildExecutableFallsBackFromAnUnavailableToolchain(t *testing.T) {
	// Only command discovery is under test; this fixture is never started.
	bin := t.TempDir()
	name := "fixture-fallback"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	fallback := filepath.Join(bin, name)
	if err := writeFakeExecutable(fallback); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))
	if runtime.GOOS == "windows" {
		t.Setenv("PATHEXT", ".EXE")
	}
	kernel := &invocationKernel{
		testKernel: &testKernel{Client: core.NewClient()},
		invocation: core.BuildInvocation{Executables: []core.BuildExecutableCandidate{
			{Kind: "toolchain", ToolchainID: "dev.example:compiler"},
			{Kind: "command", Command: "fixture-fallback"},
		}},
	}
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	p := h.app.project
	h.app.toolchainResolve = func(context.Context, string, string, string, string) (core.ToolchainSelection, error) {
		return core.ToolchainSelection{}, &toolchain.UnavailableError{Tool: "dev.example:compiler", Code: "notFound"}
	}
	execution, err := h.app.resolveBuildExecutable(context.Background(), p, buildInstance{
		BuildInstance: core.BuildInstance{Root: "."},
	}, h.app.text.Build)
	if err != nil {
		t.Fatal(err)
	}
	if execution.Executable != fallback {
		t.Fatalf("executable = %q, want the command fallback", execution.Executable)
	}
}

func writeFakeExecutable(name string) error {
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		return err
	}
	return os.WriteFile(name, []byte("#!/bin/sh\n"), 0o755)
}
