package settingswindow

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

func TestPluginSettingsDraftPreservesSevenDeclaredControlTypes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err := os.ReadFile("../../../shared/fixtures/plugins/settings-documents.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	source := pluginsettings.New(core.NewClient(), t.TempDir())
	snapshot, err := source.Load(ctx, fixture.Manifest, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p := newPluginSettingsForm(nil)
	p.editor.Snapshot, p.loaded = snapshot, true
	p.applyScope(0)
	p.applyScope(1)
	values := map[string]string{"count": "8", "label": "node", "program": filepath.Join(t.TempDir(), "tool"), "folder": t.TempDir()}
	for index, row := range snapshot.State.Rows {
		c := &p.controls[0][index]
		switch row.Declaration.Kind {
		case "boolean":
			c.input.On = false
		case "enum":
			c.input.Selected = 1
		case "multiSelect":
			c.input.Checks[0] = true
		default:
			c.text = values[row.Declaration.ID]
		}
	}
	edits, err := p.edits()
	if err != nil || len(edits) != 7 {
		t.Fatalf("draft=%+v error=%v", edits, err)
	}
	result, err := source.Save(ctx, snapshot, "global", edits, nil)
	if err != nil || result.Readback == nil {
		t.Fatalf("save=%+v error=%v", result, err)
	}
	got := result.Readback.State.Settings
	for id, want := range map[string]string{"count": "8", "flag": "false", "format": `"rich"`, "checks": `["lint"]`, "label": `"node"`} {
		if string(got[id]) != want {
			t.Errorf("%s=%s want %s", id, got[id], want)
		}
	}
	p.editor.Snapshot = *result.Readback
	p.applyScope(0)
	if p.hasDraft() {
		t.Fatal("readback appears dirty")
	}
	for index, row := range result.Readback.State.Rows {
		control := &p.controls[0][index]
		control.apply(result.Readback.State.Editors.Global[index].ResetInput)
		control.reset = true
		if row.Declaration.Kind == "integer" && control.text != "3" {
			t.Fatal("reset input did not come from Core")
		}
	}
	resets, err := p.edits()
	if err != nil || len(resets) != 7 {
		t.Fatalf("reset edits=%+v error=%v", resets, err)
	}
	for _, edit := range resets {
		if edit.Text != nil || edit.Value != nil {
			t.Fatalf("reset is an override: %+v", edit)
		}
	}
	reset, err := source.Save(ctx, *result.Readback, "global", resets, nil)
	if err != nil || reset.Readback == nil {
		t.Fatalf("reset=%+v error=%v", reset, err)
	}
	if _, err := os.Stat(reset.Readback.GlobalPath()); !os.IsNotExist(err) {
		t.Fatalf("reset retained empty source: %v", err)
	}
}

func TestPluginSettingsInvalidIntegerDraftStaysUnparsedUntilCoreRejectsSave(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err := os.ReadFile("../../../shared/fixtures/plugins/settings-documents.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	source := pluginsettings.New(core.NewClient(), t.TempDir())
	snapshot, err := source.Load(ctx, fixture.Manifest, "")
	if err != nil {
		t.Fatal(err)
	}
	p := newPluginSettingsForm(nil)
	p.editor.Snapshot, p.loaded = snapshot, true
	p.applyScope(0)
	for index, row := range snapshot.State.Rows {
		if row.Declaration.ID == "count" {
			p.controls[0][index].text = "1.25"
		}
	}
	edits, err := p.edits()
	if err != nil || len(edits) != 1 || edits[0].Text == nil || *edits[0].Text != "1.25" {
		t.Fatalf("native parsed integer draft: %+v %v", edits, err)
	}
	result, err := source.Save(ctx, snapshot, "global", edits, nil)
	if err == nil || result.Committed || !p.hasDraft() {
		t.Fatalf("invalid editor text published: %+v %v", result, err)
	}
	if _, err := os.Stat(snapshot.GlobalPath()); !os.IsNotExist(err) {
		t.Fatalf("invalid draft created source: %v", err)
	}
}

type queuedSettingsLoad struct {
	id      string
	ctx     context.Context
	release chan struct{}
}
type queuedSettingsSource struct{ requests chan queuedSettingsLoad }

func (s queuedSettingsSource) Load(ctx context.Context, id string) (pluginservice.SettingsEditor, error) {
	release := make(chan struct{})
	s.requests <- queuedSettingsLoad{id: id, ctx: ctx, release: release}
	<-release // Model a native read completing just after cancellation.
	return pluginservice.SettingsEditor{Snapshot: pluginsettings.Snapshot{State: core.PluginSettingsState{PluginID: id}}}, nil
}
func (s queuedSettingsSource) Save(context.Context, pluginservice.SettingsEditor, string, []core.PluginSettingEdit) (pluginsettings.SaveResult, error) {
	return pluginsettings.SaveResult{}, errors.New("unexpected save")
}

// Rapid selection replaces the read in flight: its context is cancelled, the reads that were
// replaced before a paint never start, and only the latest owner's result is shown even
// when the cancelled read completes after it.
func TestPluginSettingsRapidSelectionCancelsStaleAndKeepsLatestOwner(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	requests := make(chan queuedSettingsLoad, 4)
	w := newWindow(NewController(Options{PluginSettings: queuedSettingsSource{requests: requests}}), Values{})
	d := openWindow(t, w)
	p := w.pluginSettings
	var releases []chan struct{}
	t.Cleanup(func() {
		for _, release := range releases {
			select {
			case <-release:
			default:
				close(release)
			}
		}
	})
	next := func() queuedSettingsLoad {
		t.Helper()
		select {
		case request := <-requests:
			releases = append(releases, request.release)
			return request
		case <-ctx.Done():
			t.Fatal("native settings load did not start")
			return queuedSettingsLoad{}
		}
	}
	p.load("old")
	w.inv.Invalidate()
	d.pump()
	old := next()
	p.load("intermediate")
	p.load("latest")
	w.inv.Invalidate()
	d.pump()
	latest := next()
	if latest.id != "latest" {
		t.Fatalf("started owner=%s", latest.id)
	}
	if old.ctx.Err() == nil {
		t.Fatal("replaced read was not cancelled")
	}
	select {
	case request := <-requests:
		t.Fatalf("a replaced read started: %s", request.id)
	default:
	}
	// The cancelled read completes after the latest one was asked for.
	close(latest.release)
	close(old.release)
	d.until("the latest owner", func() bool { return p.loaded })
	for range 3 {
		time.Sleep(5 * time.Millisecond)
		w.inv.Invalidate()
		d.pump()
	}
	if !p.loaded || p.editor.Snapshot.State.PluginID != "latest" || p.running {
		t.Fatalf("late result replaced owner: %+v", p.editor.Snapshot.State)
	}
}
