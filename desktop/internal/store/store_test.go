package store

import (
	"os"
	"path/filepath"
	"testing"
)

type sample struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}

func TestLoadMissingFileLeavesValue(t *testing.T) {
	store := At(filepath.Join(t.TempDir(), "absent"))
	value := sample{Name: "kept"}
	found, err := store.Load("settings.json", &value)
	if err != nil || found {
		t.Fatalf("Load = %v, %v; want not found", found, err)
	}
	if value.Name != "kept" {
		t.Fatalf("Load changed the value: %+v", value)
	}
	if _, err := os.Stat(store.Dir()); !os.IsNotExist(err) {
		t.Fatalf("Load created the directory: %v", err)
	}
}

func TestSaveThenLoad(t *testing.T) {
	store := At(filepath.Join(t.TempDir(), "nested", "Lithe Desktop"))
	if err := store.Save("settings.json", sample{Name: "first", Count: 1}); err != nil {
		t.Fatal(err)
	}
	if err := store.Save("settings.json", sample{Name: "second", Count: 2}); err != nil {
		t.Fatal(err)
	}
	var value sample
	found, err := store.Load("settings.json", &value)
	if err != nil || !found {
		t.Fatalf("Load = %v, %v", found, err)
	}
	if value != (sample{Name: "second", Count: 2}) {
		t.Fatalf("Load = %+v", value)
	}
	entries, err := os.ReadDir(store.Dir())
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		names := make([]string, 0, len(entries))
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		t.Fatalf("temporary files left behind: %v", names)
	}
}

func TestLoadReportsCorruptFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	var value sample
	found, err := At(dir).Load("settings.json", &value)
	if !found || err == nil {
		t.Fatalf("Load = %v, %v; want found with an error", found, err)
	}
}

func TestWriteFileReplacesBytesAndRemoveDeletes(t *testing.T) {
	store := At(filepath.Join(t.TempDir(), "Lithe Desktop"))
	if err := store.WriteFile("image.img", []byte("first")); err != nil {
		t.Fatal(err)
	}
	if err := store.WriteFile("image.img", []byte("second")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(store.Path("image.img"))
	if err != nil || string(data) != "second" {
		t.Fatalf("ReadFile = %q, %v; want the second write", data, err)
	}
	entries, err := os.ReadDir(store.Dir())
	if err != nil || len(entries) != 1 {
		t.Fatalf("ReadDir = %d entries, %v; want only the file", len(entries), err)
	}
	if err := store.Remove("image.img"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(store.Path("image.img")); !os.IsNotExist(err) {
		t.Fatalf("the file is still there: %v", err)
	}
	if err := store.Remove("image.img"); err != nil {
		t.Fatalf("Remove of a missing file = %v, want nil", err)
	}
}
