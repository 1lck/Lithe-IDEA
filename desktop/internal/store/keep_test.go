package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// olderSettings is a settings file as an older version knows it: fewer keys than a newer
// version writes.
type olderSettings struct {
	Theme  string            `json:"theme,omitempty"`
	Count  int               `json:"count,omitempty"`
	Editor *olderEditor      `json:"editor,omitempty"`
	Hosts  map[string]olderH `json:"hosts,omitempty"`
	olderEmbedded
}

type olderEditor struct {
	Size int `json:"size,omitempty"`
}

type olderH struct {
	Port int `json:"port,omitempty"`
}

type olderEmbedded struct {
	Shared string `json:"shared,omitempty"`
}

// writeFile puts content in dir/name for a store to load.
func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// readObject decodes dir/name as a JSON object for comparison.
func readObject(t *testing.T, dir, name string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		t.Fatalf("the saved file is not a JSON object: %v\n%s", err, data)
	}
	return object
}

func TestSaveKeepsKeysANewerVersionWrote(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "settings.json", `{
  "theme": "dark",
  "updateChannel": "autobuild",
  "editor": {"size": 13, "ligatures": true},
  "hosts": {"a": {"port": 22, "proxy": "jump"}},
  "shared": "yes"
}`)
	store := At(dir)
	var value olderSettings
	if found, err := store.Load("settings.json", &value); !found || err != nil {
		t.Fatalf("Load = %v, %v", found, err)
	}
	if value.Theme != "dark" || value.Editor == nil || value.Editor.Size != 13 || value.Hosts["a"].Port != 22 || value.Shared != "yes" {
		t.Fatalf("Load = %+v", value)
	}
	if got, want := store.Unknown("settings.json"), []string{"editor.ligatures", "hosts.a.proxy", "updateChannel"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Unknown = %v, want %v", got, want)
	}

	value.Theme = "light"
	if err := store.Save("settings.json", value); err != nil {
		t.Fatal(err)
	}
	saved := readObject(t, dir, "settings.json")
	want := map[string]any{
		"theme":         "light",
		"updateChannel": "autobuild",
		"editor":        map[string]any{"size": float64(13), "ligatures": true},
		"hosts":         map[string]any{"a": map[string]any{"port": float64(22), "proxy": "jump"}},
		"shared":        "yes",
	}
	if !reflect.DeepEqual(saved, want) {
		t.Fatalf("saved %v\nwant  %v", saved, want)
	}
}

func TestSaveDoesNotReviveAKnownKeyThisVersionCleared(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "settings.json", `{"theme": "dark", "editor": {"size": 13, "ligatures": true}, "hosts": {"a": {"proxy": "jump"}}, "later": 1}`)
	store := At(dir)
	var value olderSettings
	if _, err := store.Load("settings.json", &value); err != nil {
		t.Fatal(err)
	}
	// The user clears the theme, removes the editor block and the host: none comes back, and a
	// removed object takes the keys inside it along.
	value.Theme = ""
	value.Editor = nil
	delete(value.Hosts, "a")
	if err := store.Save("settings.json", value); err != nil {
		t.Fatal(err)
	}
	if saved, want := readObject(t, dir, "settings.json"), map[string]any{"later": float64(1)}; !reflect.DeepEqual(saved, want) {
		t.Fatalf("saved %v, want %v", saved, want)
	}
}

func TestLoadKeepsAValueOfAShapeThisVersionCannotRead(t *testing.T) {
	dir := t.TempDir()
	// A newer version turned count into an object; the rest of the file still loads.
	writeFile(t, dir, "settings.json", `{"theme": "dark", "count": {"value": 3}, "editor": {"size": "large"}}`)
	store := At(dir)
	value := olderSettings{Count: 7}
	if found, err := store.Load("settings.json", &value); !found || err != nil {
		t.Fatalf("Load = %v, %v; want the readable keys loaded", found, err)
	}
	if value.Theme != "dark" || value.Count != 7 {
		t.Fatalf("Load = %+v, want the theme read and count left at its default", value)
	}
	if got, want := store.Unknown("settings.json"), []string{"count", "editor.size"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("Unknown = %v, want %v", got, want)
	}

	if err := store.Save("settings.json", value); err != nil {
		t.Fatal(err)
	}
	saved := readObject(t, dir, "settings.json")
	if want := map[string]any{"value": float64(3)}; !reflect.DeepEqual(saved["count"], want) {
		t.Fatalf("count = %v, want the stored %v back", saved["count"], want)
	}
	if want := map[string]any{"size": "large"}; !reflect.DeepEqual(saved["editor"], want) {
		t.Fatalf("editor = %v, want the stored %v back", saved["editor"], want)
	}

	// Once this version sets the field itself, its value wins and stays.
	value.Count = 9
	if err := store.Save("settings.json", value); err != nil {
		t.Fatal(err)
	}
	value.Count = 7
	if err := store.Save("settings.json", value); err != nil {
		t.Fatal(err)
	}
	if saved := readObject(t, dir, "settings.json"); saved["count"] != float64(7) {
		t.Fatalf("count = %v, want this version's 7", saved["count"])
	}
}

func TestSaveWithNothingUnknownWritesTheValueAsBefore(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "settings.json", `{"theme": "dark"}`)
	store := At(dir)
	var value olderSettings
	if _, err := store.Load("settings.json", &value); err != nil {
		t.Fatal(err)
	}
	if unknown := store.Unknown("settings.json"); unknown != nil {
		t.Fatalf("Unknown = %v, want none", unknown)
	}
	if err := store.Save("settings.json", value); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	want, _ := json.MarshalIndent(value, "", "  ")
	if string(data) != string(want)+"\n" {
		t.Fatalf("saved %q, want %q", data, string(want)+"\n")
	}
}

func TestLoadMatchesKeysAsEncodingJSONDoes(t *testing.T) {
	dir := t.TempDir()
	// encoding/json reads "Theme" into the theme field, so it is not unknown.
	writeFile(t, dir, "settings.json", `{"Theme": "dark"}`)
	store := At(dir)
	var value olderSettings
	if _, err := store.Load("settings.json", &value); err != nil {
		t.Fatal(err)
	}
	if value.Theme != "dark" || store.Unknown("settings.json") != nil {
		t.Fatalf("Load = %+v, Unknown = %v", value, store.Unknown("settings.json"))
	}
}
