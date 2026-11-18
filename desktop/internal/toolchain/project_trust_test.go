package toolchain

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func syntheticProjectEnvManifest(t *testing.T) json.RawMessage {
	t.Helper()
	manifest := map[string]any{
		"schemaVersion":    0,
		"id":               "dev.lithe.test.projectenv",
		"displayName":      "Synthetic Project Environment",
		"version":          "1.0.0",
		"pluginAPIVersion": 0,
		"requires":         map[string]any{"toolDefinitions": 0},
		"vendor": map[string]any{
			"id":                   "dev.lithe.test",
			"displayName":          "Synthetic Test Vendor",
			"signatureRequirement": "publisherPackage",
		},
		"permissions": []any{},
		"toolDefinitions": []any{
			map[string]any{
				"id":          "dev.lithe.test.projectenv:interp",
				"displayName": "Synthetic Interpreter",
				"executableLayouts": []any{
					map[string]any{"path": "bin/interp", "platforms": []string{"macos", "linux"}},
					map[string]any{"path": "Scripts/interp.exe", "platforms": []string{"windows"}},
				},
				"executables": []any{
					map[string]any{
						"id":        "pinned",
						"kind":      "setting",
						"settingID": "executable",
						"layer":     "project",
					},
					map[string]any{
						"id":          "project-venv-unix",
						"kind":        "projectFile",
						"projectKind": "environment",
						"home":        ".venv",
						"path":        ".venv/bin/interp",
						"requires":    []string{".venv/env.cfg"},
						"platforms":   []string{"macos", "linux"},
					},
					map[string]any{
						"id":          "project-venv-win",
						"kind":        "projectFile",
						"projectKind": "environment",
						"home":        ".venv",
						"path":        ".venv/Scripts/interp.exe",
						"requires":    []string{".venv/env.cfg"},
						"platforms":   []string{"windows"},
					},
					map[string]any{
						"id":        "global-default",
						"kind":      "setting",
						"settingID": "executable",
						"layer":     "global",
					},
					map[string]any{
						"id":      "shell-cmd",
						"kind":    "command",
						"command": "synthetic-interp",
					},
					map[string]any{
						"id":    "detected",
						"kind":  "toolchain",
						"scope": "installed",
					},
				},
				"version": map[string]any{
					"arguments": []string{"--version"},
					"pattern":   `SyntheticInterp (\d+(?:\.\d+)*)`,
				},
				"commands": []string{"synthetic-interp"},
				"exports": []any{
					map[string]any{"name": "SYNTHETIC_ENV_HOME", "value": "${home}"},
					map[string]any{"name": "SYNTHETIC_INTERP", "value": "${executable}"},
				},
				"pathPrepend": []string{"${home}/bin", "${home}/Scripts"},
				"launch":      []string{"${executable}", "${arguments}"},
			},
		},
	}
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func setupSyntheticVenv(t *testing.T, anchor, externalBase string) (venvHome, venvExe, prependDir string) {
	t.Helper()
	venvHome = filepath.Join(anchor, ".venv")
	if err := os.MkdirAll(venvHome, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(venvHome, "env.cfg"), []byte("home = external\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS == "windows" {
		prependDir = filepath.Join(venvHome, "Scripts")
		venvExe = filepath.Join(prependDir, "interp.exe")
		writeExecutable(t, venvExe)
		return venvHome, venvExe, prependDir
	}
	baseExe := filepath.Join(externalBase, "bin", "interp3.12")
	writeExecutable(t, baseExe)
	prependDir = filepath.Join(venvHome, "bin")
	if err := os.MkdirAll(prependDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Create a two-hop symlink chain (.venv/bin/interp -> interp3 -> externalBase/bin/interp3.12)
	// mirroring real macOS/Homebrew/uv virtual environments.
	hop := filepath.Join(prependDir, "interp3")
	if err := os.Symlink(baseExe, hop); err != nil {
		t.Fatal(err)
	}
	venvExe = filepath.Join(prependDir, "interp")
	if err := os.Symlink("interp3", venvExe); err != nil {
		t.Fatal(err)
	}
	return venvHome, venvExe, prependDir
}

type probeRecorder struct {
	mu      sync.Mutex
	calls   []string
	outputs map[string]string
}

func (r *probeRecorder) probe(_ context.Context, executable string, _ []string) (string, int, error) {
	cleaned := filepath.Clean(executable)
	r.mu.Lock()
	r.calls = append(r.calls, cleaned)
	out, ok := r.outputs[cleaned]
	r.mu.Unlock()
	if !ok {
		return "", 1, nil
	}
	return out, 0, nil
}

func (r *probeRecorder) reset() {
	r.mu.Lock()
	r.calls = nil
	r.mu.Unlock()
}

func (r *probeRecorder) snapshot() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.calls...)
}

func TestUntrustedProjectEnvironmentNeverProbesWorkspaceExecutables(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	kernel := core.NewClient()
	settingsDir := filepath.Join(t.TempDir(), "app-settings")
	root := canonical(t, t.TempDir())
	home := canonical(t, t.TempDir())
	externalBase := canonical(t, t.TempDir())

	venvHome, venvExe, _ := setupSyntheticVenv(t, root, externalBase)
	// Also place a sneaky workspace executable on Lookup (simulating a modified PATH)
	// to verify probeAll blocks workspace code from every candidate channel until trusted.
	sneakyExe := filepath.Join(root, "sneaky", "bin", "interp")
	if runtime.GOOS == "windows" {
		sneakyExe = filepath.Join(root, "sneaky", "Scripts", "interp.exe")
	}
	writeExecutable(t, sneakyExe)

	recorder := &probeRecorder{
		outputs: map[string]string{
			filepath.Clean(venvExe):   "SyntheticInterp 3.12.4\n",
			filepath.Clean(sneakyExe): "SyntheticInterp 9.9.9\n",
		},
	}
	options := Options{
		GlobalRoot:  settingsDir,
		Platform:    PlatformName(runtime.GOOS),
		Home:        home,
		Environment: map[string]string{},
		Probe:       recorder.probe,
		Lookup: func(command string) (string, error) {
			if command == "synthetic-interp" {
				return sneakyExe, nil
			}
			return "", errors.New("not found")
		},
	}
	manifests := []json.RawMessage{syntheticProjectEnvManifest(t)}
	const toolID = "dev.lithe.test.projectenv:interp"

	snapshot, err := Load(ctx, kernel, root, ".", manifests, options)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.ProjectCodeAllowed {
		t.Fatal("fresh workspace was trusted without explicit local user action")
	}
	if calls := recorder.snapshot(); len(calls) != 0 {
		t.Fatalf("untrusted workspace ran version probes on %v, want zero probes", calls)
	}
	if len(snapshot.Tools) != 1 {
		t.Fatalf("tools = %+v", snapshot.Tools)
	}
	tool := snapshot.Tools[0]
	if tool.Effective != nil {
		t.Fatalf("untrusted workspace resolved %+v, want nil", tool.Effective)
	}
	if len(tool.Project) != 1 || tool.Project[0].Reason != "projectCodeRequiresAction" || tool.Project[0].Executable != "" || filepath.Clean(tool.Project[0].Home) != filepath.Clean(venvHome) {
		t.Fatalf("project candidates = %+v, want blocked .venv without executable probe target", tool.Project)
	}

	_, err = Resolve(ctx, kernel, root, ".", toolID, "", nil, manifests, options)
	var unavailable *UnavailableError
	if !errors.As(err, &unavailable) || unavailable.Code != "projectCodeRequiresAction" {
		t.Fatalf("Resolve error = %v, want projectCodeRequiresAction", err)
	}
	if calls := recorder.snapshot(); len(calls) != 0 {
		t.Fatalf("untrusted Resolve ran version probes on %v", calls)
	}
	if _, statErr := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("untrusted load/resolve wrote workspace .lithe: %v", statErr)
	}
	if _, statErr := os.Stat(settingsDir); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("reading untrusted state created settings directory: %v", statErr)
	}
}

