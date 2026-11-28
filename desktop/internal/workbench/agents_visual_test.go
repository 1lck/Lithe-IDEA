//go:build vivahead && lithevisual

package workbench

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/headless"
)

// TestVisualAgents captures the Agent tool window of a synthetic agent plugin: a conversation
// waiting for a permission answer, with its plan, a tool call and the usage line, and the
// History tab listing recorded sessions. Every name, path and text is made up for the capture.
func TestVisualAgents(t *testing.T) {
	out := os.Getenv("LITHE_VISUAL_OUTPUT_DIR")
	if out == "" {
		t.Skip("set LITHE_VISUAL_OUTPUT_DIR")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, look := range []struct{ theme, language string }{
		{"dark", "zh-Hans"}, {"dark", "en"}, {"light", "zh-Hans"}, {"light", "en"},
	} {
		t.Run(look.theme+"-"+look.language, func(t *testing.T) {
			prefs := store.At(t.TempDir())
			if err := prefs.Save(settingsFile, settings{Theme: themeChoice(look.theme), Language: look.language, DisableAutoSave: true}); err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(t.TempDir(), "shop")
			if err := os.MkdirAll(filepath.Join(root, "src"), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, "src", "order.go"), []byte("package shop\n"), 0600); err != nil {
				t.Fatal(err)
			}
			var session *headless.Session
			h := newHarnessWithDriver(t, Options{
				Kernel: &testKernel{Client: core.NewClient()}, Store: prefs, Languages: []string{look.language},
				AgentKernel: agents.NewClient(&agentCore{}),
			}, func(config app.Config) (*app.Driver, func(), error) {
				config.Width, config.Height = 1440, 900
				var err error
				session, err = headless.Open(config, nil, headless.Options{})
				if err != nil {
					return nil, nil, err
				}
				return session.Driver(), session.Close, nil
			})
			h.openTree(t, root)
			h.settleChain()

			v := &h.app.agentsView
			v.catalog = []agents.CatalogAgent{
				{PluginID: "dev.lithe.test.agent", AgentID: "sample", DisplayName: "Sample Agent", Tool: "sample-cli",
					Modes: []string{"native"}, Forms: []string{"conversation", "terminal"}, ReadsSessions: true, MayRun: true,
					MayReadSessions: true, Update: &agents.Update{Arguments: []string{"update"}}},
				{PluginID: "dev.lithe.test.other", AgentID: "other", DisplayName: "Other Agent", Tool: "other-cli",
					Modes: []string{"native"}, Forms: []string{"conversation"}, ReadsSessions: true, MayRun: true, MayReadSessions: true},
			}
			v.configured = true
			v.conversations = []*agentConversation{sampleConversation(v.catalog[0])}
			h.click(center(h.button(itemAgents)))
			// The pointer leaves the stripe button, so its tooltip does not show over the scenes.
			if err := h.driver.Move(720, 450); err != nil {
				t.Fatal(err)
			}

			// The scenes change the window's state directly, so each one asks for a frame first.
			shot := func(scene string) {
				t.Helper()
				h.redraw()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "agents-"+scene+"-"+look.theme+"-"+look.language+".png")); err != nil {
					t.Fatal(err)
				}
			}
			shot("chat")

			now := time.Date(2026, 11, 28, 10, 0, 0, 0, time.UTC).UnixMilli()
			v.tab = agentsTabHistory
			v.history = sampleAgentHistory(root, time.Now())
			shot("history")

			v.history.query, v.history.searched = "discount", "discount"
			v.history.hits = map[string]agents.SearchHit{agentSessionKey("dev.lithe.test.other/other", "s2"): {
				Agent: "dev.lithe.test.other/other", PluginID: "dev.lithe.test.other", AgentID: "other", SessionID: "s2",
				Path: "s2.jsonl", Range: agents.ByteRange{Start: 100, End: 180}, AtMs: time.Now().Add(-90 * time.Minute).UnixMilli(),
			}}
			v.history.previews.store(agentPreviewKey{agent: "dev.lithe.test.other/other", path: "s2.jsonl", start: 100, end: 180},
				agentPreview{role: "user", text: "Add a discount rule that takes 10% off carts over 100 and never stacks with a coupon"})
			v.history.sessions = v.history.sessions[1:2]
			v.history.total = 1
			v.history.rebuildRows()
			shot("history-search")

			v.history = sampleAgentHistory(root, time.Now())
			v.history.hidden = map[string]bool{"dev.lithe.test.other/other": true}
			v.history.since = agentSinceWeek
			v.history.popup = agentPopupFilter
			shot("history-filter")

			v.history = sampleAgentHistory(root, time.Now())
			v.history.compact = true
			v.history.statusOpen = true
			v.history.expanded = map[string]bool{agentSessionKey("dev.lithe.test.agent/sample", "s1"): true}
			shot("history-compact")

			v.history.record = &agentRecord{
				agent: "dev.lithe.test.agent/sample", pluginID: "dev.lithe.test.agent", agentID: "sample", sessionID: "s1",
				title: "Order total rounding", path: "s1.jsonl", size: 4096, next: 4096, done: true,
				messages: []agents.RecordedMessage{
					{Role: "user", Text: "Why does the order total lose a cent on large carts?", AtMs: now - 600_000},
					{Role: "assistant", Text: "Total adds prices as float64, so each addition can round. Summing integer cents keeps every cart exact.", AtMs: now - 590_000},
					{Role: "tool", ToolName: "Read", Text: "src/order.go", AtMs: now - 585_000},
					{Role: "assistant", Text: "Changed Total to sum cents and added a test with a 10,000-item cart.", AtMs: now - 420_000},
				},
			}
			shot("record")

			v.history.record = nil
			v.tab = agentsTabChat
			h.app.notifyAgentToolMissing(v.catalog[1])
			shot("cli-missing")
		})
	}
}

