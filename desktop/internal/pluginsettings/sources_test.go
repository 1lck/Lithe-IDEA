package pluginsettings

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
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

type sourceFixture struct {
	root    string
	editor  SourceEditor
	ctx     context.Context
	calls   int
	staging []string
}

func sourceDigest(data []byte) string {
	digest := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(digest[:])
}

func newSourceFixture(t *testing.T) *sourceFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "child"), 0700); err != nil {
		t.Fatal(err)
	}
	data := []byte(`{"target":"two","unrelated":"keep","credential":"private-canary"}`)
	if err := os.WriteFile(filepath.Join(root, "child/tool.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-sources.json"))
	if err != nil {
		t.Fatal(err)
	}
	var payload struct {
		Snapshot core.SourceSettingsSnapshot `json:"snapshot"`
	}
	if err := json.Unmarshal(fixture, &payload); err != nil {
		t.Fatal(err)
	}
	payload.Snapshot.Sources[1].Revision = sourceDigest(data)
	raw, err := json.Marshal(payload.Snapshot)
	if err != nil {
		t.Fatal(err)
	}
	state, err := core.NewClient().ReadSourceSettings(ctx, raw)
	if err != nil {
		t.Fatal(err)
	}
	editor, err := CaptureSources(ctx, root, state, nil)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("private-canary")) {
		t.Fatal("private source content entered the projection")
	}
	return &sourceFixture{root: root, editor: editor, ctx: ctx}
}

// This synthetic backend edits inert JSON fixtures only. It deliberately opens
// the existing staging file without CREATE, as the public protocol requires.
func (f *sourceFixture) call(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var request struct {
		SourceID   string                     `json:"sourceID"`
		Values     map[string]json.RawMessage `json:"values"`
		OutputFile string                     `json:"outputFile"`
	}
	if err := json.Unmarshal(params, &request); err != nil {
		return nil, err
	}
	f.calls++
	f.staging = append(f.staging, request.OutputFile)
	path := f.editor.paths[request.SourceID]
	document := make(map[string]json.RawMessage)
	data, err := os.ReadFile(filepath.Join(f.root, path))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err == nil {
		if err := json.Unmarshal(data, &document); err != nil {
			return nil, err
		}
	}
	for id, value := range request.Values {
		if string(value) == "null" {
			delete(document, id)
		} else {
			document[id] = value
		}
	}
	data, err = json.Marshal(document)
	if err != nil {
		return nil, err
	}
	file, err := os.OpenFile(request.OutputFile, os.O_WRONLY, 0)
	if err != nil {
		return nil, err
	}
	_, writeErr := file.Write(data)
	if err := errors.Join(writeErr, file.Close()); err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{"format": "litheSettingsSourceEdit", "version": 0, "sourceID": request.SourceID, "revision": sourceDigest(data), "changed": true})
}

func (f *sourceFixture) edit(source, choice string) core.SourceSettingsEdits {
	input := f.editor.State.Inputs[source]["target"]
	input.Inherit, input.Choice = false, choice
	return core.SourceSettingsEdits{SourceID: source, Values: map[string]core.SourceSettingInput{"target": input}}
}

func assertSourceStagingRemoved(t *testing.T, f *sourceFixture) {
	t.Helper()
	for _, path := range f.staging {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("staging remains after operation: %v", err)
		}
	}
}

