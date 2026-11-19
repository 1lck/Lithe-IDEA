package core

import (
	"context"
	"encoding/json"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestSearchPreferencesAndPresentationSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("search/idea-search-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Preferences []struct {
			Request  StoredSearchPreferences
			Expected SearchPreferences
		}
		Presentation struct {
			Request  struct{ Paths, Collapsed []string }
			Expected SearchPresentation
		}
	}
	if err = json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client := NewClient()
	for _, item := range fixture.Preferences {
		got, err := client.ResolveSearchPreferences(ctx, item.Request.MaxFileBytes, item.Request.ReplacementMaxFileBytes)
		if err != nil || got != item.Expected {
			t.Fatalf("preferences %+v: %v", got, err)
		}
	}
	got, err := client.SearchPresentation(ctx, fixture.Presentation.Request.Paths, fixture.Presentation.Request.Collapsed)
	if err != nil || !reflect.DeepEqual(got, fixture.Presentation.Expected) {
		t.Fatalf("presentation %+v: %v", got, err)
	}
}

func TestSearchCountsAndLanguageDiscoverySharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("search/idea-search-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture map[string]json.RawMessage
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"completeCounts", "languageDiscovery"} {
		t.Run(name, func(t *testing.T) {
			var item struct {
				Files    map[string]string
				Request  json.RawMessage
				Expected json.RawMessage
			}
			if err := json.Unmarshal(fixture[name], &item); err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			for path, text := range item.Files {
				file := filepath.Join(root, filepath.FromSlash(path))
				if err := os.MkdirAll(filepath.Dir(file), 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(file, []byte(text), 0600); err != nil {
					t.Fatal(err)
				}
			}
			var request map[string]any
			if err := json.Unmarshal(item.Request, &request); err != nil {
				t.Fatal(err)
			}
			request["root"] = root
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			var got, want any
			if err := NewClient().Execute(ctx, "workspace.search", request, &got); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(item.Expected, &want); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("got %+v, want %+v", got, want)
			}
		})
	}
}
