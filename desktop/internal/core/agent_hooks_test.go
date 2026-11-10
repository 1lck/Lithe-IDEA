package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// fixture reads one shared agent fixture as raw JSON.
func agentFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "agent", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// requestShape decodes raw JSON into a general map for payload comparisons.
func requestShape(t *testing.T, raw []byte) map[string]any {
	t.Helper()
	var shape map[string]any
	if err := json.Unmarshal(raw, &shape); err != nil {
		t.Fatal(err)
	}
	return shape
}

func marshalShape(t *testing.T, value any) map[string]any {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return requestShape(t, raw)
}

// TestAgentHooksFixtureReplay checks the read request and library shape against
// shared/fixtures/agent/hooks-management-v1.json, and the save, remove and sync requests
// against the same file's data directory and guards.
func TestAgentHooksFixtureReplay(t *testing.T) {
	var fixture struct {
		Command     string           `json:"command"`
		ReadRequest json.RawMessage  `json:"readRequest"`
		Hook        AgentHook        `json:"hook"`
		Library     AgentHookLibrary `json:"library"`
	}
	if err := json.Unmarshal(agentFixture(t, "hooks-management-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Command != "agent.hooks" {
		t.Fatalf("command = %q", fixture.Command)
	}
	if got, want := marshalShape(t, agentHooksRequest{DataDirectory: "/fixture/library", Action: "read"}), requestShape(t, fixture.ReadRequest); !reflect.DeepEqual(got, want) {
		t.Fatalf("read request = %v, want %v", got, want)
	}

	hook := fixture.Hook
	if hook.ID != "00000000-0000-4000-8000-000000000001" || hook.Name != "notify" ||
		hook.Event != "turn-end" || hook.Matcher != "all" || hook.Command != "printf done" ||
		hook.TimeoutSeconds != nil || !hook.Enabled || hook.PendingRemoval ||
		!reflect.DeepEqual(hook.Agents, []string{"codex-acp", "claude-acp"}) {
		t.Fatalf("hook = %#v", hook)
	}
	library := fixture.Library
	if library.Revision != "fixture-library-revision" || len(library.Hooks) != 1 || len(library.Targets) != 2 {
		t.Fatalf("library = %#v", library)
	}
	stored := library.Hooks[0]
	if !stored.NeedsSync || !reflect.DeepEqual(stored.ConfiguredAgents, []string{"codex-acp"}) {
		t.Fatalf("stored hook = %#v", stored)
	}
	codex, claude := library.Targets[0], library.Targets[1]
	if codex.AgentID != "codex-acp" || codex.File == nil || codex.File.Path != "/fixture/.codex/hooks.json" ||
		codex.File.Revision != "codex-revision" || codex.Issue != nil {
		t.Fatalf("codex target = %#v", codex)
	}
	if claude.AgentID != "claude-acp" || claude.File != nil || claude.Issue == nil {
		t.Fatalf("claude target = %#v", claude)
	}

	guards := []AgentFileGuard{{AgentID: "codex-acp", Path: "/fixture/.codex/hooks.json", Revision: "codex-revision"}}
	for name, got := range map[string]map[string]any{
		"save": marshalShape(t, agentHooksRequest{
			DataDirectory: "/fixture/library", Action: "save", ExpectedRevision: "fixture-library-revision",
			Files: guards, Hook: &hook,
		}),
		"remove": marshalShape(t, agentHooksRequest{
			DataDirectory: "/fixture/library", Action: "remove", ExpectedRevision: "fixture-library-revision",
			Files: guards, ID: hook.ID,
		}),
		"sync": marshalShape(t, agentHooksRequest{
			DataDirectory: "/fixture/library", Action: "sync", ExpectedRevision: "fixture-library-revision",
			Files: guards,
		}),
	} {
		if got["action"] != name || got["dataDirectory"] != "/fixture/library" || got["expectedRevision"] != "fixture-library-revision" {
			t.Fatalf("%s request = %v", name, got)
		}
		if _, ok := got["files"]; !ok {
			t.Fatalf("%s request has no guards: %v", name, got)
		}
	}
}

// TestAgentHookDraftValidationFixtureReplay checks that every case of
// shared/fixtures/agent/hook-draft-validation-v1.json decodes into the Go request and
// response types, including the optional timeout.
func TestAgentHookDraftValidationFixtureReplay(t *testing.T) {
	var fixture struct {
		Command string `json:"command"`
		Cases   []struct {
			Name     string          `json:"name"`
			Request  json.RawMessage `json:"request"`
			Expected json.RawMessage `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(agentFixture(t, "hook-draft-validation-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Command != "agent.hooks.validateDraft" || len(fixture.Cases) == 0 {
		t.Fatalf("fixture = %#v", fixture)
	}
	for _, test := range fixture.Cases {
		var request struct {
			Hook          AgentHookDraft `json:"hook"`
			ExistingHooks []AgentHookRef `json:"existingHooks"`
		}
		if err := json.Unmarshal(test.Request, &request); err != nil {
			t.Fatalf("%s: request: %v", test.Name, err)
		}
		var expected AgentHookValidation
		if err := json.Unmarshal(test.Expected, &expected); err != nil {
			t.Fatalf("%s: expected: %v", test.Name, err)
		}
		// The cases include deliberately invalid drafts, so the test only proves that the
		// fixture decodes into the request and response types; the rules live in Core.
		if !reflect.DeepEqual(marshalShape(t, expected), requestShape(t, test.Expected)) {
			t.Fatalf("%s: validation round trip = %v", test.Name, expected)
		}
	}
}
