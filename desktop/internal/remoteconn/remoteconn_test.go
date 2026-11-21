package remoteconn

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func save(name, host string) core.RemoteConnectionEdit {
	return core.RemoteConnectionEdit{Save: &core.RemoteConnectionSave{Name: name, Connection: core.SSHConnection{Host: host}}}
}

// Reading an absent list creates nothing; a save writes the document Core returned under the
// preference root and the list is read back from it.
func TestSavingWritesOnlyThePreferenceDocument(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	root := filepath.Join(t.TempDir(), "preferences")
	source, err := Read(ctx, kernel, root)
	if err != nil || len(source.Connections) != 0 {
		t.Fatalf("read = %+v, err = %v", source, err)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("reading created %s: %v", root, err)
	}
	after, id, committed, err := source.Edit(ctx, kernel, save("Build box", "build.example"))
	if err != nil || !committed || id == "" {
		t.Fatalf("save: id = %q, committed = %v, err = %v", id, committed, err)
	}
	if len(after.Connections) != 1 || after.Connections[0].ID != id || after.Connections[0].Name != "Build box" {
		t.Fatalf("after = %+v", after.Connections)
	}
	want := filepath.Join(root, "remote", "connections.json")
	if after.Path() != want {
		t.Fatalf("path = %q, want %q", after.Path(), want)
	}
	reread, err := Read(ctx, kernel, root)
	if err != nil || len(reread.Connections) != 1 || reread.Connections[0].ID != id {
		t.Fatalf("reread = %+v, err = %v", reread, err)
	}
	removed, _, committed, err := reread.Edit(ctx, kernel, core.RemoteConnectionEdit{Remove: &core.RemoteConnectionID{ID: id}})
	if err != nil || !committed || len(removed.Connections) != 0 {
		t.Fatalf("remove: %+v, committed = %v, err = %v", removed.Connections, committed, err)
	}
}

// An edit against bytes that changed on disk writes nothing.
func TestEditingAChangedListIsAConflict(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	root := t.TempDir()
	initial, err := Read(ctx, kernel, root)
	if err != nil {
		t.Fatal(err)
	}
	first, _, _, err := initial.Edit(ctx, kernel, save("A", "a.example"))
	if err != nil {
		t.Fatal(err)
	}
	stale, err := Read(ctx, kernel, root)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := first.Edit(ctx, kernel, save("B", "b.example")); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(stale.Path())
	if err != nil {
		t.Fatal(err)
	}
	_, _, committed, err := stale.Edit(ctx, kernel, save("C", "c.example"))
	if !errors.Is(err, ErrConflict) || committed {
		t.Fatalf("stale edit: committed = %v, err = %v, want a conflict", committed, err)
	}
	if now, _ := os.ReadFile(stale.Path()); string(now) != string(before) {
		t.Fatal("a stale edit changed the file")
	}
}

// A list Core cannot decode is reported as damaged with its path, and is never overwritten; a
// refused entry names the field.
func TestADamagedListIsNeverOverwritten(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	root := t.TempDir()
	path := filepath.Join(root, "remote", "connections.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	damaged := []byte(`{"version":2,"connections":[]}`)
	if err := os.WriteFile(path, damaged, 0o600); err != nil {
		t.Fatal(err)
	}
	source, err := Read(ctx, kernel, root)
	if !errors.Is(err, ErrDamaged) || source.Path() != path {
		t.Fatalf("read: path = %q, err = %v, want the damaged list at %s", source.Path(), err, path)
	}
	if _, _, committed, err := source.Edit(ctx, kernel, save("A", "a.example")); !errors.Is(err, ErrDamaged) || committed {
		t.Fatalf("edit: committed = %v, err = %v, want the damaged list refused", committed, err)
	}
	if now, _ := os.ReadFile(path); string(now) != string(damaged) {
		t.Fatal("the damaged list was overwritten")
	}

	empty, err := Read(ctx, kernel, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, err = empty.Edit(ctx, kernel, save("Box", "dev@box"))
	if field, reason, ok := core.RemoteConnectionFieldError(err); !ok || field != "host" || reason != "invalid" {
		t.Fatalf("host with a user: %v", err)
	}
	if _, err := Read(ctx, kernel, ""); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("no root: %v", err)
	}
}
