package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestPluginSettingActionPlansMatchSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/settings-actions.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name         string
			Input        json.RawMessage
			Plan         json.RawMessage
			Error        string
			Confirmation *bool
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/settings/settings.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			var declaration map[string]any
			if err := json.Unmarshal(manifest, &declaration); err != nil {
				t.Fatal(err)
			}
			if test.Confirmation != nil {
				declaration["settingActions"].([]any)[0].(map[string]any)["confirm"] = *test.Confirmation
			}
			var request PluginSettingsActionRequest
			if err := json.Unmarshal(test.Input, &request); err != nil {
				t.Fatal(err)
			}
			request.Manifest, err = json.Marshal(declaration)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			plan, err := NewClient().PlanPluginSettingsAction(ctx, request)
			if test.Error != "" {
				var rejection *MarketplaceRejection
				if !errors.As(err, &rejection) || rejection.Code != test.Error {
					t.Fatalf("rejection: %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			var expected PluginSettingsActionPlan
			if err := json.Unmarshal(test.Plan, &expected); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(plan, expected) {
				t.Fatalf("plan %+v, want %+v", plan, expected)
			}
		})
	}
}
