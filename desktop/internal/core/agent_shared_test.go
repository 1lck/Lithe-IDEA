package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestAgentSharedInstructionsFixtureReplay checks the read request and the snapshot shape against
// shared/fixtures/agent/shared-instructions-v1.json. The save and setEnabled requests have no
// recorded fixture, so only their payload shape is covered by the Go type and not replayed here.
func TestAgentSharedInstructionsFixtureReplay(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "shared", "fixtures", "agent", "shared-instructions-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ReadRequest struct {
			Command string          `json:"command"`
			Payload json.RawMessage `json:"payload"`
		} `json:"readRequest"`
		Library AgentSharedInstructions `json:"library"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.ReadRequest.Command != "agent.instructions.shared" {
		t.Fatalf("command = %q", fixture.ReadRequest.Command)
	}
	encoded, err := json.Marshal(sharedReadPayload("/fixture/app-support/AgentInstructions"))
	if err != nil {
		t.Fatal(err)
	}
	var got, want map[string]any
	if err := json.Unmarshal(encoded, &got); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(fixture.ReadRequest.Payload, &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("read payload = %v, want %v", got, want)
	}

	shared := fixture.Library
	if shared.File.AgentID != "shared" || shared.File.Revision != "source-sha256" || shared.File.Content == "" {
		t.Fatalf("shared file = %#v", shared.File)
	}
	if len(shared.Agents) != 2 {
		t.Fatalf("agents = %d", len(shared.Agents))
	}
	codex := shared.Agents[0]
	if codex.AgentID != "codex-acp" || codex.Enabled == nil || !*codex.Enabled || codex.NeedsSync || codex.OwnLineCount != 1 || codex.File == nil {
		t.Fatalf("codex target = %#v", codex)
	}
	claude := shared.Agents[1]
	if claude.AgentID != "claude-acp" || claude.Enabled != nil || claude.File != nil || claude.Issue == nil {
		t.Fatalf("unreadable target must stay unknown, not disabled: %#v", claude)
	}
}
