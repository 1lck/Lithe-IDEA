package workbench

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// agentCore answers the agents commands with canned JSON and records the commands it got.
type agentCore struct {
	mu       sync.Mutex
	answers  map[string]string
	commands []string
}

func (f *agentCore) Execute(_ context.Context, command string, _, result any) error {
	f.mu.Lock()
	f.commands = append(f.commands, command)
	answer := f.answers[command]
	f.mu.Unlock()
	if result == nil {
		return nil
	}
	if answer == "" {
		answer = "{}"
	}
	return json.Unmarshal([]byte(answer), result)
}

func (f *agentCore) count(command string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, got := range f.commands {
		if got == command {
			n++
		}
	}
	return n
}

// liveConversation is a conversation of session in the window's agent tool window.
func liveConversation(session string) *agentConversation {
	return &agentConversation{transcript: agents.NewTranscript(session, "dev.lithe.test.agent", "sample")}
}

func TestApplyAgentBatchAppliesEachEventOnceAndSkipsOtherSessions(t *testing.T) {
	conversation := liveConversation("agent-1")
	v := &agentsState{conversations: []*agentConversation{conversation}, cursorSet: true}
	message := agents.Event{Kind: "message", Turn: 1, Role: "assistant", MessageID: "m1", Text: "hello", Delta: true}
	applyAgentBatch(v, agents.EventBatch{Next: 4, Events: []agents.SessionEvent{
		{Sequence: 3, Session: "agent-1", Event: message},
		{Sequence: 4, Session: "agent-other", Event: message},
	}})
	// A rewound read hands the same event again; it must not be appended twice.
	applyAgentBatch(v, agents.EventBatch{Next: 4, Events: []agents.SessionEvent{{Sequence: 3, Session: "agent-1", Event: message}}})

	if v.cursor != 4 {
		t.Fatalf("cursor = %d, want 4", v.cursor)
	}
	entries := conversation.transcript.Entries
	if len(entries) != 1 || entries[0].Kind != agents.EntryAssistant || entries[0].Text != "hello" {
		t.Fatalf("entries = %+v, want one assistant entry saying hello", entries)
	}
}

func TestApplyAgentBatchMarksMissedAndHonoursARewind(t *testing.T) {
	live := liveConversation("agent-1")
	ended := liveConversation("agent-2")
	ended.transcript.Apply(agents.Event{Kind: "exited", Reason: "closed"})
	v := &agentsState{conversations: []*agentConversation{live, ended}, cursor: 10, cursorSet: true, rewind: 6, rewinding: true}

	applyAgentBatch(v, agents.EventBatch{Next: 12, Missed: true})

	if !live.transcript.Missed || ended.transcript.Missed {
		t.Fatalf("missed = live %v, ended %v; want only the live conversation marked", live.transcript.Missed, ended.transcript.Missed)
	}
	if v.cursor != 6 || v.rewinding {
		t.Fatalf("cursor = %d rewinding = %v, want the probed cursor 6 and no rewind left", v.cursor, v.rewinding)
	}
}

func TestConfigureAgentsSkipsAConfigurationANewerOneOvertook(t *testing.T) {
	core := &agentCore{answers: map[string]string{
		"agents.configure": `{"agents":[{"pluginID":"dev.lithe.test.agent","agentID":"sample","displayName":"Sample","tool":"sample-cli","modes":["native"],"forms":["conversation"],"readsSessions":false,"mayRun":true,"mayReadSessions":false}],"rejected":[]}`,
	}}
	a := &App{agentKernel: agents.NewClient(core)}
	older := a.agentConfigureTicket()
	newer := a.agentConfigureTicket()

	if result := a.configureAgents(context.Background(), pluginservice.InstalledSnapshot{}, newer); result.stale || result.err != nil {
		t.Fatalf("newer configuration = stale %v err %v, want it applied", result.stale, result.err)
	}
	if result := a.configureAgents(context.Background(), pluginservice.InstalledSnapshot{}, older); !result.stale {
		t.Fatal("an older configuration that finished after a newer one must be stale")
	}
	if got := core.count("agents.configure"); got != 1 {
		t.Fatalf("agents.configure sent %d times, want once", got)
	}
}

func TestConfigureAgentsRunsAnOlderConfigurationWhenTheNewerNeverRan(t *testing.T) {
	core := &agentCore{}
	a := &App{agentKernel: agents.NewClient(core)}
	older := a.agentConfigureTicket()
	_ = a.agentConfigureTicket() // A reload that went stale before it configured.

	if result := a.configureAgents(context.Background(), pluginservice.InstalledSnapshot{}, older); result.stale {
		t.Fatal("an older configuration must run while no newer one reached Core")
	}
}

func TestAgentStatusTextShowsStateModelContextTokensAndCost(t *testing.T) {
	conversation := liveConversation("agent-1")
	cost := 1.5
	conversation.transcript.Apply(agents.Event{Kind: "usage", Model: "model-a", ContextUsed: 12_345, ContextWindow: 200_000,
		Tokens: agents.Tokens{Input: 1_000, Output: 500}, CostUSD: &cost})

	got := agentStatusText(i18n.English, conversation)
	want := "Ready · model-a · Context 12.3K/200.0K · Tokens: 1500 · $1.50"
	if got != want {
		t.Fatalf("status = %q, want %q", got, want)
	}

	conversation.busy = true
	if got := agentStatusText(i18n.English, conversation); got[:len("Working")] != "Working" {
		t.Fatalf("status while a request is on its way = %q, want it to start with Working", got)
	}
}

func TestCompactCount(t *testing.T) {
	for count, want := range map[uint64]string{0: "0", 9_999: "9999", 10_000: "10.0K", 123_456: "123.5K", 2_500_000: "2.5M"} {
		if got := compactCount(count); got != want {
			t.Errorf("compactCount(%d) = %q, want %q", count, got, want)
		}
	}
}

func TestLastLines(t *testing.T) {
	for _, tc := range []struct {
		text string
		n    int
		want string
	}{
		{"one", 2, "one"},
		{"a\nb\nc", 2, "b\nc"},
		{"a\nb\nc\n", 2, "b\nc"},
		{"a\nb", 5, "a\nb"},
	} {
		if got := lastLines(tc.text, tc.n); got != tc.want {
			t.Errorf("lastLines(%q, %d) = %q, want %q", tc.text, tc.n, got, tc.want)
		}
	}
}

func TestAgentToolWindowExistsOnlyInALocalWorkspace(t *testing.T) {
	c := newChromeState()
	agentsIndex, portsIndex := c.index[itemAgents], c.index[itemPorts]
	if !c.present(agentsIndex) || c.present(portsIndex) {
		t.Fatalf("local window: agents %v ports %v, want agents only", c.present(agentsIndex), c.present(portsIndex))
	}
	c.setRemote(true)
	if c.present(agentsIndex) || !c.present(portsIndex) {
		t.Fatalf("remote window: agents %v ports %v, want ports only", c.present(agentsIndex), c.present(portsIndex))
	}
}
