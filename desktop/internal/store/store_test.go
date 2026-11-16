package store

import (
	"bytes"
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


func TestFailedLoadPreservesOriginalSettingsAcrossSave(t *testing.T) {
	dir := t.TempDir()
	filename := filepath.Join(dir, "settings.json")
	original := []byte("{\"name\":\"keep me\",\"count\":12,}")
	if err := os.WriteFile(filename, original, 0o600); err != nil {
		t.Fatal(err)
	}
	store := At(dir)
	value := sample{Name: "default"}
	if found, err := store.Load("settings.json", &value); !found || err == nil {
		t.Fatalf("Load = %v, %v; want existing but undecodable", found, err)
	}
	if err := store.Save("settings.json", sample{Name: "changed"}); err == nil {
		t.Fatal("Save overwrote a file that Load could not decode")
	}
	after, err := os.ReadFile(filename)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(after, original) {
		t.Fatalf("failed Load lost original settings: %q", after)
	}
	if err := store.Save("recent-projects.json", []string{"a"}); err != nil {
		t.Fatalf("Save of an unrelated file: %v", err)
	}
	if err := os.WriteFile(filename, []byte("{\"name\":\"restored\",\"count\":12}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if found, err := store.Load("settings.json", &value); !found || err != nil {
		t.Fatalf("Load after repair = %v, %v", found, err)
	}
	if value.Name != "restored" || value.Count != 12 {
		t.Fatalf("Load after repair = %+v", value)
	}
	if err := store.Save("settings.json", sample{Name: "updated", Count: 12}); err != nil {
		t.Fatalf("Save after repair: %v", err)
	}
}

func TestFailedLoadProtectionClearsWhenOriginalIsRemoved(t *testing.T) {
	dir := t.TempDir()
	filename := filepath.Join(dir, "settings.json")
	if err := os.WriteFile(filename, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	store := At(dir)
	var value sample
	if _, err := store.Load("settings.json", &value); err == nil {
		t.Fatal("want a failed Load")
	}
	if err := store.Remove("settings.json"); err != nil {
		t.Fatal(err)
	}
	if err := store.Save("settings.json", sample{Name: "new"}); err != nil {
		t.Fatalf("Save after explicit removal: %v", err)
	}
	if err := os.WriteFile(filename, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Load("settings.json", &value); err == nil {
		t.Fatal("want a failed Load again")
	}
	if err := os.Remove(filename); err != nil {
		t.Fatal(err)
	}
	if found, err := store.Load("settings.json", &value); found || err != nil {
		t.Fatalf("Load of missing file = %v, %v", found, err)
	}
	if err := store.Save("settings.json", sample{Name: "recreated"}); err != nil {
		t.Fatalf("Save after external removal: %v", err)
	}
}