func TestTrustedWorkspacePersistsInLocalSettingsOnlyAndResolvesSymlinkedVenv(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	kernel := core.NewClient()
	settingsDir := filepath.Join(t.TempDir(), "app-settings")
	root := canonical(t, t.TempDir())
	otherRoot := canonical(t, t.TempDir())
	home := canonical(t, t.TempDir())
	externalBase := canonical(t, t.TempDir())

	venvHome, venvExe, prependDir := setupSyntheticVenv(t, root, externalBase)
	_, otherExe, _ := setupSyntheticVenv(t, otherRoot, externalBase)

	recorder := &probeRecorder{
		outputs: map[string]string{
			filepath.Clean(venvExe):  "SyntheticInterp 3.12.4\n",
			filepath.Clean(otherExe): "SyntheticInterp 3.11.0\n",
		},
	}
	options := Options{
		GlobalRoot:  settingsDir,
		Platform:    PlatformName(runtime.GOOS),
		Home:        home,
		Environment: map[string]string{},
		Probe:       recorder.probe,
		Lookup:      func(string) (string, error) { return "", errors.New("not found") },
	}
	manifests := []json.RawMessage{syntheticProjectEnvManifest(t)}
	const toolID = "dev.lithe.test.projectenv:interp"

	initial, err := Load(ctx, kernel, root, ".", manifests, options)
	if err != nil {
		t.Fatal(err)
	}
	// Revoking trust when already untrusted is a no-op and creates no file.
	if changed, err := initial.SaveWorkspaceTrust(ctx, kernel, false); err != nil || changed {
		t.Fatalf("no-op revoke = %v, %v", changed, err)
	}
	if _, statErr := os.Stat(filepath.Join(settingsDir, "toolchains", "global.json")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("no-op revoke created global.json: %v", statErr)
	}

	// Grant trust for root: stored in settingsDir/toolchains/global.json, NEVER in root/.lithe.
	if changed, err := initial.SaveWorkspaceTrust(ctx, kernel, true); err != nil || !changed {
		t.Fatalf("grant workspace trust = %v, %v", changed, err)
	}
	if _, statErr := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("granting workspace trust wrote inside workspace .lithe: %v", statErr)
	}
	storedBytes, err := os.ReadFile(filepath.Join(settingsDir, "toolchains", "global.json"))
	if err != nil {
		t.Fatalf("expected local trust file in settingsDir: %v", err)
	}
	if !strings.Contains(string(storedBytes), "trustedWorkspaces") {
		t.Fatalf("global.json missing trustedWorkspaces: %s", storedBytes)
	}

	recorder.reset()
	trustedSnapshot, err := Load(ctx, kernel, root, ".", manifests, options)
	if err != nil {
		t.Fatal(err)
	}
	if !trustedSnapshot.ProjectCodeAllowed {
		t.Fatal("reloaded snapshot did not reflect local workspace trust")
	}
	calls := recorder.snapshot()
	if len(calls) != 1 || filepath.Clean(calls[0]) != filepath.Clean(venvExe) {
		t.Fatalf("probed executables = %v, want literal [%s]", calls, filepath.Clean(venvExe))
	}
	tool := trustedSnapshot.Tools[0]
	if tool.Effective == nil || filepath.Clean(tool.Effective.Executable) != filepath.Clean(venvExe) {
		t.Fatalf("effective selection = %+v, want literal venv executable %q", tool.Effective, venvExe)
	}
	if tool.Effective.Version != "3.12.4" || tool.Effective.Layer != "project" || !tool.Effective.ProjectCode {
		t.Fatalf("effective metadata = %+v", tool.Effective)
	}
	if filepath.Clean(tool.Effective.Environment["SYNTHETIC_ENV_HOME"]) != filepath.Clean(venvHome) ||
		filepath.Clean(tool.Effective.Environment["SYNTHETIC_INTERP"]) != filepath.Clean(venvExe) {
		t.Fatalf("effective exports = %+v", tool.Effective.Environment)
	}
	if len(tool.Effective.PathPrepend) != 1 || filepath.Clean(tool.Effective.PathPrepend[0]) != filepath.Clean(prependDir) {
		t.Fatalf("effective pathPrepend = %+v, want [%s]", tool.Effective.PathPrepend, prependDir)
	}
	if filepath.Clean(tool.AutomaticHome) != filepath.Clean(venvHome) {
		t.Fatalf("automaticHome = %q, want %q", tool.AutomaticHome, venvHome)
	}

	selected, err := Resolve(ctx, kernel, root, ".", toolID, "", nil, manifests, options)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Clean(selected.Executable) != filepath.Clean(venvExe) {
		t.Fatalf("Resolve executable = %q, want literal %q", selected.Executable, venvExe)
	}

	// Another workspace on the same machine remains untrusted and unprobed.
	recorder.reset()
	otherSnapshot, err := Load(ctx, kernel, otherRoot, ".", manifests, options)
	if err != nil {
		t.Fatal(err)
	}
	if otherSnapshot.ProjectCodeAllowed || len(recorder.snapshot()) != 0 {
		t.Fatalf("trust leaked to another workspace: allowed=%v probes=%v", otherSnapshot.ProjectCodeAllowed, recorder.snapshot())
	}

	// Revoking trust immediately stops probing and selecting the workspace environment.
	if changed, err := trustedSnapshot.SaveWorkspaceTrust(ctx, kernel, false); err != nil || !changed {
		t.Fatalf("revoke workspace trust = %v, %v", changed, err)
	}
	recorder.reset()
	revokedSnapshot, err := Load(ctx, kernel, root, ".", manifests, options)
	if err != nil {
		t.Fatal(err)
	}
	if revokedSnapshot.ProjectCodeAllowed || revokedSnapshot.Tools[0].Effective != nil || len(recorder.snapshot()) != 0 {
		t.Fatalf("revoked workspace still probed or resolved: allowed=%v effective=%+v probes=%v",
			revokedSnapshot.ProjectCodeAllowed, revokedSnapshot.Tools[0].Effective, recorder.snapshot())
	}
	if _, statErr := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("revoking workspace trust wrote inside workspace .lithe: %v", statErr)
	}
}

