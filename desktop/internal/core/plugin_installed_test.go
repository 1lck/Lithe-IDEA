package core

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"
)

func TestInstalledPluginVersionSelectionMatchesSharedCoreFixture(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/plugins/installed-versions.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name            string                     `json:"name"`
			Entries         []InstalledPluginFact      `json:"entries"`
			IncludeDisabled bool                       `json:"includeDisabled"`
			Selected        []int                      `json:"selected"`
			Rejected        []InstalledPluginRejection `json:"rejected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			result, err := client.SelectInstalledPluginVersions(ctx, test.Entries, test.IncludeDisabled)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(result.Selected, test.Selected) || !reflect.DeepEqual(result.Rejected, test.Rejected) || result.MaximumEntries <= 0 {
				t.Fatalf("installed selection differs from Core fixture: %+v", result)
			}
		})
	}
}
