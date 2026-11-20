package workbench

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

const buildProbeHelperEnv = "LITHE_TEST_BUILD_PROBE_HELPER"

func probeSidecarPath(exePath string) string {
	if strings.EqualFold(filepath.Ext(exePath), ".exe") {
		return strings.TrimSuffix(exePath, filepath.Ext(exePath)) + ".probe"
	}
	return exePath + ".probe"
}

func maybeRunBuildProbeHelper() bool {
	if os.Getenv(buildProbeHelperEnv) != "1" {
		return false
	}
	modeBytes, err := os.ReadFile(probeSidecarPath(os.Args[0]))
	if err != nil {
		return false
	}
	mode := strings.TrimSpace(string(modeBytes))
	if len(os.Args) > 1 && os.Args[1] == "--require-env" {
		key, want, _ := strings.Cut(os.Args[2], "=")
		if os.Getenv(key) != want {
			fmt.Fprintf(os.Stderr, "missing env %s=%s (got %q)\n", key, want, os.Getenv(key))
			os.Exit(4)
		}
	}
	switch {
	case strings.HasPrefix(mode, "ok:"):
		fmt.Println(strings.TrimPrefix(mode, "ok:"))
		os.Exit(0)
	case strings.HasPrefix(mode, "fail:"):
		fmt.Fprintln(os.Stderr, strings.TrimPrefix(mode, "fail:"))
		os.Exit(2)
	case strings.HasPrefix(mode, "hang:"):
		marker := strings.TrimPrefix(mode, "hang:")
		if marker != "" {
			_ = os.WriteFile(marker, []byte("started\n"), 0o600)
		}
		timer := time.NewTimer(30 * time.Second)
		defer timer.Stop()
		<-timer.C
		os.Exit(7)
	default:
		fmt.Fprintf(os.Stderr, "unknown probe mode %q\n", mode)
		os.Exit(3)
	}
	return true
}

