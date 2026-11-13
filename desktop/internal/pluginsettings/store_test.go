package pluginsettings

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func fixture(t *testing.T) json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-documents.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	return fixture.Manifest
}

func TestPluginSettingsReadSaveResetUsesRealSources(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root, global := t.TempDir(), filepath.Join(t.TempDir(), "preferences")
	store := New(core.NewClient(), global)
	snapshot, err := store.Load(ctx, fixture(t), root)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{global, filepath.Join(root, ".lithe")} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("opening settings wrote %s: %v", path, err)
		}
	}
	saved, err := store.Save(ctx, snapshot, "global", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage(`false`)}}, nil)
	if err != nil || !saved.Committed || saved.Readback == nil {
		t.Fatalf("global save: %+v, %v", saved, err)
	}
	if _, err := os.Stat(filepath.Join(root, ".lithe")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("global save created project state: %v", err)
	}
	project, err := store.Save(ctx, *saved.Readback, "project", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage(`true`)}}, nil)
	if err != nil || project.Readback == nil {
		t.Fatalf("project save: %+v, %v", project, err)
	}
	for _, row := range project.Readback.State.Rows {
		if row.Declaration.ID == "flag" && (row.Effective.Source != "project" || string(row.Effective.Value) != "true") {
			t.Fatalf("wrong effective layer: %+v", row)
		}
	}
	reset, err := store.Save(ctx, *project.Readback, "project", []core.PluginSettingEdit{{ID: "flag"}}, nil)
	if err != nil || reset.Readback == nil {
		t.Fatalf("reset: %+v, %v", reset, err)
	}
	if _, err := os.Stat(project.Readback.ProjectPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("empty project file was not removed: %v", err)
	}
	for _, row := range reset.Readback.State.Rows {
		if row.Declaration.ID == "flag" && (row.Effective.Source != "global" || string(row.Effective.Value) != "false") {
			t.Fatalf("reset did not expose inheritance: %+v", row)
		}
	}
}

func TestPluginSettingsInvalidEditAndMissingProjectWriteNothing(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	global := filepath.Join(t.TempDir(), "preferences")
	store := New(core.NewClient(), global)
	snapshot, err := store.Load(ctx, fixture(t), "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Save(ctx, snapshot, "global", []core.PluginSettingEdit{{ID: "count", Value: json.RawMessage(`11`)}}, nil); err == nil {
		t.Fatal("invalid edit accepted")
	}
	if _, err := store.Save(ctx, snapshot, "project", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage(`false`)}}, nil); !errors.Is(err, ErrNoProject) {
		t.Fatalf("missing project: %v", err)
	}
	if _, err := os.Stat(global); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("rejection created preferences: %v", err)
	}
}

type editInterruptionKernel struct {
	*core.Client
	interruption func()
}

func (k *editInterruptionKernel) EditPluginSettings(ctx context.Context, manifest json.RawMessage, scope string, document *string, edits []core.PluginSettingEdit) (core.PluginSettingsEditPlan, error) {
	plan, err := k.Client.EditPluginSettings(ctx, manifest, scope, document, edits)
	if err == nil {
		k.interruption()
	}
	return plan, err
}

func TestPluginSettingsExternalChangeDuringCorePlanningIsPreserved(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	global := t.TempDir()
	kernel := &editInterruptionKernel{Client: core.NewClient()}
	store := New(kernel, global)
	snapshot, err := store.Load(ctx, fixture(t), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	kernel.interruption = func() {
		if err := os.WriteFile(snapshot.GlobalPath(), []byte(`{"dev.other":{"kept":true}}`), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	result, err := store.Save(ctx, snapshot, "global", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage(`false`)}}, nil)
	if result.Committed || !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("conflict: %+v, %v", result, err)
	}
	data, err := os.ReadFile(snapshot.GlobalPath())
	if err != nil || string(data) != `{"dev.other":{"kept":true}}` {
		t.Fatalf("external bytes changed: %q, %v", data, err)
	}
}

