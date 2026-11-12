package core

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// TestDecodeRunStartFollowsTheContractFixture replays every start of the shared
// fixture: the normalized start for the accepted ones, and Core's code and field
// for each refusal.
func TestDecodeRunStartFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Manifest             string   `json:"manifest"`
		WorkspaceDirectories []string `json:"workspaceDirectories"`
		Cases                []struct {
			Name   string          `json:"name"`
			Params json.RawMessage `json:"params"`
			Start  json.RawMessage `json:"start"`
			Error  *struct {
				Code  string `json:"code"`
				Field string `json:"field"`
			} `json:"error"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(readRunFixture(t, "run-start.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	manifest := readRunFixture(t, fixture.Manifest)
	workspace := t.TempDir()
	for _, directory := range fixture.WorkspaceDirectories {
		if err := os.MkdirAll(filepath.Join(workspace, directory), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			start, err := NewClient().DecodeRunStart(ctx, manifest, workspace, t.TempDir(), test.Params)
			if test.Error != nil {
				var rejection *MarketplaceRejection
				if !errors.As(err, &rejection) {
					t.Fatalf("err = %v, want a rejection", err)
				}
				if rejection.Code != test.Error.Code || rejection.Field != test.Error.Field {
					t.Fatalf("rejection = %s at %s, want %s at %s", rejection.Code, rejection.Field, test.Error.Code, test.Error.Field)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			got, _ := json.Marshal(start)
			var gotValue, wantValue map[string]any
			if err := json.Unmarshal(got, &gotValue); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(test.Start, &wantValue); err != nil {
				t.Fatal(err)
			}
			// The client's struct always carries the optional members; compare
			// only what the fixture states.
			for key, want := range wantValue {
				gotJSON, _ := json.Marshal(gotValue[key])
				wantJSON, _ := json.Marshal(want)
				if string(gotJSON) != string(wantJSON) {
					t.Errorf("%s = %s, want %s", key, gotJSON, wantJSON)
				}
			}
		})
	}
}

func TestDebugTransportPolicyOutlastsTheConnect(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	policy, err := NewClient().DebugTransportPolicy(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if policy.Limits.DiscoveryMilliseconds <= 0 || policy.Limits.ConnectMilliseconds <= 0 || policy.Limits.WriteMilliseconds <= 0 {
		t.Fatalf("limits = %+v, want positive deadlines", policy.Limits)
	}
	if policy.InitializationMilliseconds <= policy.Limits.ConnectMilliseconds {
		t.Fatalf("initialization %d must outlast connect %d", policy.InitializationMilliseconds, policy.Limits.ConnectMilliseconds)
	}
}

// TestDecodeDebugBackendConfigurationFollowsTheContractFixture replays every
// debug/start case of the shared fixture.
func TestDecodeDebugBackendConfigurationFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Manifest string `json:"manifest"`
		Cases    []struct {
			Name   string          `json:"name"`
			Params json.RawMessage `json:"params"`
			Start  json.RawMessage `json:"start"`
			Error  *struct {
				Code  string `json:"code"`
				Field string `json:"field"`
			} `json:"error"`
		} `json:"cases"`
	}
	path := contractfixture.Path("fixtures/debug-adapters")
	raw, err := os.ReadFile(filepath.Join(path, "debug-start.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	manifest, err := os.ReadFile(filepath.Join(path, fixture.Manifest))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			start, err := NewClient().DecodeDebugBackendConfiguration(ctx, manifest, test.Params)
			if test.Error != nil {
				var rejection *MarketplaceRejection
				if !errors.As(err, &rejection) || rejection.Code != test.Error.Code || rejection.Field != test.Error.Field {
					t.Fatalf("err = %v, want %s at %s", err, test.Error.Code, test.Error.Field)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			gotJSON, _ := json.Marshal(start)
			var got, want map[string]any
			_ = json.Unmarshal(gotJSON, &got)
			_ = json.Unmarshal(test.Start, &want)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("start = %s, want %s", gotJSON, test.Start)
			}
		})
	}
}