func writeProbeTool(t *testing.T, dir, name, mode string) string {
	t.Helper()
	exeName := name
	if runtime.GOOS == "windows" {
		exeName += ".exe"
	}
	dest := filepath.Join(dir, exeName)
	copyTestBinary(t, dest)
	if err := os.WriteFile(probeSidecarPath(dest), []byte(mode+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dest
}

type probeVersionKernel struct {
	*invocationKernel
	calls []string
}

func (k *probeVersionKernel) CheckBuildToolVersion(_ context.Context, _ json.RawMessage, _, reqID, output string) (core.BuildToolVersion, error) {
	k.calls = append(k.calls, reqID+":"+strings.TrimSpace(output))
	if strings.Contains(output, "Version 2.0.0") || strings.Contains(output, "Runtime 21.0.0") {
		return core.BuildToolVersion{Satisfied: true, Version: "2.0.0"}, nil
	}
	if strings.Contains(output, "Version 1.0.0") || strings.Contains(output, "Runtime 8.0.0") {
		return core.BuildToolVersion{Satisfied: false, Version: "1.0.0"}, nil
	}
	return core.BuildToolVersion{}, fmt.Errorf("unrecognized version output %q", output)
}

func TestProbeBuildToolReturnsOutputOnZeroExit(t *testing.T) {
	t.Setenv(buildProbeHelperEnv, "1")
	dir := t.TempDir()
	tool := writeProbeTool(t, dir, "good-tool", "ok:Version 2.0.0")
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	out, err := probeBuildTool(ctx, tool, []string{"--version"}, dir, nil)
	if err != nil {
		t.Fatalf("probeBuildTool returned error on exit 0: %v", err)
	}
	if !strings.Contains(out, "Version 2.0.0") {
		t.Fatalf("output = %q, want Version 2.0.0", out)
	}
}

func TestProbeBuildToolRejectsNonZeroExitWithOutput(t *testing.T) {
	t.Setenv(buildProbeHelperEnv, "1")
	dir := t.TempDir()
	tool := writeProbeTool(t, dir, "broken-tool", "fail:broken banner Version 2.0.0")
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	out, err := probeBuildTool(ctx, tool, []string{"--version"}, dir, nil)
	if err == nil {
		t.Fatalf("probeBuildTool succeeded on non-zero exit (output=%q), want error", out)
	}
}

func TestProbeBuildToolBoundsHangingProcess(t *testing.T) {
	t.Setenv(buildProbeHelperEnv, "1")
	origTimeout := buildToolProbeTimeout
	buildToolProbeTimeout = 1200 * time.Millisecond
	t.Cleanup(func() { buildToolProbeTimeout = origTimeout })

	dir := t.TempDir()
	started := filepath.Join(t.TempDir(), "started")
	tool := writeProbeTool(t, dir, "hang-tool", "hang:"+started)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	begin := time.Now()
	_, err := probeBuildTool(ctx, tool, []string{"--version"}, dir, nil)
	elapsed := time.Since(begin)
	if err == nil {
		t.Fatal("probeBuildTool succeeded on hanging process")
	}
	if elapsed > 6*time.Second {
		t.Fatalf("probeBuildTool took %s, expected bound near %s", elapsed, buildToolProbeTimeout)
	}
	if _, statErr := os.Stat(started); statErr != nil {
		t.Fatalf("hanging probe did not start before timing out: %v", statErr)
	}
}

func TestResolveBuildExecutableFallsBackAcrossAutomaticCandidates(t *testing.T) {
	t.Setenv(buildProbeHelperEnv, "1")
	if runtime.GOOS == "windows" {
		t.Setenv("PATHEXT", ".EXE")
	}
	origTimeout := buildToolProbeTimeout
	buildToolProbeTimeout = 1500 * time.Millisecond
	t.Cleanup(func() { buildToolProbeTimeout = origTimeout })

	t.Run("non-zero command falls back to next command", func(t *testing.T) {
		bin := t.TempDir()
		writeProbeTool(t, bin, "tool-broken", "fail:broken candidate")
		good := writeProbeTool(t, bin, "tool-good", "ok:Version 2.0.0")
		t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))

		kernel := &probeVersionKernel{invocationKernel: &invocationKernel{
			testKernel: &testKernel{Client: core.NewClient()},
			invocation: core.BuildInvocation{
				MinimumVersion: "2.0.0",
				Version:        &core.BuildVersionProbe{Arguments: []string{"--version"}},
				Executables: []core.BuildExecutableCandidate{
					{Kind: "command", Command: "tool-broken"},
					{Kind: "command", Command: "tool-good"},
				},
			},
		}}
		h := newHarness(t, kernel)
		h.open(t.TempDir())
		exec, err := h.app.resolveBuildExecutable(t.Context(), h.app.project, buildInstance{BuildInstance: core.BuildInstance{Root: "."}}, h.app.text.Build)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if filepath.Clean(exec.Executable) != filepath.Clean(good) {
			t.Fatalf("executable = %q, want fallback %q", exec.Executable, good)
		}
	})

	t.Run("old automatic toolchain falls back to command and applies runtime env before probing", func(t *testing.T) {
		bin := t.TempDir()
		oldRT := writeProbeTool(t, bin, "rt-old", "ok:Runtime 8.0.0")
		goodRT := writeProbeTool(t, bin, "rt-good", "ok:Runtime 21.0.0")
		oldTool := writeProbeTool(t, bin, "tool-old", "ok:Version 1.0.0")
		goodTool := writeProbeTool(t, bin, "tool-env", "ok:Version 2.0.0")
		t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))

		kernel := &probeVersionKernel{invocationKernel: &invocationKernel{
			testKernel: &testKernel{Client: core.NewClient()},
			invocation: core.BuildInvocation{
				MinimumVersion: "2.0.0",
				Version:        &core.BuildVersionProbe{Arguments: []string{"--require-env", "RUNTIME_OK=yes"}},
				RuntimeDependencies: []core.BuildRuntimeRequirement{{
					ID:             "jdk",
					MinimumVersion: "21",
					Version:        &core.BuildVersionProbe{Arguments: []string{"--version"}},
					Executables: []core.BuildExecutableCandidate{
						{Kind: "toolchain", ToolchainID: "dev.example:jdk"},
						{Kind: "command", Command: "rt-good"},
					},
				}},
				Executables: []core.BuildExecutableCandidate{
					{Kind: "toolchain", ToolchainID: "dev.example:tool"},
					{Kind: "command", Command: "tool-env"},
				},
			},
		}}
		h := newHarness(t, kernel)
		h.open(t.TempDir())
		h.app.toolchainResolve = func(_ context.Context, _, _, tool, _ string) (core.ToolchainSelection, error) {
			switch tool {
			case "dev.example:jdk":
				return core.ToolchainSelection{Executable: oldRT, Layer: "automatic", Version: "8.0.0"}, nil
			case "dev.example:tool":
				return core.ToolchainSelection{Executable: oldTool, Layer: "global", Version: "1.0.0"}, nil
			default:
				return core.ToolchainSelection{}, fmt.Errorf("unexpected tool %q", tool)
			}
		}
		// Inject an environment variable from a second runtime requirement after the first runtime passes, or wait:
		// Wait: since rt-good is a command, test runtime env propagation via a non-pinned toolchain replacement or second runtime!
		_ = goodRT
		kernel.invocation.RuntimeDependencies = []core.BuildRuntimeRequirement{
			{
				ID:             "jdk",
				MinimumVersion: "21",
				Version:        &core.BuildVersionProbe{Arguments: []string{"--version"}},
				Executables: []core.BuildExecutableCandidate{
					{Kind: "toolchain", ToolchainID: "dev.example:jdk-old"},
					{Kind: "toolchain", ToolchainID: "dev.example:jdk-new"},
				},
			},
		}
		h.app.toolchainResolve = func(_ context.Context, _, _, tool, _ string) (core.ToolchainSelection, error) {
			switch tool {
			case "dev.example:jdk-old":
				return core.ToolchainSelection{Executable: oldRT, Layer: "automatic", Environment: map[string]string{"RUNTIME_OK": "no"}}, nil
			case "dev.example:jdk-new":
				return core.ToolchainSelection{Executable: goodRT, Layer: "automatic", Environment: map[string]string{"RUNTIME_OK": "yes"}}, nil
			case "dev.example:tool":
				return core.ToolchainSelection{Executable: oldTool, Layer: "global"}, nil
			default:
				return core.ToolchainSelection{}, fmt.Errorf("unexpected tool %q", tool)
			}
		}
		exec, err := h.app.resolveBuildExecutable(t.Context(), h.app.project, buildInstance{BuildInstance: core.BuildInstance{Root: "."}}, h.app.text.Build)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if filepath.Clean(exec.Executable) != filepath.Clean(goodTool) {
			t.Fatalf("executable = %q, want %q", exec.Executable, goodTool)
		}
		if exec.Environment["RUNTIME_OK"] != "yes" {
			t.Fatalf("runtime environment was not applied: %+v", exec.Environment)
		}
	})

	t.Run("hanging projectFile falls back to command", func(t *testing.T) {
		workspace := t.TempDir()
		writeProbeTool(t, workspace, "wrapperw", "hang:"+filepath.Join(workspace, "hung"))
		bin := t.TempDir()
		good := writeProbeTool(t, bin, "tool-good", "ok:Version 2.0.0")
		t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))

		wrapperRel := "wrapperw"
		if runtime.GOOS == "windows" {
			wrapperRel += ".exe"
		}
		kernel := &probeVersionKernel{invocationKernel: &invocationKernel{
			testKernel: &testKernel{Client: core.NewClient()},
			invocation: core.BuildInvocation{
				MinimumVersion: "2.0.0",
				Version:        &core.BuildVersionProbe{Arguments: []string{"--version"}},
				Executables: []core.BuildExecutableCandidate{
					{Kind: "projectFile", Path: wrapperRel},
					{Kind: "command", Command: "tool-good"},
				},
			},
		}}
		h := newHarness(t, kernel)
		h.open(workspace)
		exec, err := h.app.resolveBuildExecutable(t.Context(), h.app.project, buildInstance{BuildInstance: core.BuildInstance{Root: "."}}, h.app.text.Build)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if filepath.Clean(exec.Executable) != filepath.Clean(good) {
			t.Fatalf("executable = %q, want %q", exec.Executable, good)
		}
	})
}

