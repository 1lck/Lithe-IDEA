package workbench

import (
	"encoding/json"
	"testing"

	"github.com/vivaui/viva/gfx"
)

// activityHarness connects a scripted Agent that supports steering and returns
// the session to push events through.
func activityHarness(t *testing.T) (*harness, *fakeAgentSession) {
	t.Helper()
	t.Setenv("FIXTURE_AGENT_KEY", "fixture-secret")
	session := newFakeAgentSession()
	kernel := &fakeAgentKernel{status: installedAgentStatus(), config: fixtureAgentConfiguration(), session: session}
	h := newAgentHarness(t, kernel)
	h.open(t.TempDir())
	h.openAssistant()
	h.agentClick(h.app.text.Agent.Start)
	session.push(map[string]any{"kind": "ready", "canSteer": true})
	h.await("newSession command", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "newSession" {
				return true
			}
		}
		return false
	})
	session.push(map[string]any{"kind": "sessionCreated", "token": "desktop-1", "sessionId": "session-1"})
	h.await("ready session", func() bool {
		p := h.app.project
		return p != nil && p.agent.sessionID == "session-1" && p.agent.phase == agentPhaseReady
	})
	return h, session
}

func update(session string, body map[string]any) map[string]any {
	return map[string]any{"kind": "update", "sessionId": session, "update": body}
}

func TestAgentActivityToolsThoughtsPlanUsageAndCommands(t *testing.T) {
	h, session := activityHarness(t)
	p := h.app.project
	// Session-level updates are accepted while idle: commands and usage.
	session.push(update("session-1", map[string]any{"sessionUpdate": "available_commands_update", "availableCommands": []any{
		map[string]any{"name": "review", "description": "Review", "input": map[string]any{"hint": "focus"}},
		map[string]any{"name": "compact", "description": "Compact"},
	}}))
	session.push(update("session-1", map[string]any{"sessionUpdate": "usage_update", "used": 125300, "size": 300000}))
	h.await("commands and usage", func() bool {
		s := p.agent.activity.current("session-1")
		return len(p.agent.activity.commandsFor("session-1")) == 2 && s != nil && s.usageKnown
	})
	if s := p.agent.activity.current("session-1"); s.used != 125300 || s.size != 300000 {
		t.Fatalf("usage = %d/%d", s.used, s.size)
	}

	h.typePrompt("hello")
	h.await("busy turn", func() bool { return p.agent.phase == agentPhaseBusy })
	session.push(update("session-1", map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "Read the manifest."}}))
	session.push(update("session-1", map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "Run tests", "kind": "execute"}))
	session.push(update("session-1", map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed",
		"content": []any{map[string]any{"type": "content", "content": map[string]any{"type": "text", "text": "1 test passed"}}}}))
	session.push(update("session-1", map[string]any{"sessionUpdate": "plan", "entries": []any{
		map[string]any{"content": "Read", "priority": "high", "status": "completed"},
		map[string]any{"content": "Test", "priority": "medium", "status": "in_progress"},
	}}))
	session.push(update("session-1", map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "Done"}}))
	h.await("rows", func() bool {
		m := p.agent.messages
		return len(m) == 4 && m[3].Text == "Done"
	})
	m := p.agent.messages
	if m[1].Role != agentRoleThought || m[1].Text != "Read the manifest." {
		t.Fatalf("thought row = %#v", m[1])
	}
	if m[2].Role != agentRoleTool || m[2].Tool.Title != "Run tests" || m[2].Tool.Status != "completed" || m[2].Tool.Output != "1 test passed" {
		t.Fatalf("tool row = %#v", m[2].Tool)
	}
	if plan := p.agent.activity.current("session-1").plan; len(plan) != 2 || plan[1].Status != "in_progress" {
		t.Fatalf("plan = %#v", plan)
	}
	// An empty plan clears it.
	session.push(update("session-1", map[string]any{"sessionUpdate": "plan", "entries": []any{}}))
	h.await("plan cleared", func() bool { return len(p.agent.activity.current("session-1").plan) == 0 })
}

