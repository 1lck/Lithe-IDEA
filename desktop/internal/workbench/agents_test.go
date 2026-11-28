package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/gfx"
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
	}}, time.Time{})
	// A rewound read hands the same event again; it must not be appended twice.
	applyAgentBatch(v, agents.EventBatch{Next: 4, Events: []agents.SessionEvent{{Sequence: 3, Session: "agent-1", Event: message}}}, time.Time{})

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

	applyAgentBatch(v, agents.EventBatch{Next: 12, Missed: true}, time.Time{})

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

func TestPermissionOptionLabelTranslatesKnownKindsAndKeepsTheAgentsOtherwise(t *testing.T) {
	for _, tc := range []struct {
		language i18n.Language
		kind     string
		want     string
	}{
		{i18n.English, "allowOnce", "Allow"},
		{i18n.English, "allowAlways", "Always Allow"},
		{i18n.English, "rejectOnce", "Deny"},
		{i18n.English, "rejectAlways", "Always Deny"},
		{i18n.Chinese, "allowAlways", "总是允许"},
		{i18n.Chinese, "rejectOnce", "拒绝"},
		{i18n.Chinese, "askLater", "Agent wording"},
	} {
		option := agents.PermissionOption{ID: "o", Label: "Agent wording", OptionKind: tc.kind}
		if got := permissionOptionLabel(tc.language, option); got != tc.want {
			t.Errorf("permissionOptionLabel(%v, %q) = %q, want %q", tc.language, tc.kind, got, tc.want)
		}
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

// showAgentConversation opens the Agent tool window of an English window showing conversation.
func showAgentConversation(t *testing.T, conversation *agentConversation) *harness {
	t.Helper()
	h, _ := showAgentConversationWith(t, conversation)
	return h
}

// showAgentConversationWith is showAgentConversation answering from a Core that records what
// the window asks.
func showAgentConversationWith(t *testing.T, conversation *agentConversation) (*harness, *agentCore) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	kernel := &agentCore{}
	h := newHarnessWithOptions(t, Options{
		Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(dir), Languages: []string{"en-US"},
		AgentKernel: agents.NewClient(kernel),
	})
	h.open(t.TempDir())
	v := &h.app.agentsView
	v.catalog = []agents.CatalogAgent{conversation.agent}
	v.configured = true
	v.conversations = []*agentConversation{conversation}
	h.click(center(h.button(itemAgents)))
	h.settle()
	return h, kernel
}

// shownText is where the window drew value.
func (h *harness) shownText(value string) gfx.Rect {
	h.t.Helper()
	for _, text := range h.driver.Snapshot().Texts {
		if text.Value == value {
			return text.Bounds
		}
	}
	h.t.Fatalf("%q is not shown", value)
	return gfx.Rect{}
}

// sampleAgentConversation is a conversation of a synthetic agent with no entries yet.
func sampleAgentConversation() *agentConversation {
	agent := agents.CatalogAgent{PluginID: "dev.lithe.test.agent", AgentID: "sample", DisplayName: "Sample", Forms: []string{"conversation"}, MayRun: true}
	return &agentConversation{agent: agent, transcript: agents.NewTranscript("agent-1", agent.PluginID, agent.AgentID)}
}

// A drag across an agent's reply selects its words and Primary+C copies them.
func TestAgentReplyDragSelectsAndCopies(t *testing.T) {
	conversation := sampleAgentConversation()
	reply := "Summing integer cents keeps every cart exact."
	conversation.transcript.Apply(agents.Event{Kind: "message", Turn: 1, Role: "assistant", MessageID: "m1", Text: reply})
	h := showAgentConversation(t, conversation)

	r := h.pageHit(reply).Bounds
	// The reply may wrap at the tool window's width: the drag ends on its last line.
	h.drag(gfx.Point{X: r.X + 1, Y: r.Y + 4}, gfx.Point{X: r.X + r.Width - 1, Y: r.Y + r.Height - 4})
	h.settle()
	md := conversation.markdown[conversation.transcript.Entries[0].Serial]
	if md == nil {
		t.Fatal("the reply is not drawn as Markdown")
	}
	if got := md.view.SelectedText(md.selection); got != reply {
		t.Fatalf("the drag selected %q, want %q", got, reply)
	}
	if got := h.copyShortcut(); got != reply {
		t.Fatalf("Primary+C copied %q, want %q", got, reply)
	}
}

// Select All in a prompt the user sent takes the prompt only, not the caption naming who spoke.
func TestAgentPromptSelectAllLeavesTheCaptionOut(t *testing.T) {
	conversation := sampleAgentConversation()
	prompt := "Why does the total lose a cent?"
	conversation.transcript.AddPrompt(prompt)
	h := showAgentConversation(t, conversation)

	r := h.shownText(prompt)
	h.drag(gfx.Point{X: r.X + 1, Y: r.Y + r.Height/2}, gfx.Point{X: r.X + r.Width/2, Y: r.Y + r.Height/2})
	h.settle()
	if _, err := h.driver.ShortcutChord(primaryModifier(), 'a'); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if got := h.copyShortcut(); got != prompt {
		t.Fatalf("Select All then Primary+C copied %q, want only the prompt %q", got, prompt)
	}
}

// The selections of entries the transcript dropped to keep its bounds are forgotten.
func TestAgentSelectionsOfDroppedEntriesArePruned(t *testing.T) {
	conversation := liveConversation("agent-1")
	conversation.transcript.AddPrompt("first")
	first := conversation.transcript.Entries[0].Serial
	conversation.selection(first)
	for range agents.MaxEntries {
		conversation.transcript.AddPrompt("more")
	}
	if conversation.transcript.Entries[0].Serial == first {
		t.Fatal("the transcript kept its first entry; the test needs it dropped")
	}
	kept := conversation.transcript.Entries[0].Serial
	conversation.selection(kept)
	conversation.pruneSelections()
	if _, ok := conversation.selections[first]; ok {
		t.Fatal("the selection of a dropped entry was kept")
	}
	if _, ok := conversation.selections[kept]; !ok {
		t.Fatal("the selection of a kept entry was forgotten")
	}
}