func TestResolveBuildExecutableDoesNotFallBackAfterTerminalCandidateFailure(t *testing.T) {
	t.Setenv(buildProbeHelperEnv, "1")
	if runtime.GOOS == "windows" {
		t.Setenv("PATHEXT", ".EXE")
	}

	t.Run("explicit setting does not fall back when version probe fails", func(t *testing.T) {
		bin := t.TempDir()
		explicit := writeProbeTool(t, t.TempDir(), "explicit-tool", "fail:broken explicit")
		writeProbeTool(t, bin, "tool-fallback", "ok:Version 2.0.0")
		t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))

		kernel := &probeVersionKernel{invocationKernel: &invocationKernel{
			testKernel: &testKernel{Client: core.NewClient()},
			invocation: core.BuildInvocation{
				MinimumVersion: "2.0.0",
				Version:        &core.BuildVersionProbe{Arguments: []string{"--version"}},
				Executables: []core.BuildExecutableCandidate{
					{Kind: "setting", Path: explicit},
					{Kind: "command", Command: "tool-fallback"},
				},
			},
		}}
		h := newHarness(t, kernel)
		h.open(t.TempDir())
		if _, err := h.app.resolveBuildExecutable(t.Context(), h.app.project, buildInstance{BuildInstance: core.BuildInstance{Root: "."}}, h.app.text.Build); err == nil {
			t.Fatal("explicit setting fell back to command after probe failure")
		}
	})

	t.Run("pinned toolchain does not fall back when too old", func(t *testing.T) {
		bin := t.TempDir()
		pinned := writeProbeTool(t, t.TempDir(), "pinned-tool", "ok:Version 1.0.0")
		writeProbeTool(t, bin, "tool-fallback", "ok:Version 2.0.0")
		t.Setenv("PATH", bin+string(filepath.ListSeparator)+os.Getenv("PATH"))

		kernel := &probeVersionKernel{invocationKernel: &invocationKernel{
			testKernel: &testKernel{Client: core.NewClient()},
			invocation: core.BuildInvocation{
				MinimumVersion: "2.0.0",
				Version:        &core.BuildVersionProbe{Arguments: []string{"--version"}},
				Executables: []core.BuildExecutableCandidate{
					{Kind: "toolchain", ToolchainID: "dev.example:tool"},
					{Kind: "command", Command: "tool-fallback"},
				},
			},
		}}
		h := newHarness(t, kernel)
		h.open(t.TempDir())
		h.app.toolchainResolve = func(context.Context, string, string, string, string) (core.ToolchainSelection, error) {
			return core.ToolchainSelection{Executable: pinned, Layer: "pinned", Version: "1.0.0"}, nil
		}
		_, err := h.app.resolveBuildExecutable(t.Context(), h.app.project, buildInstance{BuildInstance: core.BuildInstance{Root: "."}}, i18n.BuildMessages{
			ExecutableMissing: "missing",
			VersionTooOld:     func(want, got string) string { return "too old: " + got + " < " + want },
		})
		if err == nil || !strings.Contains(err.Error(), "too old") {
			t.Fatalf("err = %v, want too-old error without fallback", err)
		}
	})
}
