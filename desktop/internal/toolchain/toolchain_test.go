package toolchain

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func readManifest(t *testing.T, name string) json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func writeExecutable(t *testing.T, name string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func canonical(t *testing.T, name string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(name)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}

func fixtureOptions(home, vmHome string, outputs map[string]string) Options {
	return Options{
		Platform: PlatformName(runtime.GOOS),
		Home:     home,
		Environment: map[string]string{
			"FICTIONAL_VM_HOME": vmHome,
		},
		Probe: func(_ context.Context, executable string, _ []string) (string, int, error) {
			output, ok := outputs[executable]
			if !ok {
				return "", 1, nil
			}
			return output, 0, nil
		},
		Lookup: func(string) (string, error) { return "", errors.New("no command") },
	}
}

func TestLoadDiscoversTwoSemanticallyDifferentTools(t *testing.T) {
	root := t.TempDir()
	home := t.TempDir()
	compilerHome := filepath.Join(home, "tools", "compiler-1.0")
	compiler := filepath.Join(compilerHome, "bin", "cc")
	writeExecutable(t, compiler)
	compiler = canonical(t, compiler)
	vmHome := filepath.Join(home, "runtimes", "vm-7")
	vm := filepath.Join(vmHome, "jre", "bin", "vm")
	writeExecutable(t, vm)
	vm = canonical(t, vm)

	ctx, cancel := context.WithTimeout(context.Background(), 20e9)
	defer cancel()
	manifest := readManifest(t, "compiler.plugin.json")
	runtimeManifest := readManifest(t, "runtime.plugin.json")
	snapshot, err := Load(ctx, core.NewClient(), root, ".", []json.RawMessage{manifest, runtimeManifest},
		fixtureOptions(home, vmHome, map[string]string{
			compiler: "Compiler 3.2.1\n",
			vm:       "vm 7.1\n",
		}))
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Tools) != 2 {
		t.Fatalf("tools = %d, want 2: %+v", len(snapshot.Tools), snapshot.Tools)
	}
	byID := map[string]Tool{}
	for _, tool := range snapshot.Tools {
		byID[tool.ID] = tool
	}
	compilerTool, ok := byID["dev.example.toolsmith:compiler"]
	if !ok {
		t.Fatalf("compiler tool missing: %+v", snapshot.Tools)
	}
	if compilerTool.Effective == nil || compilerTool.Effective.Version != "3.2.1" {
		t.Fatalf("compiler effective = %+v", compilerTool.Effective)
	}
	if filepath.Base(compilerTool.Effective.Executable) != "cc" || compilerTool.Effective.Layer != "automatic" {
		t.Fatalf("compiler selection = %+v", compilerTool.Effective)
	}
	if compilerTool.Effective.Environment["FICTIONAL_CC_HOME"] != filepath.Dir(filepath.Dir(compiler)) {
		t.Fatalf("compiler environment = %+v", compilerTool.Effective.Environment)
	}
	if len(compilerTool.Effective.PathPrepend) != 1 {
		t.Fatalf("compiler path prepend = %+v", compilerTool.Effective.PathPrepend)
	}
	if len(compilerTool.Installations) != 1 {
		t.Fatalf("compiler installations = %+v", compilerTool.Installations)
	}
	vmTool, ok := byID["dev.example.runtime:vm"]
	if !ok {
		t.Fatalf("vm tool missing: %+v", snapshot.Tools)
	}
	if vmTool.Effective == nil || vmTool.Effective.Version != "7.1" {
		for _, trace := range vmTool.Trace {
			if trace.Reason != nil {
				t.Logf("vm trace reason = %s", trace.Reason.Code)
			}
		}
		t.Fatalf("vm effective = %+v", vmTool.Effective)
	}
	if filepath.Base(vmTool.Effective.Executable) != "vm" {
		t.Fatalf("vm executable = %q", vmTool.Effective.Executable)
	}
	if vmTool.Effective.Environment["FICTIONAL_VM_HOME"] != canonical(t, vmHome) {
		t.Fatalf("vm environment = %+v", vmTool.Effective.Environment)
	}
	if _, err := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("loading created workspace state: %v", err)
	}
}

