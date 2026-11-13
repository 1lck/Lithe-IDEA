package core

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func readLifecycleFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture("process-lifecycle/" + name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// TestProcessLifecycleResolveFollowsTheContractFixture replays every exit plan:
// Core decides, the client only carries the records and the decisions.
func TestProcessLifecycleResolveFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Cases []struct {
			Name    string `json:"name"`
			Request struct {
				Context  string          `json:"context"`
				Settings json.RawMessage `json:"settings"`
				Records  []ProcessRecord `json:"records"`
			} `json:"request"`
			Expected ProcessPlan `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(readLifecycleFixture(t, "exit-plan-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	ctx := debugContext(t)
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			got, err := NewClient().ResolveProcessLifecycle(ctx, test.Request.Context, test.Request.Settings, test.Request.Records)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, test.Expected) {
				t.Fatalf("plan = %+v, want %+v", got, test.Expected)
			}
		})
	}
}

// TestProcessLifecycleSettleFollowsTheContractFixture replays every settlement.
func TestProcessLifecycleSettleFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Cases []struct {
			Name    string `json:"name"`
			Request struct {
				Settings  json.RawMessage             `json:"settings"`
				Remember  bool                        `json:"remember"`
				Decisions []ProcessSettlementDecision `json:"decisions"`
				Answers   map[string]string           `json:"answers"`
			} `json:"request"`
			Expected struct {
				Terminate []string        `json:"terminate"`
				Keep      []string        `json:"keep"`
				Settings  json.RawMessage `json:"settings"`
			} `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(readLifecycleFixture(t, "settle-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	ctx := debugContext(t)
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			got, err := NewClient().SettleProcessLifecycle(ctx, test.Request.Settings, test.Request.Decisions, test.Request.Answers, test.Request.Remember)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(nilIfEmpty(got.Terminate), nilIfEmpty(test.Expected.Terminate)) || !reflect.DeepEqual(nilIfEmpty(got.Keep), nilIfEmpty(test.Expected.Keep)) {
				t.Fatalf("settlement = %+v, want %+v", got, test.Expected)
			}
			var gotSettings, wantSettings any
			_ = json.Unmarshal(got.Settings, &gotSettings)
			_ = json.Unmarshal(test.Expected.Settings, &wantSettings)
			if !reflect.DeepEqual(gotSettings, wantSettings) {
				t.Fatalf("settings = %s, want %s", got.Settings, test.Expected.Settings)
			}
		})
	}
}

func nilIfEmpty(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	return values
}
