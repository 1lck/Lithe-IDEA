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