func TestSavedPinAppliesToTheProjectAndSubdirectories(t *testing.T) {
	root := t.TempDir()
	home := t.TempDir()
	compilerHome := filepath.Join(home, "tools", "compiler-1.0")
	compiler := filepath.Join(compilerHome, "bin", "cc")
	writeExecutable(t, compiler)
	compiler = canonical(t, compiler)
	if err := os.MkdirAll(filepath.Join(root, ".lithe", "toolchains"), 0o755); err != nil {
		t.Fatal(err)
	}
	document := []byte(`{"version":1,"toolchains":{"legacy":{"home":"/fixture/legacy"}},"pins":{".":{"dev.example.toolsmith:compiler":{"home":"` + compilerHome + `","version":"3.2.1","provider":"host:system"}}}}`)
	if err := os.WriteFile(filepath.Join(root, ".lithe", "toolchains", "local.json"), document, 0o600); err != nil {
		t.Fatal(err)
	}
	manifest := readManifest(t, "compiler.plugin.json")
	ctx, cancel := context.WithTimeout(context.Background(), 20e9)
	defer cancel()
	for _, directory := range []string{".", "nested/child"} {
		snapshot, err := Load(ctx, core.NewClient(), root, directory, []json.RawMessage{manifest},
			fixtureOptions(home, "", map[string]string{compiler: "Compiler 3.2.1\n"}))
		if err != nil {
			t.Fatal(err)
		}
		if len(snapshot.Tools) != 1 || snapshot.Tools[0].Effective == nil {
			t.Fatalf("%s: tools = %+v", directory, snapshot.Tools)
		}
		if snapshot.Tools[0].Effective.Layer != "pinned" {
			for _, trace := range snapshot.Tools[0].Trace {
				if trace.Reason != nil {
					t.Logf("%s trace reason = %s", directory, trace.Reason.Code)
				}
			}
			t.Fatalf("%s selected layer %q, want pinned", directory, snapshot.Tools[0].Effective.Layer)
		}
		if snapshot.Tools[0].Pin == nil || snapshot.Tools[0].PinSource != "." {
			t.Fatalf("%s pin = %+v source %q", directory, snapshot.Tools[0].Pin, snapshot.Tools[0].PinSource)
		}
	}
}

func TestConflictingShortIDsHaveNoOwner(t *testing.T) {
	root := t.TempDir()
	home := t.TempDir()
	writeExecutable(t, filepath.Join(home, "tools", "compiler-1.0", "bin", "cc"))
	ctx, cancel := context.WithTimeout(context.Background(), 20e9)
	defer cancel()
	snapshot, err := Load(ctx, core.NewClient(), root, ".", []json.RawMessage{
		readManifest(t, "conflict.plugin.json"),
		readManifest(t, "conflict-b.plugin.json"),
	}, fixtureOptions(home, "", nil))
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Conflicts) != 1 || snapshot.Conflicts[0].Tool != "compiler" {
		t.Fatalf("conflicts = %+v", snapshot.Conflicts)
	}
	if len(snapshot.Tools) != 0 {
		t.Fatalf("a contested tool was registered: %+v", snapshot.Tools)
	}
}

func TestSavePinPreservesUnrelatedEntriesAndDetectsConflicts(t *testing.T) {
	root := t.TempDir()
	home := t.TempDir()
	compilerHome := filepath.Join(home, "tools", "compiler-1.0")
	writeExecutable(t, filepath.Join(compilerHome, "bin", "cc"))
	document := []byte(`{"version":1,"toolchains":{"legacy":{"home":"/fixture/legacy"}},"pins":{"other":{"dev.example.runtime:vm":{"home":"/fixture/vm","version":"7.1","provider":"host:system"}}}}`)
	if err := os.MkdirAll(filepath.Join(root, ".lithe", "toolchains"), 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, ".lithe", "toolchains", "local.json")
	if err := os.WriteFile(path, document, 0o640); err != nil {
		t.Fatal(err)
	}
	originalInfo, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20e9)
	defer cancel()
	pin := &core.ToolchainPin{Home: compilerHome, Version: "3.2.1", Provider: "host:system"}
	saved, baseline, err := SavePin(ctx, core.NewClient(), root, ".", "dev.example.toolsmith:compiler", pin, document)
	if err != nil {
		t.Fatal(err)
	}
	if saved == nil || baseline == nil {
		t.Fatal("save returned no document")
	}
	var parsed savedPinFixture
	if err := json.Unmarshal(saved, &parsed); err != nil {
		t.Fatal(err)
	}
	if _, ok := parsed.Toolchains["legacy"]; !ok {
		t.Fatalf("legacy entries were dropped: %+v", parsed.Toolchains)
	}
	if parsed.Pins["other"]["dev.example.runtime:vm"].Home != "/fixture/vm" {
		t.Fatalf("unrelated pin was changed: %+v", parsed.Pins)
	}
	if parsed.Pins["."]["dev.example.toolsmith:compiler"].Home != compilerHome {
		t.Fatalf("saved pin missing: %+v", parsed.Pins)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != originalInfo.Mode().Perm() {
		t.Fatalf("mode = %o, want original native mode %o", info.Mode().Perm(), originalInfo.Mode().Perm())
	}
	ignore, err := os.ReadFile(filepath.Join(root, ".lithe", ".gitignore"))
	if err != nil {
		t.Fatal(err)
	}
	if !containsLine(string(ignore), LocalIgnorePath) {
		t.Fatalf("ignore file = %q", ignore)
	}
	// A stale baseline must not overwrite the file another editor changed.
	if _, _, err := SavePin(ctx, core.NewClient(), root, ".", "dev.example.toolsmith:compiler", pin, document); !errors.Is(err, ErrPinConflict) {
		t.Fatalf("stale baseline error = %v, want conflict", err)
	}
	current, _ := os.ReadFile(path)
	if string(current) != string(saved) {
		t.Fatal("a conflicting save changed the document")
	}
	updated, _, err := SavePin(ctx, core.NewClient(), root, ".", "dev.example.toolsmith:compiler", nil, saved)
	if err != nil {
		t.Fatal(err)
	}
	parsed = savedPinFixture{}
	if err := json.Unmarshal(updated, &parsed); err != nil {
		t.Fatal(err)
	}
	if _, ok := parsed.Pins["."]; ok {
		t.Fatalf("removed pin left an empty directory: %+v", parsed.Pins)
	}
	if _, ok := parsed.Pins["other"]["dev.example.runtime:vm"]; !ok {
		t.Fatalf("removing one pin changed another: %+v", parsed.Pins)
	}
}

