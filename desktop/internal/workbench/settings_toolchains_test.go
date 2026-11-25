package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginstate"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

// Discovery is inert here: the test owns source failures, never the user's SDKs.

func TestGlobalToolchainsRetainValidPluginAndReportUnreadableOne(t *testing.T) {
	preferences, root := store.At(t.TempDir()), t.TempDir()
	service, err := pluginservice.Open(core.NewClient(), preferences, root)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"dev.example.catalog-readable", "dev.example.catalog-unreadable"} {
		staging, err := pluginpkg.NewStaging(root)
		if err != nil {
			t.Fatal(err)
		}
		fixture, err := os.ReadFile("../toolchain/testdata/compiler.plugin.json")
		if err != nil {
			t.Fatal(err)
		}
		var document map[string]any
		if err := json.Unmarshal(fixture, &document); err != nil {
			t.Fatal(err)
		}
		document["id"] = id
		definition := document["toolDefinitions"].([]any)[0].(map[string]any)
		definition["id"] = id + ":compiler"
		manifest, err := json.Marshal(document)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(staging, pluginpkg.ManifestFile), manifest, 0600); err != nil {
			t.Fatal(err)
		}
		installed, err := pluginpkg.Install(root, id, "1.0.0", staging)
		if err != nil {
			t.Fatal(err)
		}
		if err := pluginstate.New(preferences).SetEnabled(id, true); err != nil {
			t.Fatal(err)
		}
		if id == "dev.example.catalog-unreadable" {
			if err := os.Remove(filepath.Join(installed.Path, pluginpkg.ManifestFile)); err != nil {
				t.Fatal(err)
			}
		}
	}
	app := &App{kernel: &testKernel{Client: core.NewClient()}, store: preferences, plugins: service}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	log := &treeRecordingLog{}
	app.logSink = log
	snapshot, err := (settingsToolchains{app: app}).LoadScope(ctx, "global")
	if err != nil {
		t.Fatalf("global catalog should retain valid tools: %v", err)
	}
	if len(snapshot.Tools) == 0 || !snapshot.DiscoveryIncomplete {
		t.Fatalf("catalog lost tools or partial warning: %+v", snapshot)
	}
	log.mu.Lock()
	if len(log.events) != 1 || log.events[0].Fields["operation"] != "toolchain_settings_discovery" {
		t.Errorf("partial global catalog recorded events %+v", log.events)
	}
	log.mu.Unlock()
	if _, err := os.Stat(filepath.Join(preferences.Dir(), "toolchains", "global.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a failed read wrote a global catalog: %v", err)
	}
}

// A readable plugin remains in project settings when another plugin's
// manifest disappeared. The partial failure must be logged once at the
// boundary instead of silently turning into a complete-looking tool list.
func TestProjectToolchainPartialManifestReadReportsDegradation(t *testing.T) {
	preferences, pluginRoot, projectRoot := store.At(t.TempDir()), t.TempDir(), t.TempDir()
	service, err := pluginservice.Open(core.NewClient(), preferences, pluginRoot)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"dev.example.catalog-readable", "dev.example.catalog-unreadable"} {
		staging, err := pluginpkg.NewStaging(pluginRoot)
		if err != nil {
			t.Fatal(err)
		}
		fixture, err := os.ReadFile("../toolchain/testdata/compiler.plugin.json")
		if err != nil {
			t.Fatal(err)
		}
		var document map[string]any
		if err := json.Unmarshal(fixture, &document); err != nil {
			t.Fatal(err)
		}
		document["id"] = id
		definition := document["toolDefinitions"].([]any)[0].(map[string]any)
		definition["id"] = id + ":compiler"
		manifest, err := json.Marshal(document)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(staging, pluginpkg.ManifestFile), manifest, 0o600); err != nil {
			t.Fatal(err)
		}
		installed, err := pluginpkg.Install(pluginRoot, id, "1.0.0", staging)
		if err != nil {
			t.Fatal(err)
		}
		if err := pluginstate.New(preferences).SetEnabled(id, true); err != nil {
			t.Fatal(err)
		}
		if id == "dev.example.catalog-unreadable" {
			if err := os.Remove(filepath.Join(installed.Path, pluginpkg.ManifestFile)); err != nil {
				t.Fatal(err)
			}
		}
	}
	log := &treeRecordingLog{}
	app := &App{kernel: &testKernel{Client: core.NewClient()}, store: preferences, plugins: service, logSink: log}
	app.toolchainRoot.Store(&projectRoot)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	snapshot, err := (settingsToolchains{app: app}).Load(ctx)
	if err != nil {
		t.Fatalf("readable manifests should still load project settings: %v", err)
	}
	if len(snapshot.Tools) == 0 || !snapshot.DiscoveryIncomplete {
		t.Fatal("the readable plugin was lost or incomplete status was not reported")
	}
	log.mu.Lock()
	defer log.mu.Unlock()
	if len(log.events) != 1 || log.events[0].Fields["operation"] != "toolchain_settings_discovery" {
		t.Fatalf("missing one degradation event: %+v", log.events)
	}
}

