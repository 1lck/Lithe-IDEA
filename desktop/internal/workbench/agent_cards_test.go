package workbench

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// cardFixtureCase is one case of shared/fixtures/agent/claude-desktop-cards-v1.json:
// what Core presents to the client, in call order.
type cardFixtureCase struct {
	Name      string            `json:"name"`
	Presented []json.RawMessage `json:"presented"`
}

func loadCardFixture(t *testing.T) map[string]cardFixtureCase {
	t.Helper()
	data, err := os.ReadFile("../../../shared/fixtures/agent/claude-desktop-cards-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []cardFixtureCase `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	cases := map[string]cardFixtureCase{}
	for _, c := range fixture.Cases {
		cases[c.Name] = c
	}
	return cases
}

// replayCards applies a case's tool updates as the transcript does and returns
// the tool rows by call id.
func replayCards(t *testing.T, c cardFixtureCase) map[string]*agentToolCall {
	t.Helper()
	a, p := &App{}, &project{}
	var messages []agentMessage
	bytes := 0
	for _, raw := range c.Presented {
		var update agentUpdateWire
		if err := json.Unmarshal(raw, &update); err != nil {
			t.Fatal(err)
		}
		if update.SessionUpdate == "tool_call" || update.SessionUpdate == "tool_call_update" {
			a.applyAgentToolCall(p, update, &messages, &bytes)
		}
	}
	size := 0
	for _, m := range messages {
		size += agentMessageSize(m)
	}
	if size != bytes {
		t.Fatalf("%s: byte budget %d, rows hold %d", c.Name, bytes, size)
	}
	return p.agent.activity.tools
}

func TestAgentCardsDecodeTheSharedFixture(t *testing.T) {
	cases := loadCardFixture(t)
	shown := func(name, id string) *agentCard {
		t.Helper()
		c, ok := cases[name]
		if !ok {
			t.Fatalf("fixture has no case %q", name)
		}
		tool := replayCards(t, c)[id]
		if !agentCardShown(tool) {
			t.Fatalf("%s: tool %q shows no card: %#v", name, id, tool)
		}
		return tool.Card
	}

	if card := shown("chapter", "c"); card.Kind != agentCardChapter || card.Title != "Core" || card.Summary != "Rust first" {
		t.Fatalf("chapter = %#v", card)
	}
	if card := shown("next-step-from-wrap-up", "w#next"); card.Kind != agentCardNextStep || len(card.Actions) != 1 || card.Actions[0] != (agentCardAction{Label: "Yes", Message: "yes"}) {
		t.Fatalf("next step = %#v", card)
	}
	// The withdrawal arrives as a card-only update of the original call and replaces the card.
	if card := shown("task-proposed-then-withdrawn", "t1"); card.Kind != agentCardTask || card.State != "withdrawn" || card.Prompt != "Do it" {
		t.Fatalf("withdrawn task = %#v", card)
	}
	if card := shown("task-handed-off", "h"); card.State != "handedOff" || card.Prompt != "Done: x\nNext: y" {
		t.Fatalf("handed-off task = %#v", card)
	}
	if card := shown("pull-request-monitored", "p"); card.Action != "monitored" || card.Number != 31 || card.AutoFix == nil || !*card.AutoFix {
		t.Fatalf("monitored pull request = %#v", card)
	}
	if card := shown("pull-request-auto-merge", "m"); card.Action != "autoMerge" || card.Enabled == nil || *card.Enabled {
		t.Fatalf("auto-merge pull request = %#v", card)
	}
	if card := shown("directory-requested", "d"); card.Action != "requested" || card.Path != "/w/other" {
		t.Fatalf("directory = %#v", card)
	}
	if card := shown("widget", "v"); card.Kind != agentCardWidget || card.Title != "vcs layers" || card.Code != "<svg/>" {
		t.Fatalf("widget = %#v", card)
	}

	// Calls without a card stay plain rows under the title Core gave them.
	for name, want := range map[string]string{
		"readable-row-without-card":     "Checked the pull request status",
		"unknown-server-passes-through": "mcp__dbx__list_connections",
	} {
		for _, tool := range replayCards(t, cases[name]) {
			if tool.Card != nil || tool.Title != want || tool.Status != "completed" {
				t.Fatalf("%s: row = %#v", name, tool)
			}
		}
	}
}

func TestAgentCardsFallBackToThePlainRow(t *testing.T) {
	meta := func(card string) json.RawMessage {
		return json.RawMessage(`{"lithe":{"claudeDesktop":` + card + `}}`)
	}
	actions := strings.Repeat(`{"label":"a","message":"b"},`, agentCardActionLimit+1)
	for name, card := range map[string]string{
		"unknown kind":           `{"card":"poll","title":"x"}`,
		"chapter without title":  `{"card":"chapter","summary":"x"}`,
		"too many replies":       `{"card":"nextStep","actions":[` + strings.TrimSuffix(actions, ",") + `]}`,
		"reply without message":  `{"card":"nextStep","actions":[{"label":"a"}]}`,
		"unknown task state":     `{"card":"task","title":"x","state":"done"}`,
		"script link":            `{"card":"pullRequest","action":"bound","url":"javascript:alert(1)"}`,
		"relative link":          `{"card":"pullRequest","action":"bound","url":"/o/r/pull/1"}`,
		"auto-merge without bit": `{"card":"pullRequest","action":"autoMerge","url":"https://h/o/r/pull/1"}`,
		"directory without path": `{"card":"directory","action":"changed"}`,
		"not an object":          `"chapter"`,
	} {
		if got := decodeAgentCard(meta(card)); got != nil {
			t.Errorf("%s: decoded %#v", name, got)
		}
	}
	if decodeAgentCard(json.RawMessage(`{"other":{}}`)) != nil || decodeAgentCard(nil) != nil {
		t.Fatal("a _meta without a card decoded one")
	}

	// An oversized visualization keeps its card without the source.
	big := strings.Repeat("x", agentCardWidgetLimit+1)
	card := decodeAgentCard(meta(`{"card":"widget","title":"t","code":"` + big + `"}`))
	if card == nil || card.Code != "" {
		t.Fatalf("oversized widget = %v", card != nil)
	}

	// Only a completed call shows its card, and an update without one keeps it.
	a, p := &App{}, &project{}
	var messages []agentMessage
	bytes := 0
	apply := func(body string) {
		var update agentUpdateWire
		if err := json.Unmarshal([]byte(body), &update); err != nil {
			t.Fatal(err)
		}
		a.applyAgentToolCall(p, update, &messages, &bytes)
	}
	apply(`{"sessionUpdate":"tool_call","toolCallId":"c","title":"Chapter: A","status":"pending","_meta":` + string(meta(`{"card":"chapter","title":"A"}`)) + `}`)
	tool := p.agent.activity.tools["c"]
	if agentCardShown(tool) {
		t.Fatal("a pending call shows its card")
	}
	apply(`{"sessionUpdate":"tool_call_update","toolCallId":"c","status":"failed"}`)
	if agentCardShown(tool) || tool.Card == nil {
		t.Fatalf("failed call: shown %v, card %v", agentCardShown(tool), tool.Card)
	}
	apply(`{"sessionUpdate":"tool_call_update","toolCallId":"c","status":"completed"}`)
	if !agentCardShown(tool) || tool.Card.Title != "A" {
		t.Fatalf("completed call card = %#v", tool.Card)
	}
}

func TestAgentCardReplyFillsTheComposerWithoutSending(t *testing.T) {
	h, session := activityHarness(t)
	p := h.app.project
	h.typePrompt("draft")
	h.await("busy turn", func() bool { return p.agent.phase == agentPhaseBusy })
	session.push(update("session-1", map[string]any{"sessionUpdate": "tool_call", "toolCallId": "w#next", "title": "Suggested replies", "kind": "other", "status": "completed",
		"_meta": map[string]any{"lithe": map[string]any{"claudeDesktop": map[string]any{"card": "nextStep", "actions": []any{
			map[string]any{"label": "Mark ready", "message": "Mark the pull request ready"},
		}}}}}))
	session.push(map[string]any{"kind": "turnFinished", "sessionId": "session-1", "stopReason": "end_turn"})
	h.await("reply card", func() bool {
		_, ok := h.agentHit("Mark ready")
		return ok && p.agent.phase == agentPhaseReady
	})
	prompts := func() int {
		n := 0
		for _, command := range session.commands() {
			if command["kind"] == "prompt" {
				n++
			}
		}
		return n
	}
	before := prompts()
	h.agentClick("Mark ready")
	h.await("filled composer", func() bool { return p.agent.editor.String() == "Mark the pull request ready" })
	if after := prompts(); after != before {
		t.Fatalf("a card reply sent %d prompts", after-before)
	}

	// The replies answer only the latest turn: the next one hides them.
	h.typePrompt(" now")
	h.await("next turn", func() bool { return p.agent.phase == agentPhaseBusy })
	h.await("replies hidden", func() bool {
		_, ok := h.agentHit("Mark ready")
		return !ok
	})
}

func TestAgentTaskCardStartsANewConversationWithItsPrompt(t *testing.T) {
	h, session := activityHarness(t)
	p := h.app.project
	h.typePrompt("plan")
	h.await("busy turn", func() bool { return p.agent.phase == agentPhaseBusy })
	session.push(update("session-1", map[string]any{"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Suggested task: Fix", "kind": "other", "status": "completed",
		"_meta": map[string]any{"lithe": map[string]any{"claudeDesktop": map[string]any{"card": "task", "title": "Fix login", "prompt": "Fix the login redirect", "state": "proposed"}}}}))
	session.push(map[string]any{"kind": "turnFinished", "sessionId": "session-1", "stopReason": "end_turn"})
	start := h.app.text.Agent.Card.StartTask
	h.await("task card", func() bool {
		_, ok := h.agentHit(start)
		return ok && p.agent.phase == agentPhaseReady
	})
	newSessions := func() int {
		n := 0
		for _, command := range session.commands() {
			if command["kind"] == "newSession" {
				n++
			}
		}
		return n
	}
	before := newSessions()
	h.agentClick(start)
	h.await("new session requested", func() bool { return newSessions() == before+1 })
	if got := p.agent.editor.String(); got != "Fix the login redirect" {
		t.Fatalf("composer = %q", got)
	}
	for _, command := range session.commands() {
		if command["kind"] == "prompt" && command["text"] == "Fix the login redirect" {
			t.Fatal("starting a task sent its prompt")
		}
	}
}