func TestPluginSettingsCancellationAfterPlanningDoesNotCreateSources(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	global := filepath.Join(t.TempDir(), "preferences")
	kernel := &editInterruptionKernel{Client: core.NewClient(), interruption: cancel}
	store := New(kernel, global)
	snapshot, err := store.Load(ctx, fixture(t), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	result, err := store.Save(ctx, snapshot, "global", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage(`false`)}}, nil)
	if result.Committed || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation: %+v, %v", result, err)
	}
	if _, err := os.Stat(global); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cancellation created preferences: %v", err)
	}
}

func TestPluginSettingsReadbackRetainsCapturedPreferenceRoot(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	first, other := t.TempDir(), t.TempDir()
	kernel := core.NewClient()
	snapshot, err := New(kernel, first).Load(ctx, fixture(t), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// A replacement owner must not retarget either publication or readback.
	result, err := New(kernel, other).Save(ctx, snapshot, "global", []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage(`false`)}}, nil)
	if err != nil || !result.Committed || result.Readback == nil {
		t.Fatalf("save: %+v, %v", result, err)
	}
	if result.Readback.GlobalPath() != snapshot.GlobalPath() {
		t.Fatalf("readback moved from %q to %q", snapshot.GlobalPath(), result.Readback.GlobalPath())
	}
	if _, err := os.Stat(filepath.Join(other, "plugin-settings.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("save touched replacement preferences: %v", err)
	}
}

type readbackFailureKernel struct {
	*core.Client
	failure error
}

func (k *readbackFailureKernel) ReadPluginSettingsState(ctx context.Context, manifest json.RawMessage, global, project *string) (core.PluginSettingsState, error) {
	if global != nil {
		return core.PluginSettingsState{}, k.failure
	}
	return k.Client.ReadPluginSettingsState(ctx, manifest, global, project)
}

func TestPluginSettingsCommittedReadbackFailureCannotRetryOldBaseline(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	kernel := &readbackFailureKernel{Client: core.NewClient(), failure: errors.New("readback unavailable")}
	store := New(kernel, t.TempDir())
	snapshot, err := store.Load(ctx, fixture(t), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	edits := []core.PluginSettingEdit{{ID: "flag", Value: json.RawMessage(`false`)}}
	result, err := store.Save(ctx, snapshot, "global", edits, nil)
	if !result.Committed || result.Readback != nil || !errors.Is(err, kernel.failure) {
		t.Fatalf("lost committed status: %+v, %v", result, err)
	}
	actual, err := os.ReadFile(snapshot.GlobalPath())
	if err != nil || !json.Valid(actual) {
		t.Fatalf("committed source unreadable: %q, %v", actual, err)
	}
	retry, err := store.Save(ctx, snapshot, "global", edits, nil)
	if retry.Committed || !errors.Is(err, configfile.ErrConflict) {
		t.Fatalf("stale baseline retried: %+v, %v", retry, err)
	}
}

func TestPluginWithoutSettingsDoesNotReadUnrelatedPreferenceFiles(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var manifest map[string]json.RawMessage
	if err := json.Unmarshal(fixture(t), &manifest); err != nil {
		t.Fatal(err)
	}
	delete(manifest, "settings")
	var requirements map[string]int
	if err := json.Unmarshal(manifest["requires"], &requirements); err != nil {
		t.Fatal(err)
	}
	delete(requirements, "settings")
	requires, err := json.Marshal(requirements)
	if err != nil {
		t.Fatal(err)
	}
	manifest["requires"] = requires
	encoded, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	global, workspace := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(global, "plugin-settings.json"), []byte("unrelated malformed file"), 0o600); err != nil {
		t.Fatal(err)
	}
	snapshot, err := New(core.NewClient(), global).Load(ctx, encoded, workspace)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.State.Storage.ReadRequired || len(snapshot.State.Rows) != 0 {
		t.Fatalf("unexpected settings read: %+v", snapshot.State)
	}
}