func TestToolchainSettingsRejectSaveForAnotherOrClosedProject(t *testing.T) {
	for _, closed := range []bool{false, true} {
		name := "another-project"
		if closed {
			name = "closed-project"
		}
		t.Run(name, func(t *testing.T) {
			original, current := t.TempDir(), t.TempDir()
			app := &App{kernel: &testKernel{Client: core.NewClient()}}
			if !closed {
				app.toolchainRoot.Store(&current)
			}
			snapshot := toolchain.Snapshot{Root: original, Directory: "."}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, err := (settingsToolchains{app: app}).Save(ctx, snapshot, []toolchain.Edit{{Tool: "dev.example:compiler"}})
			if !errors.Is(err, toolchain.ErrPinConflict) {
				t.Errorf("save error = %v, want a stale-source conflict", err)
			}
			for _, root := range []string{original, current} {
				if _, err := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(err, os.ErrNotExist) {
					t.Errorf("stale draft created workspace state: %v", err)
				}
			}
		})
	}
}

type settingsScopeKernel struct {
	*testKernel
	onEdit func()
}

func (k *settingsScopeKernel) EditToolchainPinSources(ctx context.Context, request core.ToolchainPinSourcesRequest) (core.ToolchainPinSourcesEdit, error) {
	k.onEdit()
	return k.Client.EditToolchainPinSources(ctx, request)
}