func TestNativeSourcesReadAndUnchangedInheritanceWriteNothing(t *testing.T) {
	f := newSourceFixture(t)
	var edits []core.SourceSettingsEdits
	for id, inputs := range f.editor.State.Inputs {
		edits = append(edits, core.SourceSettingsEdits{SourceID: id, Values: inputs})
	}
	published, err := f.editor.Apply(f.ctx, core.NewClient(), edits, f.call, func() error { return nil })
	if err != nil || len(published) != 0 || f.calls != 0 {
		t.Fatalf("no-op = %v, %v, calls %d", published, err, f.calls)
	}
	if _, err := os.Stat(filepath.Join(f.root, "tool.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("opening/saving unchanged inheritance created a source")
	}
}

func TestNativeSourcesPublishOnlyTheEditedModuleAndPreservePrivateFields(t *testing.T) {
	f := newSourceFixture(t)
	published, err := f.editor.Apply(f.ctx, core.NewClient(), []core.SourceSettingsEdits{f.edit("child", "one")}, f.call, func() error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(f.root, "child/tool.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(published) != 1 || published["child"] != sourceDigest(data) {
		t.Fatalf("published = %v", published)
	}
	var document map[string]string
	if err := json.Unmarshal(data, &document); err != nil {
		t.Fatal(err)
	}
	if document["target"] != "one" || document["credential"] != "private-canary" || document["unrelated"] != "keep" {
		t.Fatal("native edit lost unrelated/private content")
	}
	if _, err := os.Stat(filepath.Join(f.root, "tool.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("module edit created project defaults")
	}
	assertSourceStagingRemoved(t, f)
}

func TestNativeSourcesRejectAnExternalEditBeforeCallingThePlugin(t *testing.T) {
	f := newSourceFixture(t)
	if err := os.WriteFile(filepath.Join(f.root, "child/tool.json"), []byte(`{"target":"external"}`), 0600); err != nil {
		t.Fatal(err)
	}
	_, err := f.editor.Apply(f.ctx, core.NewClient(), []core.SourceSettingsEdits{f.edit("child", "one")}, f.call, func() error { return nil })
	if !errors.Is(err, configfile.ErrConflict) || f.calls != 0 {
		t.Fatalf("conflict = %v, calls %d", err, f.calls)
	}
}

func TestNativeSourcesPrepareAllReplacementsBeforePublishingAny(t *testing.T) {
	f := newSourceFixture(t)
	rejected := errors.New("synthetic staging rejection")
	call := func(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
		if f.calls > 0 {
			return nil, rejected
		}
		return f.call(ctx, params)
	}
	published, err := f.editor.Apply(f.ctx, core.NewClient(), []core.SourceSettingsEdits{f.edit("root", "one"), f.edit("child", "one")}, call, func() error { return nil })
	if !errors.Is(err, rejected) || len(published) != 0 {
		t.Fatalf("preparation = %v, %v", published, err)
	}
	if _, err := os.Stat(filepath.Join(f.root, "tool.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("first source was published before all staging succeeded")
	}
	assertSourceStagingRemoved(t, f)
}

func TestNativeSourcesRejectAFalseStagingDigestAndCleanUp(t *testing.T) {
	f := newSourceFixture(t)
	call := func(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
		result, err := f.call(ctx, params)
		if err != nil {
			return nil, err
		}
		if err := os.WriteFile(f.staging[len(f.staging)-1], []byte("different bytes"), 0600); err != nil {
			return nil, err
		}
		return result, nil
	}
	published, err := f.editor.Apply(f.ctx, core.NewClient(), []core.SourceSettingsEdits{f.edit("child", "one")}, call, func() error { return nil })
	if !errors.Is(err, configfile.ErrConflict) || len(published) != 0 {
		t.Fatalf("digest mismatch = %v, %v", published, err)
	}
	assertSourceStagingRemoved(t, f)
}

func TestNativeSourcesReportPartialPublicationAndKeepTheRemainingSource(t *testing.T) {
	f := newSourceFixture(t)
	revoked := errors.New("synthetic owner revocation")
	check := func() error {
		if _, err := os.Stat(filepath.Join(f.root, "tool.json")); err == nil {
			return revoked
		}
		return nil
	}
	published, err := f.editor.Apply(f.ctx, core.NewClient(), []core.SourceSettingsEdits{f.edit("root", "one"), f.edit("child", "one")}, f.call, check)
	if !errors.Is(err, ErrSourcesCommitted) || !errors.Is(err, revoked) || len(published) != 1 {
		t.Fatalf("partial outcome = %v, %v", published, err)
	}
	data, readErr := os.ReadFile(filepath.Join(f.root, "child/tool.json"))
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Contains(data, []byte(`"target":"two"`)) {
		t.Fatal("revoked operation changed the remaining source")
	}
	assertSourceStagingRemoved(t, f)
}

func TestNativeSourcesCannotEditAnInstallationRoot(t *testing.T) {
	f := newSourceFixture(t)
	_, err := CaptureSources(f.ctx, f.root, f.editor.State, []string{f.root})
	if !errors.Is(err, configfile.ErrTarget) {
		t.Fatalf("installation source = %v", err)
	}
}

func TestNativeSourcesCancellationAfterStagingNeverPublishes(t *testing.T) {
	f := newSourceFixture(t)
	ctx, cancel := context.WithCancel(f.ctx)
	defer cancel()
	call := func(ctx context.Context, params json.RawMessage) (json.RawMessage, error) {
		result, err := f.call(ctx, params)
		cancel()
		return result, err
	}
	published, err := f.editor.Apply(ctx, core.NewClient(), []core.SourceSettingsEdits{f.edit("child", "one")}, call, func() error { return nil })
	if !errors.Is(err, context.Canceled) || len(published) != 0 {
		t.Fatalf("cancel outcome = %v, %v", published, err)
	}
	data, readErr := os.ReadFile(filepath.Join(f.root, "child/tool.json"))
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !bytes.Contains(data, []byte(`"target":"two"`)) {
		t.Fatal("canceled operation published a source")
	}
	assertSourceStagingRemoved(t, f)
}