// sampleAgentHistory is a History tab listing made-up sessions of the two synthetic agents in
// root and a sibling directory, with their previews read and a refresh just done.
func sampleAgentHistory(root string, now time.Time) agentHistory {
	other := filepath.Join(filepath.Dir(root), "shop-admin")
	ago := func(d time.Duration) int64 { return now.Add(-d).UnixMilli() }
	span := func(start uint64) *agents.ByteRange { return &agents.ByteRange{Start: start, End: start + 80} }
	sessions := []agents.RecordedSession{
		{Agent: "dev.lithe.test.agent/sample", PluginID: "dev.lithe.test.agent", AgentID: "sample", SessionID: "s1", Path: "s1.jsonl", Cwd: root,
			Title: "Order total rounding", StartedAtMs: ago(26 * time.Hour), UpdatedAtMs: ago(90 * time.Second), AgentVersion: "2.4.1",
			MessageCount: 1284, SubagentCount: 3, Model: "sample-large-2", LastMessageRange: span(0)},
		{Agent: "dev.lithe.test.other/other", PluginID: "dev.lithe.test.other", AgentID: "other", SessionID: "s2", Path: "s2.jsonl", Cwd: root,
			Title: "Add a discount rule", StartedAtMs: ago(5 * time.Hour), UpdatedAtMs: ago(90 * time.Minute),
			MessageCount: 312, Model: "other-fast-1", LastMessageRange: span(0)},
		{Agent: "dev.lithe.test.agent/sample", PluginID: "dev.lithe.test.agent", AgentID: "sample", SessionID: "s3", Path: "s3.jsonl", Cwd: root,
			Title: "Explain the checkout flow", StartedAtMs: ago(50 * time.Hour), UpdatedAtMs: ago(49 * time.Hour),
			MessageCount: 46, SubagentCount: 1, Model: "sample-large-2", LastMessageRange: span(0)},
		{Agent: "dev.lithe.test.agent/sample", PluginID: "dev.lithe.test.agent", AgentID: "sample", SessionID: "s4", Path: "s4.jsonl", Cwd: other,
			Title: "Admin login rate limit", StartedAtMs: ago(80 * time.Hour), UpdatedAtMs: ago(75 * time.Hour),
			MessageCount: 1, Model: "sample-large-2", LastMessageRange: span(0)},
	}
	history := agentHistory{loaded: true, sessions: sessions, total: uint64(len(sessions)),
		groupCounts: map[string]uint64{root: 3, other: 1}, refreshedAt: now.Add(-20 * time.Second),
		syncs: []agentSyncResult{
			{agent: "Sample Agent", report: agents.SyncReport{FilesListed: 24, FilesUnchanged: 22, FilesRead: 2}},
			{agent: "Other Agent", report: agents.SyncReport{FilesListed: 9, FilesUnchanged: 9}},
		}}
	previews := []agentPreview{
		{role: "assistant", text: "Total now sums integer cents, so a 10,000-item cart keeps every cent; the new test covers carts over the float64 limit and the refund path."},
		{role: "user", text: "Add a discount rule that takes 10% off carts over 100 and never stacks with a coupon"},
		{role: "assistant", text: "Checkout validates the cart, reserves stock, charges the card and then writes the order, rolling back the reservation if the charge fails."},
		{role: "tool", toolName: "Bash", text: "go test ./admin/... ok 0.8s"},
	}
	for i, session := range sessions {
		key, _ := history.previewKeyOf(session)
		history.previews.store(key, previews[i])
	}
	history.rebuildRows()
	return history
}

