package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"
)

func TestPluginSettingsDocumentSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/plugins/settings-documents.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Manifest json.RawMessage `json:"manifest"`
		Cases    []struct {
			Name      string              `json:"name"`
			Scope     string              `json:"scope"`
			Document  *string             `json:"document"`
			Edits     []PluginSettingEdit `json:"edits"`
			Expected  any                 `json:"expected"`
			ErrorCode string              `json:"errorCode"`
			Delete    bool                `json:"delete"`
			Unchanged bool                `json:"unchanged"`
			Effects   []string            `json:"effects"`
		} `json:"editCases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			plan, err := client.EditPluginSettings(ctx, fixture.Manifest, test.Scope, test.Document, test.Edits)
			if test.ErrorCode != "" {
				var rejection *MarketplaceRejection
				if !errors.As(err, &rejection) || rejection.Code != test.ErrorCode {
					t.Fatalf("rejection = %v, want %s", err, test.ErrorCode)
				}
				if plan.Document != "" {
					t.Fatal("rejection exposed a partial replacement")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var document any
			if err := json.Unmarshal([]byte(plan.Document), &document); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(document, test.Expected) || plan.Delete != test.Delete || !reflect.DeepEqual(plan.Effects, test.Effects) {
				t.Fatalf("edit plan differs from shared fixture: %+v", plan)
			}
			if test.Unchanged && (plan.Changed || test.Document == nil || plan.Document != *test.Document) {
				t.Fatal("a semantic no-op rewrote the captured document")
			}
		})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	state, err := client.ReadPluginSettingsState(ctx, fixture.Manifest, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Rows) != 7 || state.Storage.MaximumBytes <= 0 || state.Storage.ProjectRelativePath == "" {
		t.Fatalf("state did not decode its rows and bounded read plan: %+v", state)
	}
	for _, row := range state.Rows {
		if row.Scope == "" || row.Effect == "" || row.Effective.Source != "default" || len(row.Effective.Value) == 0 {
			t.Fatalf("row lost Core's normalized fields: %+v", row)
		}
	}
}
