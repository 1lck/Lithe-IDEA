package remoteconn

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// testPorts is a PortsKernel that keeps one workspace's records as the JSON of
// core.RemotePortRecords, without a session, and remembers the document of every call.
type testPorts struct {
	documents []string
}

var testPortsStorage = core.RemotePreferenceStorage{RelativePath: "remote/ports.json", MaximumBytes: 4096}

func (k *testPorts) decode(document *string, sessionID string) (core.RemotePortRecords, error) {
	if document != nil {
		k.documents = append(k.documents, *document)
	}
	if sessionID != "session-1" {
		return core.RemotePortRecords{}, &core.Error{Code: core.CodeConnectionClosed, Message: "closed"}
	}
	var records core.RemotePortRecords
	if document != nil && json.Unmarshal([]byte(*document), &records) != nil {
		return core.RemotePortRecords{}, &core.Error{Code: core.CodeParseFailed, Message: "not json"}
	}
	return records, nil
}

func (k *testPorts) RemotePortRecords(_ context.Context, document *string, sessionID, workspace string) (core.RemotePortRecordsState, error) {
	records, err := k.decode(document, sessionID)
	return core.RemotePortRecordsState{Records: records, Workspace: workspace, Storage: testPortsStorage}, err
}

func (k *testPorts) EditRemotePortRecords(_ context.Context, document *string, sessionID, _ string, edit core.RemotePortRecordEdit) (bool, *string, core.RemotePortRecords, error) {
	records, err := k.decode(document, sessionID)
	if err != nil {
		return false, nil, core.RemotePortRecords{}, err
	}
	if edit.Port != nil {
		records.Ports = slices.DeleteFunc(records.Ports, func(record core.RemotePortRecord) bool { return record.Port == edit.Port.Port })
		records.Ports = append(records.Ports, *edit.Port)
	}
	data, err := json.Marshal(records)
	if err != nil {
		return false, nil, core.RemotePortRecords{}, err
	}
	if document != nil && *document == string(data) {
		return false, nil, records, nil
	}
	updated := string(data)
	return true, &updated, records, nil
}

func (k *testPorts) RestoreRemoteForwards(_ context.Context, document *string, sessionID, _ string) ([]core.RemoteRestoredForward, error) {
	records, err := k.decode(document, sessionID)
	if err != nil {
		return nil, err
	}
	var restored []core.RemoteRestoredForward
	for _, record := range records.Ports {
		if record.ForwardTarget != "" {
			restored = append(restored, core.RemoteRestoredForward{Port: record.Port, Forward: &core.RemoteForward{TargetPort: record.Port}, Created: true})
		}
	}
	return restored, nil
}

// Reading absent records creates nothing; an edit writes only the records document below the
// preference root, an edit that changes nothing writes nothing, and the forwards are restored from
// the bytes on disk.
func TestPortRecordsWriteOnlyTheirDocument(t *testing.T) {
	ctx := testContext(t)
	kernel := &testPorts{}
	root := filepath.Join(t.TempDir(), "preferences")
	read, err := ReadPortRecords(ctx, kernel, root, "session-1", "/srv/repo")
	if err != nil || read.State.Workspace != "/srv/repo" || len(read.State.Records.Ports) != 0 {
		t.Fatalf("read: rows = %d, err = %v", len(read.State.Records.Ports), err)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("reading created the preference root: %v", err)
	}
	edit := core.RemotePortRecordEdit{Port: &core.RemotePortRecord{Port: 8080, Label: "web", ForwardTarget: "localhost"}}
	after, committed, err := read.Edit(ctx, kernel, edit)
	if err != nil || !committed || len(after.Ports) != 1 || after.Ports[0].Label != "web" {
		t.Fatalf("edit: committed = %v, rows = %d, err = %v", committed, len(after.Ports), err)
	}
	var files []string
	if err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err == nil && !entry.IsDir() {
			files = append(files, path)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(root, "remote", "ports.json"); len(files) != 1 || files[0] != want {
		t.Fatalf("the edit wrote %d files, want the records document alone", len(files))
	}
	reread, err := ReadPortRecords(ctx, kernel, root, "session-1", "/srv/repo")
	if err != nil || len(reread.State.Records.Ports) != 1 {
		t.Fatalf("reread: rows = %d, err = %v", len(reread.State.Records.Ports), err)
	}
	data, _ := os.ReadFile(files[0])
	if _, committed, err := reread.Edit(ctx, kernel, edit); err != nil || committed {
		t.Fatalf("unchanged edit: committed = %v, err = %v", committed, err)
	}
	if again, _ := os.ReadFile(files[0]); string(again) != string(data) {
		t.Fatal("an edit that changes nothing rewrote the document")
	}
	restored, err := reread.Restore(ctx, kernel)
	if err != nil || len(restored) != 1 || restored[0].Port != 8080 || kernel.documents[len(kernel.documents)-1] != string(data) {
		t.Fatalf("restore: %d forwards, err = %v, want the forward the document records", len(restored), err)
	}
}

// An edit of a document changed since it was read is ErrConflict and keeps the other writer's
// bytes.
func TestPortRecordsEditOfAChangedDocumentIsAConflict(t *testing.T) {
	ctx := testContext(t)
	kernel := &testPorts{}
	root := t.TempDir()
	read, err := ReadPortRecords(ctx, kernel, root, "session-1", "/srv/repo")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "remote", "ports.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	other := []byte(`{"ports":[{"port":9090,"label":"other"}],"rules":[]}`)
	if err := os.WriteFile(path, other, 0o600); err != nil {
		t.Fatal(err)
	}
	_, committed, err := read.Edit(ctx, kernel, core.RemotePortRecordEdit{Port: &core.RemotePortRecord{Port: 8080, Label: "web"}})
	if !errors.Is(err, ErrConflict) || committed {
		t.Fatalf("edit: committed = %v, err = %v, want a conflict", committed, err)
	}
	if data, _ := os.ReadFile(path); string(data) != string(other) {
		t.Fatal("the conflicting edit replaced the other writer's document")
	}
}

// A document Core cannot decode is ErrDamaged and is never sent to be edited; a closed session is
// Core's error and not a damaged document, and no preference root is ErrUnavailable.
func TestDamagedPortRecordsAreReported(t *testing.T) {
	ctx := testContext(t)
	kernel := &testPorts{}
	root := t.TempDir()
	path := filepath.Join(root, "remote", "ports.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadPortRecords(ctx, kernel, root, "session-1", "/srv/repo"); !errors.Is(err, ErrDamaged) {
		t.Fatalf("read: err = %v, want ErrDamaged", err)
	}
	var coreErr *core.Error
	if _, err := ReadPortRecords(ctx, kernel, root, "session-2", "/srv/repo"); errors.Is(err, ErrDamaged) || !errors.As(err, &coreErr) || coreErr.Code != core.CodeConnectionClosed {
		t.Fatalf("closed session: err = %v, want connection_closed", err)
	}
	if _, err := ReadPortRecords(ctx, kernel, "", "session-1", "/srv/repo"); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("no root: err = %v", err)
	}
	if _, _, err := (PortRecords{}).Edit(ctx, kernel, core.RemotePortRecordEdit{}); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("edit without a reading: err = %v", err)
	}
	if _, err := (PortRecords{}).Restore(ctx, kernel); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("restore without a reading: err = %v", err)
	}
}