// Switching projects after confirmation cannot retarget either publication or
// the reread. The result must describe the source the user actually saved.
func TestToolchainSettingsSaveRereadsItsCapturedProject(t *testing.T) {
	original, current := t.TempDir(), t.TempDir()
	kernel := &settingsScopeKernel{testKernel: &testKernel{Client: core.NewClient()}}
	app := &App{kernel: kernel, store: store.At(t.TempDir())}
	app.toolchainRoot.Store(&original)
	kernel.onEdit = func() { app.toolchainRoot.Store(&current) }
	plugins, err := pluginservice.Open(core.NewClient(), store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	app.plugins = plugins
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	snapshot, err := (settingsToolchains{app: app}).Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := (settingsToolchains{app: app}).Save(ctx, snapshot, []toolchain.Edit{{Tool: "dev.example:compiler", Pin: &core.ToolchainPin{Home: "/fixture/tool", Version: "1.0", Provider: "host:system"}}})
	if err != nil {
		t.Fatal(err)
	}
	if updated.Root != snapshot.Root {
		t.Errorf("saved source = %q, want captured source %q", updated.Root, snapshot.Root)
	}
	data, err := os.ReadFile(filepath.Join(original, ".lithe", "toolchains", "local.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(updated.Baseline, data) {
		t.Error("save returned another project's baseline")
	}
	if _, err := os.Stat(filepath.Join(current, ".lithe")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("save created state in the newly selected project: %v", err)
	}
}

func TestToolchainSettingsRejectsReplacedWorkspaceAtTheSamePath(t *testing.T) {
	testToolchainSettingsWorkspaceReplacement(t, false)
}

func TestToolchainSettingsRejectsWorkspaceReplacementDuringCoreEdit(t *testing.T) {
	testToolchainSettingsWorkspaceReplacement(t, true)
}

func testToolchainSettingsWorkspaceReplacement(t *testing.T, duringEdit bool) {
	t.Helper()
	original := filepath.Join(t.TempDir(), "workspace")
	if err := os.Mkdir(original, 0o700); err != nil {
		t.Fatal(err)
	}
	kernel := &settingsScopeKernel{testKernel: &testKernel{Client: core.NewClient()}, onEdit: func() {}}
	app := &App{kernel: kernel, store: store.At(t.TempDir())}
	app.toolchainRoot.Store(&original)
	plugins, err := pluginservice.Open(core.NewClient(), store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	app.plugins = plugins
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	snapshot, err := (settingsToolchains{app: app}).Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	retired := original + "-retired"
	replace := func() {
		if err := os.Rename(original, retired); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(original, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if duringEdit {
		kernel.onEdit = replace
	} else {
		replace()
	}
	_, err = (settingsToolchains{app: app}).Save(ctx, snapshot, []toolchain.Edit{{Tool: "dev.example:compiler"}})
	if !errors.Is(err, toolchain.ErrPinConflict) {
		t.Fatalf("replaced workspace save = %v, want conflict", err)
	}
	for _, root := range []string{original, retired} {
		if _, err := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("replaced workspace was written: %s: %v", root, err)
		}
	}
}

type pinReadbackFailureKernel struct {
	*testKernel
	failReadback bool
}

func (k *pinReadbackFailureKernel) EditToolchainPinSources(ctx context.Context, request core.ToolchainPinSourcesRequest) (core.ToolchainPinSourcesEdit, error) {
	edit, err := k.Client.EditToolchainPinSources(ctx, request)
	if err == nil {
		k.failReadback = true
	}
	return edit, err
}

func (k *pinReadbackFailureKernel) DecodeToolchainPinDocument(ctx context.Context, document *string) (json.RawMessage, error) {
	if k.failReadback {
		return nil, errors.New("fixture source became unreadable after publication")
	}
	return k.Client.DecodeToolchainPinDocument(ctx, document)
}

func TestToolchainSettingsReadbackFailureReportsCommittedSource(t *testing.T) {
	root := t.TempDir()
	kernel := &pinReadbackFailureKernel{testKernel: &testKernel{Client: core.NewClient()}}
	app := &App{kernel: kernel, store: store.At(t.TempDir())}
	app.toolchainRoot.Store(&root)
	plugins, err := pluginservice.Open(core.NewClient(), store.At(t.TempDir()), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	app.plugins = plugins
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	adapter := settingsToolchains{app: app}
	snapshot, err := adapter.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, err = adapter.Save(ctx, snapshot, []toolchain.Edit{{Tool: "dev.example:compiler", Pin: &core.ToolchainPin{Home: "/fixture/tool", Version: "1.0", Provider: "host:system"}}})
	if !errors.Is(err, toolchain.ErrPinCommitted) {
		t.Fatalf("readback failure did not invalidate the baseline: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(root, ".lithe", "toolchains", "local.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte("dev.example:compiler")) {
		t.Fatalf("test did not exercise a committed pin: %s", data)
	}
}

const syntheticWorkbenchInterpMarkerEnv = "LITHE_TEST_SYNTHETIC_INTERP_MARKER"

func TestMain(m *testing.M) {
	// Core names the running executable as the AskPass helper of an interactive Git command,
	// so a test that lets Git ask starts this binary in helper mode; it must not run the tests.
	if prompt, helper := core.GitAskPassRequest(os.Args); helper {
		os.Exit(core.GitAskPass(prompt))
	}
	if maybeRunBuildProbeHelper() {
		return
	}
	if marker := os.Getenv(syntheticWorkbenchInterpMarkerEnv); marker != "" && len(os.Args) == 2 && os.Args[1] == "--version" {
		_ = os.WriteFile(marker, []byte("probed\n"), 0o600)
		fmt.Println("SyntheticInterp 3.12.4")
		os.Exit(0)
	}
	os.Exit(m.Run())
}

type actionFieldLog struct {
	logwindow.Source
	mu      sync.Mutex
	actions []string
	failed  []string
}

func (l *actionFieldLog) Emit(_ core.LogLevel, event, _ string, fields map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	switch event {
	case "app.action.performed":
		if action, ok := fields["action"].(string); ok {
			l.actions = append(l.actions, action)
		}
	case "app.notification.operation_failed":
		if op, ok := fields["operation"].(string); ok {
			l.failed = append(l.failed, op)
		}
	}
}

func TestWorkbenchToolchainTrustPersistsLocallyLogsActionAndEnablesRuntimeResolution(t *testing.T) {
	preferences := store.At(t.TempDir())
	pluginsRoot := t.TempDir()
	workspaceRaw := t.TempDir()
	workspaceRoot, err := filepath.EvalSymlinks(workspaceRaw)
	if err != nil {
		t.Fatal(err)
	}
	externalRaw := t.TempDir()
	externalBase, err := filepath.EvalSymlinks(externalRaw)
	if err != nil {
		t.Fatal(err)
	}
	markerPath := filepath.Join(t.TempDir(), "probe-ran.marker")

	const pluginID = "dev.lithe.test.projectenv"
	const toolID = pluginID + ":interp"
	manifestDoc := map[string]any{
		"schemaVersion":    0,
		"id":               pluginID,
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
				"id":          toolID,
				"displayName": "Synthetic Interpreter",
				"executableLayouts": []any{
					map[string]any{"path": "bin/interp", "platforms": []string{"macos", "linux"}},
					map[string]any{"path": "Scripts/interp.exe", "platforms": []string{"windows"}},
				},
				"executables": []any{
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
						"id":      "shell-cmd",
						"kind":    "command",
						"command": "nonexistent-synthetic-interp",
					},
				},
				"version": map[string]any{
					"arguments": []string{"--version"},
					"pattern":   `SyntheticInterp (\d+(?:\.\d+)*)`,
				},
				"commands":    []string{"nonexistent-synthetic-interp"},
				"exports":     []any{map[string]any{"name": "SYNTHETIC_ENV_HOME", "value": "${home}"}},
				"pathPrepend": []string{"${home}/bin", "${home}/Scripts"},
				"launch":      []string{"${executable}", "${arguments}"},
			},
		},
	}
	manifestBytes, err := json.Marshal(manifestDoc)
	if err != nil {
		t.Fatal(err)
	}

	service, err := pluginservice.Open(core.NewClient(), preferences, pluginsRoot)
	if err != nil {
		t.Fatal(err)
	}
	staging, err := pluginpkg.NewStaging(pluginsRoot)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(staging, pluginpkg.ManifestFile), manifestBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := pluginpkg.Install(pluginsRoot, pluginID, "1.0.0", staging); err != nil {
		t.Fatal(err)
	}
	if err := pluginstate.New(preferences).SetEnabled(pluginID, true); err != nil {
		t.Fatal(err)
	}

	venvHome := filepath.Join(workspaceRoot, ".venv")
	if err := os.MkdirAll(venvHome, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(venvHome, "env.cfg"), []byte("home = external\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var venvExe string
	if runtime.GOOS == "windows" {
		t.Setenv(syntheticWorkbenchInterpMarkerEnv, markerPath)
		scriptsDir := filepath.Join(venvHome, "Scripts")
		if err := os.MkdirAll(scriptsDir, 0o755); err != nil {
			t.Fatal(err)
		}
		venvExe = filepath.Join(scriptsDir, "interp.exe")
		copyTestBinary(t, venvExe)
	} else {
		baseBin := filepath.Join(externalBase, "bin")
		if err := os.MkdirAll(baseBin, 0o755); err != nil {
			t.Fatal(err)
		}
		baseExe := filepath.Join(baseBin, "interp3.12")
		script := fmt.Sprintf("#!/bin/sh\nprintf 'probed\\n' > %q\nprintf 'SyntheticInterp 3.12.4\\n'\n", markerPath)
		if err := os.WriteFile(baseExe, []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
		venvBin := filepath.Join(venvHome, "bin")
		if err := os.MkdirAll(venvBin, 0o755); err != nil {
			t.Fatal(err)
		}
		venvExe = filepath.Join(venvBin, "interp")
		if err := os.Symlink(baseExe, venvExe); err != nil {
			t.Fatal(err)
		}
	}

	logs := &actionFieldLog{}
	app := &App{kernel: &testKernel{Client: core.NewClient()}, store: preferences, plugins: service, logSink: logs}
	app.toolchainRoot.Store(&workspaceRoot)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	adapter := settingsToolchains{app: app}

	// 1. Untrusted load & runtime resolution: NEVER executes the probe, returns projectCodeRequiresAction.
	initial, err := adapter.Load(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if initial.ProjectCodeAllowed {
		t.Fatal("fresh project was trusted without user action")
	}
	if _, err := app.resolveToolchainSelection(ctx, workspaceRoot, ".", toolID, ""); err == nil {
		t.Fatal("untrusted runtime resolution succeeded unexpectedly")
	} else {
		var unavailable *toolchain.UnavailableError
		if !errors.As(err, &unavailable) || unavailable.Code != "projectCodeRequiresAction" {
			t.Fatalf("untrusted resolveToolchainSelection = %v, want projectCodeRequiresAction", err)
		}
	}
	if _, statErr := os.Stat(markerPath); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("untrusted load/resolve executed workspace probe: %v", statErr)
	}

	// 2. Grant trust: logs action, stores only in preferences.Dir()/toolchains/global.json, reloads & resolves.
	trusted, err := adapter.SetWorkspaceTrust(ctx, initial, true)
	if err != nil {
		t.Fatal(err)
	}
	if !trusted.ProjectCodeAllowed || len(trusted.Tools) != 1 || trusted.Tools[0].Effective == nil {
		t.Fatalf("trusted snapshot = %+v", trusted)
	}
	if filepath.Clean(trusted.Tools[0].AutomaticHome) != filepath.Clean(venvHome) ||
		filepath.Clean(trusted.Tools[0].Effective.Executable) != filepath.Clean(venvExe) {
		t.Fatalf("trusted snapshot tool = %+v", trusted.Tools[0])
	}
	if _, statErr := os.Stat(markerPath); statErr != nil {
		t.Fatalf("trusted load did not probe .venv interpreter: %v", statErr)
	}
	if _, statErr := os.Stat(filepath.Join(workspaceRoot, ".lithe")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("workspace trust wrote inside workspace .lithe: %v", statErr)
	}
	if _, statErr := os.Stat(filepath.Join(preferences.Dir(), "toolchains", "global.json")); statErr != nil {
		t.Fatalf("workspace trust missing from local store: %v", statErr)
	}

	// Build/Run/Debug shared resolver reads the same local trust and selects .venv.
	selected, err := app.resolveToolchainSelection(ctx, workspaceRoot, ".", toolID, "")
	if err != nil {
		t.Fatalf("trusted resolveToolchainSelection failed: %v", err)
	}
	if filepath.Clean(selected.Executable) != filepath.Clean(venvExe) || selected.Version != "3.12.4" {
		t.Fatalf("trusted selection = %+v, want %q 3.12.4", selected, venvExe)
	}

	// 3. Revoke trust: logs action, removes probes on reload, blocks runtime resolution again.
	if err := os.Remove(markerPath); err != nil {
		t.Fatal(err)
	}
	revoked, err := adapter.SetWorkspaceTrust(ctx, trusted, false)
	if err != nil {
		t.Fatal(err)
	}
	if revoked.ProjectCodeAllowed || revoked.Tools[0].Effective != nil {
		t.Fatalf("revoked snapshot = %+v", revoked)
	}
	if _, err := app.resolveToolchainSelection(ctx, workspaceRoot, ".", toolID, ""); err == nil {
		t.Fatal("revoked workspace still resolved project environment")
	}
	if _, statErr := os.Stat(markerPath); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("revoked workspace executed probe: %v", statErr)
	}

	logs.mu.Lock()
	gotActions := append([]string(nil), logs.actions...)
	gotFailed := append([]string(nil), logs.failed...)
	logs.mu.Unlock()
	wantActions := []string{"toolchain.workspaceTrust.grant", "toolchain.workspaceTrust.revoke"}
	if len(gotActions) != len(wantActions) || gotActions[0] != wantActions[0] || gotActions[1] != wantActions[1] {
		t.Fatalf("logged actions = %v, want %v", gotActions, wantActions)
	}
	if len(gotFailed) != 0 {
		t.Fatalf("unexpected operation failures logged: %v", gotFailed)
	}
}