func TestAgentActivityStatisticsQuotaSubagentsAndTurnUsage(t *testing.T) {
	h, session := activityHarness(t)
	p := h.app.project
	h.typePrompt("go")
	h.await("busy", func() bool { return p.agent.phase == agentPhaseBusy })

	stats := func(steps uint64) map[string]any {
		return map[string]any{"requests": 1, "steps": steps, "inputTokens": 100, "cacheReadTokens": 10, "outputTokens": 50, "callsWithUsage": 1,
			"context": map[string]any{"toolCount": 3}}
	}
	session.push(map[string]any{"kind": "modelCall", "sessionId": "session-1", "call": map[string]any{"api": "responses"}, "statistics": stats(1)})
	session.push(map[string]any{"kind": "modelCall", "sessionId": "session-1", "call": map[string]any{"api": "responses"}, "statistics": stats(1)})
	// A call without a session is dropped, not guessed.
	session.push(map[string]any{"kind": "modelCall", "call": map[string]any{"api": "responses"}, "statistics": stats(1)})
	session.push(map[string]any{"kind": "quota", "snapshot": map[string]any{"windows": []any{
		map[string]any{"id": "codex:primary", "name": "codex", "limitSeconds": 18000, "usedPercent": 68, "resetsAt": 1800003600}}, "fetchedAt": 1800000000}})
	session.push(update("session-1", map[string]any{"sessionUpdate": "subagent_spawned", "subagentSessionId": "child-1", "name": "Explore", "task": "Inspect"}))
	session.push(update("child-1", map[string]any{"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read README", "status": "in_progress"}))
	session.push(update("child-1", map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "thinking"}}))
	session.push(update("session-1", map[string]any{"sessionUpdate": "subagent_state_update", "subagentSessionId": "child-1", "state": "completed"}))
	session.push(map[string]any{"kind": "turnFinished", "sessionId": "session-1", "usage": map[string]any{"totalTokens": 9, "inputTokens": 4, "outputTokens": 5}})
	h.await("turn finished", func() bool { return p.agent.phase == agentPhaseReady })

	s := p.agent.activity.current("session-1")
	if s.stats.Steps != 2 || s.stats.Input != 200 || s.stats.CacheRead != 20 || s.stats.Context == nil || s.stats.Context.ToolCount != 3 {
		t.Fatalf("stats = %#v", s.stats)
	}
	if len(s.subagents) != 1 || s.subagents[0].State != "completed" || len(s.subagents[0].Tools) != 1 || s.subagents[0].Thought != "thinking" {
		t.Fatalf("subagents = %#v", s.subagents)
	}
	// Child output never enters the root transcript.
	for _, m := range p.agent.messages {
		if m.Role == agentRoleTool || m.Role == agentRoleThought {
			t.Fatalf("a child row leaked into the transcript: %#v", m)
		}
	}
	if s.turnUsage == nil || s.turnUsage.Total != 9 {
		t.Fatalf("turn usage = %#v", s.turnUsage)
	}
	if len(p.agent.activity.quota) != 1 || p.agent.activity.quota[0].UsedPercent != 68 {
		t.Fatalf("quota = %#v", p.agent.activity.quota)
	}
	// With a known quota, a finished turn requests one refresh.
	h.await("quota refresh", func() bool {
		for _, command := range session.commands() {
			if command["kind"] == "refreshQuota" {
				return true
			}
		}
		return false
	})
	session.push(map[string]any{"kind": "quotaFailed", "code": "timeout"})
	h.await("quota failure", func() bool { return p.agent.activity.quotaFailed == "timeout" })
}