func containsLine(text, line string) bool {
	for _, candidate := range splitLines(text) {
		if candidate == line {
			return true
		}
	}
	return false
}

func splitLines(text string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(text); i++ {
		if text[i] == '\n' {
			lines = append(lines, text[start:i])
			start = i + 1
		}
	}
	if start < len(text) {
		lines = append(lines, text[start:])
	}
	return lines
}

// blockingPinKernel pauses the first Core validation so a test can cancel the
// save at the exact point between validation and the native writes.
type blockingPinKernel struct {
	*core.Client
	entered chan struct{}
	release chan struct{}
	block   atomic.Bool
}

func (k *blockingPinKernel) EditToolchainPins(ctx context.Context, document json.RawMessage, directory string, edits []core.ToolchainPinEdit) (json.RawMessage, error) {
	if k.block.CompareAndSwap(true, false) {
		close(k.entered)
		select {
		case <-k.release:
		case <-time.After(5 * time.Second):
		}
	}
	if ctx.Err() != nil {
		// Core's cancellation is cooperative: a validation that finished before
		// observing cancellation returns its normal result, and the host must
		// refuse to write after the caller cancelled.
		return document, nil
	}
	return k.Client.EditToolchainPins(ctx, document, directory, edits)
}

func readExactly(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestSavePinCancelledAfterValidationWritesNothing(t *testing.T) {
	root := t.TempDir()
	document := []byte(`{"version":1,"toolchains":{"legacy":{"home":"/fixture/legacy"}}}`)
	local := filepath.Join(root, ".lithe", "toolchains", "local.json")
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, document, 0o640); err != nil {
		t.Fatal(err)
	}
	ignore := filepath.Join(root, ".lithe", ".gitignore")
	if err := os.WriteFile(ignore, []byte("existing\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	kernel := &blockingPinKernel{
		Client:  core.NewClient(),
		entered: make(chan struct{}),
		release: make(chan struct{}),
	}
	kernel.block.Store(true)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, _, err := SavePin(ctx, kernel, root, ".", "dev.example.toolsmith:compiler",
			&core.ToolchainPin{Home: "/fixture/compiler", Version: "1.0", Provider: "host:system"}, document)
		done <- err
	}()
	select {
	case <-kernel.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the save never reached Core validation")
	}
	cancel()
	close(kernel.release)
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("SavePin error = %v, want context.Canceled", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("SavePin did not return after cancellation")
	}
	if got := readExactly(t, local); string(got) != string(document) {
		t.Fatalf("cancelled save changed the toolchain document: %q", got)
	}
	if got := readExactly(t, ignore); string(got) != "existing\n" {
		t.Fatalf("cancelled save changed the ignore file: %q", got)
	}
	entries, err := os.ReadDir(filepath.Dir(local))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "local.json" {
		t.Fatalf("cancelled save left temporary files: %+v", entries)
	}
}

