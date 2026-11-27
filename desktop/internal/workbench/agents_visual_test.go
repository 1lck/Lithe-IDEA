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

			shot := func(scene string) {
				t.Helper()
				h.settleChain()
				if err := session.Screenshot(filepath.Join(out, "agents-"+scene+"-"+look.theme+"-"+look.language+".png")); err != nil {
					t.Fatal(err)
				}
			}
			shot("chat")

			now := time.Date(2026, 11, 28, 10, 0, 0, 0, time.UTC).UnixMilli()
			v.tab = agentsTabHistory
			v.history = agentHistory{loaded: true, sessions: []agents.RecordedSession{
				{Agent: "dev.lithe.test.agent/sample", PluginID: "dev.lithe.test.agent", AgentID: "sample", SessionID: "s1", Cwd: root, Title: "Order total rounding", UpdatedAtMs: now},
				{Agent: "dev.lithe.test.other/other", PluginID: "dev.lithe.test.other", AgentID: "other", SessionID: "s2", Cwd: root, Title: "Add a discount rule", UpdatedAtMs: now - 3_600_000},
				{Agent: "dev.lithe.test.agent/sample", PluginID: "dev.lithe.test.agent", AgentID: "sample", SessionID: "s3", Cwd: root, Title: "Explain the checkout flow", UpdatedAtMs: now - 86_400_000},
			}}
			shot("history")
		})
	}
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
		{ID: "allow", Label: "Allow", OptionKind: "allow_once"},
		{ID: "allowAlways", Label: "Always allow", OptionKind: "allow_always"},
		{ID: "reject", Label: "Reject", OptionKind: "reject_once"},
	}})
	cost := 0.42
	t.Apply(agents.Event{Kind: "usage", ContextUsed: 18_400, ContextWindow: 200_000, Tokens: agents.Tokens{Input: 12_000, Output: 1_800, CacheRead: 4_600}, CostUSD: &cost})
	return &agentConversation{agent: agent, transcript: t, seen: 1}
}