func TestAgentSteeringDeliveryOutcomes(t *testing.T) {
	h, session := activityHarness(t)
	p := h.app.project
	h.typePrompt("first")
	h.await("busy", func() bool { return p.agent.phase == agentPhaseBusy })

	p.agent.editor.Insert("focus on login")
	h.app.addAgentFiles(p, []string{"/tmp/a b.txt", "/tmp/a b.txt", "relative.txt"})
	if len(p.agent.files) != 1 || p.agent.files[0].URI != "file:///tmp/a%20b.txt" {
		t.Fatalf("files = %#v", p.agent.files)
	}
	h.app.steerAgent(p)
	var steer map[string]any
	for _, command := range session.commands() {
		if command["kind"] == "steer" {
			steer = command
		}
	}
	if steer == nil || steer["text"] != "focus on login" || steer["files"] == nil {
		t.Fatalf("steer command = %v", steer)
	}
	token, _ := steer["token"].(string)
	last := p.agent.messages[len(p.agent.messages)-1]
	if last.Delivery != agentDeliveryPending || len(p.agent.files) != 0 {
		t.Fatalf("pending row = %#v", last)
	}
	// A second request is refused while one is outstanding.
	p.agent.editor.Insert("again")
	if h.app.agentCanSteer(p) {
		t.Fatal("two supplementary requests were allowed")
	}
	session.push(map[string]any{"kind": "steeringResult", "token": "stale", "sessionId": "session-1", "outcome": "injected"})
	session.push(map[string]any{"kind": "steeringResult", "token": token, "sessionId": "session-1", "outcome": "promptRequired"})
	h.await("queued", func() bool { return p.agent.steer.queued != nil })
	if p.agent.messages[len(p.agent.messages)-1].Delivery != agentDeliveryQueued {
		t.Fatal("promptRequired did not queue the input")
	}
	// The turn ends: the input is sent once as a normal prompt.
	session.push(map[string]any{"kind": "turnFinished", "sessionId": "session-1"})
	h.await("fallback prompt", func() bool {
		n := 0
		for _, command := range session.commands() {
			if command["kind"] == "prompt" && command["text"] == "focus on login" {
				n++
			}
		}
		return n == 1 && p.agent.steer.queued == nil
	})
}

func TestAgentSlashCandidatesAndLimits(t *testing.T) {
	if trigger, query, ok := agentSlashTrigger("、re"); !ok || trigger != '/' || query != "re" {
		t.Fatalf("trigger = %q %q %v", trigger, query, ok)
	}
	if trigger, _, ok := agentSlashTrigger("¥x"); !ok || trigger != '$' {
		t.Fatal("full-width dollar must open the skill list")
	}
	if _, _, ok := agentSlashTrigger("/review now"); ok {
		t.Fatal("a command with arguments must close the list")
	}
	h, session := activityHarness(t)
	p := h.app.project
	session.push(update("session-1", map[string]any{"sessionUpdate": "available_commands_update", "availableCommands": []any{
		map[string]any{"name": "review"}, map[string]any{"name": "compact"}, map[string]any{"name": "preview"}}}))
	h.await("commands", func() bool { return len(p.agent.activity.commandsFor("session-1")) == 3 })
	p.agent.editor.Insert("/re")
	got := h.app.agentSlashCandidates(p)
	if len(got) != 2 || got[0].Name != "review" || got[1].Name != "preview" {
		t.Fatalf("candidates = %#v", got)
	}
	h.app.chooseAgentSlash(p, got[0].Insert)
	if p.agent.editor.CommittedString() != "/review " {
		t.Fatalf("draft = %q", p.agent.editor.CommittedString())
	}
	// The window cap and the launch JSON come from settings.
	h.app.setAgentContextLimits("codex-acp", agentContextLimit{WindowTokens: 200000, AutoCompactTokens: 150000})
	limits := h.app.agentLaunchLimits("codex-acp")
	raw, _ := json.Marshal(limits)
	if string(raw) != `{"autoCompactTokens":150000,"windowTokens":200000}` {
		t.Fatalf("launch limits = %s", raw)
	}
	session.push(update("session-1", map[string]any{"sessionUpdate": "usage_update", "used": 1000, "size": 900000}))
	h.await("capped usage", func() bool {
		s := p.agent.activity.current("session-1")
		return s != nil && s.usageKnown
	})
	if got := p.agent.activity.current("session-1").size; got != 200000 {
		t.Fatalf("displayed capacity = %d", got)
	}
}

