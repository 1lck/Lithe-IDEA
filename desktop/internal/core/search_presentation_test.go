package core

import (
	"context"
	"encoding/json"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"os"
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