func TestSavePinIgnoreFailureLeavesDocumentUntouched(t *testing.T) {
	root := t.TempDir()
	document := []byte(`{"version":1,"toolchains":{}}`)
	local := filepath.Join(root, ".lithe", "toolchains", "local.json")
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, document, 0o600); err != nil {
		t.Fatal(err)
	}
	// A directory where .gitignore should be makes the prerequisite write fail.
	if err := os.MkdirAll(filepath.Join(root, ".lithe", ".gitignore"), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _, err := SavePin(ctx, core.NewClient(), root, ".", "dev.example.toolsmith:compiler",
		&core.ToolchainPin{Home: "/fixture/compiler", Version: "1.0", Provider: "host:system"}, document)
	if err == nil {
		t.Fatal("a failed ignore write was reported as success")
	}
	if got := readExactly(t, local); string(got) != string(document) {
		t.Fatalf("ignore failure changed the toolchain document: %q", got)
	}
}

func TestSavePinRejectsUnknownTopLevelFieldsBeforeWriting(t *testing.T) {
	root := t.TempDir()
	document := []byte(`{"version":1,"toolchains":{},"unknown":true}`)
	local := filepath.Join(root, ".lithe", "toolchains", "local.json")
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, document, 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _, err := SavePin(ctx, core.NewClient(), root, ".", "dev.example.toolsmith:compiler",
		&core.ToolchainPin{Home: "/fixture/compiler", Version: "1.0", Provider: "host:system"}, document)
	if err == nil {
		t.Fatal("a document with an unknown top-level field was accepted")
	}
	if got := readExactly(t, local); string(got) != string(document) {
		t.Fatalf("rejected document was rewritten: %q", got)
	}
	if _, statErr := os.Stat(filepath.Join(root, ".lithe", ".gitignore")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("a rejected save created the ignore file: %v", statErr)
	}
}

func TestSavePinsAppliesEveryDraftEditInOneTransaction(t *testing.T) {
	root := t.TempDir()
	document := []byte(`{"version":1,"toolchains":{"legacy":{"home":"/fixture/legacy"}},"pins":{".":{"dev.example:old":{"home":"/fixture/old","version":"1.0","provider":"host:system"}}}}`)
	local := filepath.Join(root, ".lithe", "toolchains", "local.json")
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, document, 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	saved, _, err := SavePins(ctx, core.NewClient(), root, ".", []Edit{
		{Tool: "dev.example:old"},
		{Tool: "dev.example:new", Pin: &core.ToolchainPin{Home: "/fixture/new", Version: "2.0", Provider: "host:system"}},
	}, document)
	if err != nil {
		t.Fatal(err)
	}
	var parsed savedPinFixture
	if err := json.Unmarshal(saved, &parsed); err != nil {
		t.Fatal(err)
	}
	if _, ok := parsed.Pins["."]["dev.example:old"]; ok {
		t.Fatalf("removed pin survived: %+v", parsed.Pins)
	}
	if parsed.Pins["."]["dev.example:new"].Home != "/fixture/new" {
		t.Fatalf("new pin missing: %+v", parsed.Pins)
	}
	if _, ok := parsed.Toolchains["legacy"]; !ok {
		t.Fatalf("legacy entry was dropped: %+v", parsed.Toolchains)
	}
}

// externalEditKernel models another editor publishing after the initial read.
type externalEditKernel struct {
	*core.Client
	path    string
	content []byte
}

func (k externalEditKernel) EditToolchainPins(ctx context.Context, document json.RawMessage, directory string, edits []core.ToolchainPinEdit) (json.RawMessage, error) {
	edited, err := k.Client.EditToolchainPins(ctx, document, directory, edits)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(k.path, k.content, 0o600); err != nil {
		return nil, err
	}
	return edited, nil
}

func TestSavePinsRejectsExternalEditDuringCoreEditing(t *testing.T) {
	root := t.TempDir()
	path := documentPath(root)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	baseline := []byte(`{"version":1,"toolchains":{}}`)
	changed := []byte(`{"version":1,"toolchains":{"other":{"home":"/fixture/other"}}}`)
	if err := os.WriteFile(path, baseline, 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, _, err := SavePins(ctx, externalEditKernel{core.NewClient(), path, changed}, root, ".", []Edit{{Tool: "java", Pin: nil}}, baseline)
	if !errors.Is(err, ErrPinConflict) {
		t.Fatalf("save error = %v, want conflict", err)
	}
	if got := readExactly(t, path); string(got) != string(changed) {
		t.Fatalf("external edit overwritten: %s", got)
	}
}

// savedPinFixture decodes only the fields these preservation assertions inspect.
type savedPinFixture struct {
	Toolchains map[string]json.RawMessage              `json:"toolchains"`
	Pins       map[string]map[string]core.ToolchainPin `json:"pins"`
}
