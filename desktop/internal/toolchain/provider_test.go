package toolchain

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"testing"
	"testing/synctest"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func TestToolchainProviderRoundPreservesAnswersAtItsDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		var contacted, timedOut []string
		success := core.ToolchainProviderReply{ID: json.RawMessage(`"ready"`), Response: json.RawMessage(`{"result":{}}`)}
		timeout := core.ToolchainProviderReply{ID: json.RawMessage(`"timeout"`), Response: json.RawMessage(`{"error":{}}`)}
		client := ProviderClient{
			Request: func(query context.Context, _, version string, params core.ToolchainQueryParams) (core.ToolchainProviderReply, error) {
				if version != "1.0.0" {
					t.Fatalf("queried provider version %q", version)
				}
				contacted = append(contacted, params.ProviderID)
				if params.ProviderID == "ready" {
					return success, nil
				}
				<-query.Done()
				return core.ToolchainProviderReply{}, query.Err()
			},
			FailureReply: func(replyContext context.Context, params core.ToolchainQueryParams, code string) (core.ToolchainProviderReply, error) {
				if replyContext.Err() != nil || code != core.ToolchainProviderTimeout {
					t.Fatalf("failure reply context = %v, code = %q", replyContext.Err(), code)
				}
				timedOut = append(timedOut, params.ProviderID)
				return timeout, nil
			},
		}
		planned := core.ToolchainDiscoveryPlanTool{Tool: "fixture", Providers: []string{"test:ready", "test:slow", "test:queued"}}
		round, _, err := client.round(ctx, &workspace{platform: "macos"}, nil, planned, ".", nil, map[string]string{"test": "1.0.0"})
		if err != nil {
			t.Fatal(err)
		}
		if !slices.Equal(contacted, []string{"ready", "slow"}) || !slices.Equal(timedOut, []string{"slow", "queued"}) {
			t.Fatalf("contacted %v, timed out %v", contacted, timedOut)
		}
		if len(round.answers) != 3 || !slices.Equal(round.answers[0].response, success.Response) ||
			!slices.Equal(round.answers[1].response, timeout.Response) || !slices.Equal(round.answers[2].response, timeout.Response) {
			t.Fatalf("round answers = %+v", round.answers)
		}
	})
}

func TestToolchainProviderRoundHonorsCallerDeadline(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		client := ProviderClient{
			Request: func(query context.Context, _, _ string, _ core.ToolchainQueryParams) (core.ToolchainProviderReply, error) {
				<-query.Done()
				return core.ToolchainProviderReply{}, query.Err()
			},
			FailureReply: func(context.Context, core.ToolchainQueryParams, string) (core.ToolchainProviderReply, error) {
				t.Fatal("the caller's deadline was converted into a provider failure")
				return core.ToolchainProviderReply{}, nil
			},
		}
		planned := core.ToolchainDiscoveryPlanTool{Tool: "fixture", Providers: []string{"test:slow"}}
		round, _, err := client.round(ctx, &workspace{platform: "macos"}, nil, planned, ".", nil, map[string]string{"test": "1.0.0"})
		if round != nil || !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("round = %+v, error = %v", round, err)
		}
	})
}
