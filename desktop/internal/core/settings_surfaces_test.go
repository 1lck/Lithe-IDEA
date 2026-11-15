package core

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestSettingsSurfacesSharedVectors(t *testing.T) {
	bytes, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-surfaces.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name, Command, Status string
			Input                 json.RawMessage
			Pages                 *int
			Delivery              any
			RowIDs                []string
			PageOwners            map[string][]string
		}
	}
	if err := json.Unmarshal(bytes, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			var result struct {
				Status   string
				Error    *MarketplaceRejection
				Pages    []SettingsPage
				Delivery any
				Rows     []SettingsNavigationRow
			}
			if err := client.Execute(ctx, test.Command, test.Input, &result); err != nil {
				t.Fatal(err)
			}
			if result.Status != test.Status {
				t.Fatalf("status %s want %s: %+v", result.Status, test.Status, result)
			}
			if test.Pages != nil && len(result.Pages) != *test.Pages {
				t.Fatalf("pages=%+v", result.Pages)
			}
			if test.Delivery != nil && !reflect.DeepEqual(test.Delivery, result.Delivery) {
				t.Fatalf("delivery=%+v want %+v", result.Delivery, test.Delivery)
			}
			for key, want := range test.PageOwners {
				var got []string
				for _, page := range result.Pages {
					if page.Key == key {
						for _, owner := range page.Contributors {
							got = append(got, owner.PluginID)
						}
					}
				}
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("page %s owners=%v want %v", key, got, want)
				}
			}
			if test.RowIDs != nil {
				ids := make([]string, len(result.Rows))
				for i, row := range result.Rows {
					ids[i] = row.ID
				}
				if !reflect.DeepEqual(ids, test.RowIDs) {
					t.Fatalf("rows=%+v", result.Rows)
				}
			}
		})
	}
}
