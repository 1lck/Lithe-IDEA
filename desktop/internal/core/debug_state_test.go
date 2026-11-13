package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func readDebugFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "debug", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func debugContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// TestDebugVariablePagingFollowsTheContractFixture replays each scenario of the
// shared variable paging fixture through the typed wrappers.
func TestDebugVariablePagingFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Scenarios []struct {
			Name string `json:"name"`
			Plan struct {
				VariablesReference int64  `json:"variablesReference"`
				NamedVariables     int64  `json:"namedVariables"`
				IndexedVariables   int64  `json:"indexedVariables"`
				PageSize           uint32 `json:"pageSize"`
			} `json:"plan"`
			FirstRequest DebugVariablePageRequest `json:"firstRequest"`
			Pages        []struct {
				Page         []DebugVariablePageItem   `json:"page"`
				NewItemCount uint64                    `json:"newItemCount"`
				Accept       bool                      `json:"accept"`
				Next         *DebugVariablePageRequest `json:"next"`
			} `json:"pages"`
		} `json:"scenarios"`
	}
	if err := json.Unmarshal(readDebugFixture(t, "variable-page-plan-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	ctx := debugContext(t)
	client := NewClient()
	for _, scenario := range fixture.Scenarios {
		t.Run(scenario.Name, func(t *testing.T) {
			plan := scenario.Plan
			state, err := client.PlanDebugVariablePage(ctx, plan.VariablesReference, plan.NamedVariables, plan.IndexedVariables, plan.PageSize)
			if err != nil {
				t.Fatal(err)
			}
			if state.Next == nil || !reflect.DeepEqual(*state.Next, scenario.FirstRequest) {
				t.Fatalf("first request = %+v, want %+v", state.Next, scenario.FirstRequest)
			}
			for index, page := range scenario.Pages {
				requested := *state.Next
				accept, next, err := client.ReduceDebugVariablePage(ctx, state, requested, page.Page, page.NewItemCount)
				if err != nil {
					t.Fatalf("page %d: %v", index, err)
				}
				if accept != page.Accept || !reflect.DeepEqual(next.Next, page.Next) {
					t.Fatalf("page %d: accept %v next %+v, want %v %+v", index, accept, next.Next, page.Accept, page.Next)
				}
				state = next
				if state.Next == nil {
					break
				}
			}
		})
	}
}

// TestDebugDisassemblyPagingFollowsTheContractFixture replays every scripted
// request/reply step: the planned or recovery request must equal the fixture's
// request before the reply is reduced.
func TestDebugDisassemblyPagingFollowsTheContractFixture(t *testing.T) {
	type step struct {
		Request  DebugDisassemblyArguments `json:"request"`
		Reply    DebugDisassemblyReply     `json:"reply"`
		Expected DebugDisassemblyStep      `json:"expected"`
	}
	var fixture struct {
		Scenarios []struct {
			Name string `json:"name"`
			Plan struct {
				Direction          string `json:"direction"`
				Reference          string `json:"reference"`
				Count              uint32 `json:"count"`
				InstructionsBefore uint32 `json:"instructionsBefore"`
			} `json:"plan"`
			Known []string `json:"knownAddresses"`
			Steps []step   `json:"steps"`
		} `json:"scenarios"`
	}
	if err := json.Unmarshal(readDebugFixture(t, "disassembly-paging-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	ctx := debugContext(t)
	client := NewClient()
	for _, scenario := range fixture.Scenarios {
		t.Run(scenario.Name, func(t *testing.T) {
			plan := scenario.Plan
			fetch, err := client.PlanDebugDisassemblyWindow(ctx, plan.Direction, plan.Reference, plan.Count, plan.InstructionsBefore)
			if err != nil {
				t.Fatal(err)
			}
			for index, step := range scenario.Steps {
				if fetch.Request != step.Request {
					t.Fatalf("step %d: request = %+v, want %+v", index, fetch.Request, step.Request)
				}
				got, err := client.ReduceDebugDisassemblyPage(ctx, fetch, step.Reply, scenario.Known)
				if err != nil {
					t.Fatalf("step %d: %v", index, err)
				}
				if got.Kind != step.Expected.Kind || got.Exhausted != step.Expected.Exhausted || got.Message != step.Expected.Message ||
					(step.Expected.Keep != nil && !reflect.DeepEqual(got.Keep, step.Expected.Keep)) {
					t.Fatalf("step %d: got %+v, want %+v", index, got, step.Expected)
				}
				if got.Kind == "request" {
					fetch = *got.Fetch
				}
			}
		})
	}
}

// TestDebugTransportLifecycleFollowsTheContractFixture replays each scripted
// byte-stream scenario against a fresh transport and requires Core's exact step.
func TestDebugTransportLifecycleFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Scenarios []struct {
			Name  string `json:"name"`
			Steps []struct {
				Event  DebugTransportEvent `json:"event"`
				Expect DebugTransportStep  `json:"expect"`
			} `json:"steps"`
		} `json:"scenarios"`
	}
	if err := json.Unmarshal(readDebugFixture(t, "transport-lifecycle-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	ctx := debugContext(t)
	client := NewClient()
	for index, scenario := range fixture.Scenarios {
		t.Run(scenario.Name, func(t *testing.T) {
			id := "fixture-" + time.Now().Format("150405.000000") + "-" + string(rune('a'+index%26))
			defer client.DebugTransportRelease(ctx, id)
			for stepIndex, step := range scenario.Steps {
				got, err := client.DebugTransportHandle(ctx, id, step.Event)
				if err != nil {
					t.Fatalf("step %d: %v", stepIndex, err)
				}
				if len(got.Effects) == 0 {
					got.Effects = nil
				}
				want := step.Expect
				if len(want.Effects) == 0 {
					want.Effects = nil
				}
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("step %d: got %+v, want %+v", stepIndex, got, want)
				}
			}
		})
	}
}

func TestDebugStartOrContinueFollowsCore(t *testing.T) {
	ctx := debugContext(t)
	for _, test := range []struct {
		active, paused, pending bool
		want                    DebugStartAction
	}{
		{false, false, false, DebugActionStart},
		{true, true, false, DebugActionContinue},
		{true, false, false, DebugActionNone},
		{true, true, true, DebugActionNone},
	} {
		got, err := NewClient().DebugStartOrContinue(ctx, test.active, test.paused, test.pending)
		if err != nil || got != test.want {
			t.Fatalf("%+v = %q, %v", test, got, err)
		}
	}
}

// TestDebugMemoryWindowFollowsTheContractFixture plans each scenario's window and locates
// each reply through the typed wrappers.
func TestDebugMemoryWindowFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Scenarios []struct {
			Name    string            `json:"name"`
			Address string            `json:"address"`
			Window  DebugMemoryWindow `json:"window"`
			Replies []struct {
				Start    string              `json:"start"`
				Length   uint32              `json:"length"`
				Expected DebugMemoryLocation `json:"expected"`
			} `json:"replies"`
		} `json:"scenarios"`
	}
	if err := json.Unmarshal(readDebugFixture(t, "memory-window-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	ctx := debugContext(t)
	client := NewClient()
	for _, scenario := range fixture.Scenarios {
		t.Run(scenario.Name, func(t *testing.T) {
			window, err := client.PlanDebugMemoryWindow(ctx, scenario.Address)
			if err != nil {
				t.Fatal(err)
			}
			if window != scenario.Window {
				t.Fatalf("window = %+v, want %+v", window, scenario.Window)
			}
			for index, reply := range scenario.Replies {
				got, err := client.LocateDebugMemoryWindow(ctx, window, reply.Start, reply.Length)
				if err != nil {
					t.Fatalf("reply %d: %v", index, err)
				}
				if !reflect.DeepEqual(got, reply.Expected) {
					t.Fatalf("reply %d: got %+v, want %+v", index, got, reply.Expected)
				}
			}
		})
	}
	if _, err := client.PlanDebugMemoryWindow(ctx, "  "); err == nil {
		t.Fatal("a blank address was planned")
	}
}