func TestTrustedWorkspaceResolvesSubdirectoryEnvironmentAndRejectsEscapingDirectories(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	kernel := core.NewClient()
	settingsDir := filepath.Join(t.TempDir(), "app-settings")
	root := canonical(t, t.TempDir())
	home := canonical(t, t.TempDir())
	externalBase := canonical(t, t.TempDir())

	subdir := filepath.Join(root, "services", "worker")
	if err := os.MkdirAll(subdir, 0o755); err != nil {
		t.Fatal(err)
	}
	subVenvHome, subVenvExe, _ := setupSyntheticVenv(t, subdir, externalBase)

	recorder := &probeRecorder{
		outputs: map[string]string{
			filepath.Clean(subVenvExe): "SyntheticInterp 3.13.1\n",
		},
	}
	options := Options{
		GlobalRoot:  settingsDir,
		Platform:    PlatformName(runtime.GOOS),
		Home:        home,
		Environment: map[string]string{},
		Probe:       recorder.probe,
		Lookup:      func(string) (string, error) { return "", errors.New("not found") },
	}
	manifests := []json.RawMessage{syntheticProjectEnvManifest(t)}
	const toolID = "dev.lithe.test.projectenv:interp"

	initial, err := Load(ctx, kernel, root, "services/worker", manifests, options)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := initial.SaveWorkspaceTrust(ctx, kernel, true); err != nil {
		t.Fatal(err)
	}

	selected, err := Resolve(ctx, kernel, root, "services/worker", toolID, "", nil, manifests, options)
	if err != nil {
		t.Fatalf("subdirectory Resolve failed: %v", err)
	}
	if filepath.Clean(selected.Executable) != filepath.Clean(subVenvExe) || selected.Home == nil || filepath.Clean(*selected.Home) != filepath.Clean(subVenvHome) {
		t.Fatalf("subdirectory selection = %+v, want %q in %q", selected, subVenvExe, subVenvHome)
	}

	// Replace root/.venv with a directory link escaping outside the workspace:
	// Core must reject it as unsafePath BEFORE any probe is executed.
	outsideEnv := canonical(t, t.TempDir())
	_, escapedTargetExe, _ := setupSyntheticVenv(t, outsideEnv, externalBase)
	linkToolchainDirectory(t, filepath.Join(outsideEnv, ".venv"), filepath.Join(root, ".venv"))
	escapedLexicalExe := filepath.Join(root, ".venv", "bin", "interp")
	if runtime.GOOS == "windows" {
		escapedLexicalExe = filepath.Join(root, ".venv", "Scripts", "interp.exe")
	}
	recorder.outputs[filepath.Clean(escapedLexicalExe)] = "SyntheticInterp 9.9.9\n"
	recorder.outputs[filepath.Clean(escapedTargetExe)] = "SyntheticInterp 9.9.9\n"
	recorder.reset()

	_, err = Resolve(ctx, kernel, root, ".", toolID, "", nil, manifests, options)
	var unavailable *UnavailableError
	if !errors.As(err, &unavailable) || unavailable.Code != "unsafePath" {
		t.Fatalf("escaping .venv error = %v, want unsafePath", err)
	}
	if calls := recorder.snapshot(); len(calls) != 0 {
		t.Fatalf("escaping directory symlink was probed: %v", calls)
	}
}

func TestSaveWorkspaceTrustRejectsReplacedWorkspaceDirectory(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	kernel := core.NewClient()
	settingsDir := filepath.Join(t.TempDir(), "app-settings")
	parent := canonical(t, t.TempDir())
	workspaceDir := filepath.Join(parent, "project")
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	options := Options{
		GlobalRoot:  settingsDir,
		Platform:    PlatformName(runtime.GOOS),
		Home:        t.TempDir(),
		Environment: map[string]string{},
		Lookup:      func(string) (string, error) { return "", errors.New("not found") },
	}
	snapshot, err := Load(ctx, kernel, workspaceDir, ".", nil, options)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(workspaceDir, workspaceDir+"-old"); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := snapshot.SaveWorkspaceTrust(ctx, kernel, true); !errors.Is(err, ErrPinConflict) {
		t.Fatalf("replaced workspace error = %v, want ErrPinConflict", err)
	}
	if _, statErr := os.Stat(filepath.Join(settingsDir, "toolchains", "global.json")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("replaced workspace wrote global.json: %v", statErr)
	}
}
