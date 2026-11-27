package agents

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

// fakeCore records each command and payload and answers with a canned JSON value.
type fakeCore struct {
	answers  map[string]string
	commands []string
	payloads []string
}

func (f *fakeCore) Execute(_ context.Context, command string, payload, result any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	f.commands = append(f.commands, command)
	f.payloads = append(f.payloads, string(data))
	if result == nil {
		return nil
	}
	answer := f.answers[command]
	if answer == "" {
		answer = "{}"
	}
	return json.Unmarshal([]byte(answer), result)
}

func TestClientSendsCommandsAndDecodesAnswers(t *testing.T) {
	core := &fakeCore{answers: map[string]string{
		"agents.configure":    `{"agents":[{"pluginID":"dev.lithe.test.agent","agentID":"sample","displayName":"Sample","tool":"sample-cli","modes":["native"],"forms":["conversation","terminal"],"readsSessions":true,"mayRun":true,"mayReadSessions":false,"terminalArguments":[],"update":{"arguments":["update"]}}],"rejected":[{"pluginID":"dev.lithe.test.bad","code":"agents.invalidManifest","message":"bad"}]}`,
		"agents.start":        `{"session":"agent-1","mode":"native"}`,
		"agents.prompt":       `{"turn":3}`,
		"agents.waitEvents":   `{"events":[{"sequence":7,"session":"agent-1","event":{"kind":"message","turn":3,"role":"assistant","messageID":"m1","text":"hi","delta":true}}],"next":7,"missed":false}`,
		"agentSessions.stats": `{"summaries":[{"key":{"kind":"model","model":"m"},"calls":2,"failedCalls":0,"compactionCalls":0,"tokens":{"input":10,"output":5,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0,"reasoning":0},"firstStartedAtMs":1,"lastStartedAtMs":2}],"rateLimits":[{"atMs":5,"windows":[{"id":"primary","usedPercent":40}],"pluginID":"dev.lithe.test.agent","agentID":"sample"}]}`,
	}}
	client := NewClient(core)
	ctx := context.Background()

	configured, err := client.Configure(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(configured.Agents) != 1 || configured.Agents[0].Key() != "dev.lithe.test.agent/sample" {
		t.Fatalf("agents = %+v", configured.Agents)
	}
	agent := configured.Agents[0]
	if !agent.HasMode("native") || !agent.HasForm("terminal") || agent.Update == nil || agent.Update.Arguments[0] != "update" {
		t.Fatalf("agent = %+v", agent)
	}
	if len(configured.Rejected) != 1 || configured.Rejected[0].Code != "agents.invalidManifest" {
		t.Fatalf("rejected = %+v", configured.Rejected)
	}
	if core.payloads[0] != `{"plugins":[]}` {
		t.Fatalf("configure payload = %s", core.payloads[0])
	}

	session, err := client.Start(ctx, StartRequest{PluginID: "dev.lithe.test.agent", AgentID: "sample", Cwd: "/w", ToolPath: "/bin/sample-cli", WorkspaceTrusted: true})
	if err != nil || session != "agent-1" {
		t.Fatalf("start = %q, %v", session, err)
	}
	if !strings.Contains(core.payloads[1], `"environment":{}`) || strings.Contains(core.payloads[1], "resume") {
		t.Fatalf("start payload = %s", core.payloads[1])
	}

	turn, err := client.Prompt(ctx, session, "hello")
	if err != nil || turn != 3 {
		t.Fatalf("prompt = %d, %v", turn, err)
	}

	batch, err := client.WaitEvents(ctx, 6, time.Minute, 0)
	if err != nil {
		t.Fatal(err)
	}
	if core.payloads[3] != `{"after":6,"timeoutMilliseconds":30000}` {
		t.Fatalf("wait payload = %s", core.payloads[3])
	}
	if batch.Next != 7 || len(batch.Events) != 1 || batch.Events[0].Event.Text != "hi" || !batch.Events[0].Event.Delta {
		t.Fatalf("batch = %+v", batch)
	}

	if err := client.Close(ctx, session); err != nil {
		t.Fatal(err)
	}

	stats, err := client.Stats(ctx, StatsQuery{GroupBy: "model"})
	if err != nil {
		t.Fatal(err)
	}
	if len(stats.Summaries) != 1 || stats.Summaries[0].Key.Model != "m" || stats.Summaries[0].Tokens.Total() != 15 {
		t.Fatalf("summaries = %+v", stats.Summaries)
	}
	if len(stats.RateLimits) != 1 || stats.RateLimits[0].Windows[0].UsedPercent != 40 {
		t.Fatalf("rate limits = %+v", stats.RateLimits)
	}

	want := []string{"agents.configure", "agents.start", "agents.prompt", "agents.waitEvents", "agents.close", "agentSessions.stats"}
	if strings.Join(core.commands, ",") != strings.Join(want, ",") {
		t.Fatalf("commands = %v", core.commands)
	}
}

func TestTranscriptFoldsEvents(t *testing.T) {
	transcript := NewTranscript("agent-1", "dev.lithe.test.agent", "sample")
	transcript.Apply(Event{Kind: "session", AgentSessionID: "s-1", Model: "m"})
	transcript.AddPrompt("question")
	transcript.Apply(Event{Kind: "turnStarted", Turn: 1})
	transcript.Apply(Event{Kind: "message", Turn: 1, Role: "thought", MessageID: "t1", Text: "thinking"})
	transcript.Apply(Event{Kind: "message", Turn: 1, Role: "assistant", MessageID: "a1", Text: "Hel", Delta: true})
	transcript.Apply(Event{Kind: "message", Turn: 1, Role: "assistant", MessageID: "a1", Text: "lo", Delta: true})
	transcript.Apply(Event{Kind: "toolCall", Turn: 1, ToolCallID: "c1", Status: "pending", ToolKind: "execute", Title: "ls"})
	// Core's answer to the prompt can be applied after the turn's first replies.
	transcript.PromptAccepted(1)
	if transcript.Entries[0].Kind != EntryUser || transcript.Entries[0].Turn != 1 {
		t.Fatalf("prompt = %+v", transcript.Entries[0])
	}
	transcript.Apply(Event{Kind: "permissionRequested", Turn: 1, Permission: "p1", Title: "Run ls?", ToolCallID: "c1", Options: []PermissionOption{{ID: "allow", Label: "Allow", OptionKind: "allowOnce"}}})
	if len(transcript.Pending) != 1 {
		t.Fatalf("pending = %+v", transcript.Pending)
	}
	transcript.Apply(Event{Kind: "permissionDecided", Turn: 1, Permission: "p1", Option: "allow"})
	transcript.Apply(Event{Kind: "toolCall", Turn: 1, ToolCallID: "c1", Status: "completed", Output: "a\nb"})
	transcript.Apply(Event{Kind: "usage", Turn: 1, Tokens: Tokens{Input: 4, Output: 2}, ContextUsed: 6, ContextWindow: 100})
	transcript.Apply(Event{Kind: "turnEnded", Turn: 1, Reason: "completed"})

	if transcript.AgentSessionID != "s-1" || transcript.ActiveTurn != 0 || len(transcript.Pending) != 0 {
		t.Fatalf("state = %+v", transcript)
	}
	kinds := []EntryKind{EntryUser, EntryThought, EntryAssistant, EntryTool}
	if len(transcript.Entries) != len(kinds) {
		t.Fatalf("entries = %+v", transcript.Entries)
	}
	for at, kind := range kinds {
		if transcript.Entries[at].Kind != kind {
			t.Fatalf("entry %d = %+v", at, transcript.Entries[at])
		}
	}
	if transcript.Entries[2].Text != "Hello" {
		t.Fatalf("assistant = %q", transcript.Entries[2].Text)
	}
	tool := transcript.Entries[3]
	if tool.Status != "completed" || tool.Title != "ls" || tool.Output != "a\nb" || tool.ToolKind != "execute" {
		t.Fatalf("tool = %+v", tool)
	}
	if transcript.Usage == nil || transcript.Usage.Model != "m" || transcript.Usage.ContextWindow != 100 {
		t.Fatalf("usage = %+v", transcript.Usage)
	}

	transcript.Apply(Event{Kind: "turnEnded", Turn: 2, Reason: "cancelled"})
	last := transcript.Entries[len(transcript.Entries)-1]
	if last.Kind != EntryNotice || last.Code != "cancelled" {
		t.Fatalf("notice = %+v", last)
	}
	entries := len(transcript.Entries)
	transcript.AddPrompt("refused")
	if text := transcript.PromptRefused(); text != "refused" || len(transcript.Entries) != entries {
		t.Fatalf("refused prompt = %q, entries = %d", text, len(transcript.Entries))
	}
	code := 0
	transcript.Apply(Event{Kind: "exited", Reason: "closed", ExitCode: &code})
	if transcript.Live() || transcript.Exit.Reason != "closed" {
		t.Fatalf("exit = %+v", transcript.Exit)
	}
}

func TestTranscriptStaysBounded(t *testing.T) {
	transcript := NewTranscript("agent-1", "p", "a")
	for turn := uint64(1); turn <= MaxEntries+100; turn++ {
		transcript.AddPrompt("q")
		transcript.PromptAccepted(turn)
	}
	if len(transcript.Entries) > MaxEntries || transcript.Dropped == 0 {
		t.Fatalf("entries = %d, dropped = %d", len(transcript.Entries), transcript.Dropped)
	}

	big := strings.Repeat("é", MaxEntryBytes)
	transcript.Apply(Event{Kind: "message", Turn: 1, Role: "assistant", MessageID: "big", Text: big})
	transcript.Apply(Event{Kind: "message", Turn: 1, Role: "assistant", MessageID: "big", Text: big, Delta: true})
	last := transcript.Entries[len(transcript.Entries)-1]
	if len(last.Text) > MaxEntryBytes || !strings.HasPrefix(last.Text, "é") || strings.ContainsRune(last.Text, '�') {
		t.Fatalf("text = %d bytes", len(last.Text))
	}
	for range 40 {
		transcript.Apply(Event{Kind: "toolCall", Turn: 1, ToolCallID: "c", Status: "inProgress", Output: big})
	}
	if transcript.bytes > MaxTotalBytes {
		t.Fatalf("bytes = %d", transcript.bytes)
	}
	tool := transcript.Entries[len(transcript.Entries)-1]
	if tool.Kind != EntryTool || len(tool.Output) > MaxOutputBytes {
		t.Fatalf("tool = %d bytes", len(tool.Output))
	}
}

func TestGrantedPermissionsWithholdSessionsUntilConsent(t *testing.T) {
	manifest := []string{PermissionRun, PermissionNative, PermissionReadSessions, "ui.contribute", PermissionRun}
	if got := GrantedPermissions(manifest, false); strings.Join(got, ",") != "agents.run,agents.native,ui.contribute" {
		t.Fatalf("without consent = %v", got)
	}
	if got := GrantedPermissions(manifest, true); strings.Join(got, ",") != "agents.run,agents.native,agents.sessions.read,ui.contribute" {
		t.Fatalf("with consent = %v", got)
	}
	consent := Consent{"dev.lithe.test.agent": true, "dev.lithe.test.other": false}
	if !consent.Plugin("dev.lithe.test.agent") || consent.Plugin("dev.lithe.test.other") || consent.Plugin("dev.lithe.test") {
		t.Fatalf("consent = %v", consent)
	}
	if clone := consent.Clone(); len(clone) != 1 || !clone["dev.lithe.test.agent"] {
		t.Fatalf("clone = %v", clone)
	}
	if !UsesAgents(false, []string{PermissionReadUsage}) || UsesAgents(false, []string{"ui.contribute"}) || !UsesAgents(true, nil) {
		t.Fatal("UsesAgents")
	}
}

func TestLaunchEnvironmentKeepsWhatCoreTakes(t *testing.T) {
	base := []string{"PATH=/usr/bin", "HOME=/h", "BROKEN", "=empty", "NUL=a\x00b", "BIG=" + strings.Repeat("x", 33<<10), "HOME=/later"}
	env, dropped := LaunchEnvironment(base, map[string]string{"TERM_PROGRAM": "Lithe", "PATH": "/tool/bin:/usr/bin"})
	if env["PATH"] != "/tool/bin:/usr/bin" || env["HOME"] != "/later" || env["TERM_PROGRAM"] != "Lithe" || len(env) != 3 {
		t.Fatalf("env = %v", env)
	}
	// BROKEN, =empty, NUL, BIG and the first HOME.
	if dropped != 5 {
		t.Fatalf("dropped = %d", dropped)
	}

	many := make([]string, 0, MaxEnvironment+10)
	for i := range MaxEnvironment + 10 {
		many = append(many, fmt.Sprintf("V%03d=x", i))
	}
	env, dropped = LaunchEnvironment(many, map[string]string{"KEEP": "1"})
	if len(env) != MaxEnvironment || env["KEEP"] != "1" || dropped != 11 || env["V000"] != "x" {
		t.Fatalf("len = %d, dropped = %d", len(env), dropped)
	}
}