// sampleConversation is a conversation with agent in the middle of a turn: the prompt, a
// thought, a reply, a finished tool call, a plan, a permission request and the usage so far.
func sampleConversation(agent agents.CatalogAgent) *agentConversation {
	t := agents.NewTranscript("agent-1", agent.PluginID, agent.AgentID)
	t.Apply(agents.Event{Kind: "session", AgentSessionID: "sample-session", Model: "sample-model"})
	t.AddPrompt("Why does the order total lose a cent on large carts?")
	t.PromptAccepted(1)
	t.Apply(agents.Event{Kind: "message", Turn: 1, Role: "thought", MessageID: "t1", Text: "The total is summed in float64 before rounding."})
	t.Apply(agents.Event{Kind: "toolCall", Turn: 1, ToolCallID: "c1", Status: "completed", ToolKind: "read", Title: "Read src/order.go",
		Locations: []agents.ToolLocation{{Path: "src/order.go", Line: 42}}, Output: "func Total(items []Item) float64 {\n\tsum := 0.0\n\tfor _, item := range items {\n\t\tsum += item.Price\n\t}\n\treturn math.Round(sum*100) / 100\n}"})
	t.Apply(agents.Event{Kind: "message", Turn: 1, Role: "assistant", MessageID: "m1", Text: "Total adds prices as float64, so each addition can round. Summing integer cents keeps every cart exact."})
	t.Apply(agents.Event{Kind: "plan", Entries: []agents.PlanEntry{
		{Content: "Store prices as integer cents", Status: "completed"},
		{Content: "Change Total to sum cents", Status: "inProgress"},
		{Content: "Add a test with a large cart", Status: "pending"},
	}})
	t.Apply(agents.Event{Kind: "permissionRequested", Turn: 1, Permission: "p1", Title: "Edit src/order.go", ToolCallID: "c2", Options: []agents.PermissionOption{
		{ID: "allow", Label: "Allow", OptionKind: "allowOnce"},
		{ID: "allowSession", Label: "Allow for this session", OptionKind: "allowAlways"},
		{ID: "reject", Label: "Reject", OptionKind: "rejectOnce"},
	}})
	cost := 0.42
	t.Apply(agents.Event{Kind: "usage", ContextUsed: 18_400, ContextWindow: 200_000, Tokens: agents.Tokens{Input: 12_000, Output: 1_800, CacheRead: 4_600}, CostUSD: &cost})
	return &agentConversation{agent: agent, transcript: t, seen: 1}
}