func TestAgentArchivedHistoryBrowsesReadOnlyAndRestoresAfterConfirmation(t *testing.T) {
	h, session := activityHarness(t)
	p := h.app.project
	// The harness's ready event does not carry canListArchivedSessions.
	if p.agent.history.archive.canList {
		t.Fatal("archived listing must follow the Agent's capability")
	}
	p.agent.history.archive.canList = true
	h.app.toggleAgentArchived(p)
	var token string
	for _, command := range session.commands() {
		if command["kind"] == "listArchivedSessions" {
			token, _ = command["token"].(string)
		}
	}
	if token == "" {
		t.Fatal("opening the group did not list archived conversations")
	}
	session.push(map[string]any{"kind": "archivedSessions", "token": "stale", "sessions": []any{}, "complete": true})
	session.push(map[string]any{"kind": "archivedSessions", "token": token, "complete": false,
		"sessions": []any{map[string]any{"sessionId": "old-1", "title": "Earlier refactor"}}})
	h.await("archived rows", func() bool { return p.agent.history.archive.loaded })
	s := &p.agent.history.archive
	if len(s.sessions) != 1 || !s.incomplete {
		t.Fatalf("archived = %#v incomplete=%v", s.sessions, s.incomplete)
	}
	// Asking does not restore; only the confirmation sends the command.
	h.app.askAgentUnarchive(p, "old-1")
	for _, command := range session.commands() {
		if command["kind"] == "unarchiveSession" {
			t.Fatal("restore was sent before confirmation")
		}
	}
	h.app.confirmAgentUnarchive(p)
	var restore map[string]any
	for _, command := range session.commands() {
		if command["kind"] == "unarchiveSession" {
			restore = command
		}
	}
	if restore == nil || restore["sessionId"] != "old-1" {
		t.Fatalf("restore command = %v", restore)
	}
	session.push(map[string]any{"kind": "sessionUnarchived", "token": restore["token"], "sessionId": "old-1"})
	h.await("archived list refreshed", func() bool { return s.unarchiveToken == "" && s.confirming == "" })
}

func TestAgentFileDropOnComposerAttachesReferences(t *testing.T) {
	h, session := activityHarness(t)
	p := h.app.project
	for i := 0; i < 3; i++ {
		h.app.invalidator.Invalidate()
		h.settle()
	}
	r := p.agent.composerRect
	if r.Width <= 0 {
		t.Fatal("the composer's rectangle was not recorded")
	}
	// A drop elsewhere is not the composer's.
	outside := h.app.agentFileDrop(gfx.FileDropEvent{Phase: gfx.FileDropDrop, X: 1, Y: 1, Paths: []string{"/tmp/x.txt"}})
	if outside.Handled || len(p.agent.files) != 0 {
		t.Fatal("a drop outside the composer attached a file")
	}
	inside := h.app.agentFileDrop(gfx.FileDropEvent{Phase: gfx.FileDropDrop, X: r.X + 5, Y: r.Y + 5, Paths: []string{"/tmp/x.txt", "/tmp/x.txt", "/tmp/y z.md"}})
	if !inside.Handled || len(p.agent.files) != 2 {
		t.Fatalf("files = %#v", p.agent.files)
	}
	p.agent.editor.Insert("explain")
	h.app.sendAgentPrompt(p)
	var prompt map[string]any
	for _, c := range session.commands() {
		if c["kind"] == "prompt" {
			prompt = c
		}
	}
	files, _ := prompt["files"].([]any)
	if len(files) != 2 || len(p.agent.files) != 0 {
		t.Fatalf("prompt files = %v, draft files = %v", prompt["files"], p.agent.files)
	}
}
