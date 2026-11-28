package workbench

import (
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// workedTurn is a conversation whose first turn read a file, ran two commands, changed a file
// and replied, timed from start to end.
func workedTurn(ended bool) *agentConversation {
	conversation := liveConversation("agent-1")
	t := conversation.transcript
	start := time.Date(2026, 11, 28, 9, 0, 0, 0, time.UTC)
	conversation.sentAt = start
	t.AddPrompt("Fix the cart total")
	t.PromptAccepted(1)
	conversation.timeTurns(start)
	for _, event := range []agents.Event{
		{Kind: "message", Turn: 1, Role: "thought", MessageID: "think", Text: "Look at the sum"},
		{Kind: "toolCall", Turn: 1, ToolCallID: "t1", ToolKind: "read", Status: "completed", Title: "Read cart.go"},
		{Kind: "toolCall", Turn: 1, ToolCallID: "t2", ToolKind: "execute", Status: "completed", Title: "go test"},
		{Kind: "toolCall", Turn: 1, ToolCallID: "t3", ToolKind: "execute", Status: "completed", Title: "go vet"},
		{Kind: "toolCall", Turn: 1, ToolCallID: "t4", ToolKind: "edit", Status: "completed", Title: "Edit cart.go",
			Locations: []agents.ToolLocation{{Path: "/work/cart.go"}}},
		{Kind: "message", Turn: 1, Role: "assistant", MessageID: "reply", Text: "Fixed."},
	} {
		t.Apply(event)
	}
	if ended {
		t.Apply(agents.Event{Kind: "turnEnded", Turn: 1, Reason: "completed"})
		conversation.timeTurns(start.Add(17*time.Minute + 7*time.Second))
	}
	return conversation
}

func rowKinds(conversation *agentConversation) []agentRowKind {
	conversation.layRows()
	kinds := make([]agentRowKind, len(conversation.rows))
	for i, row := range conversation.rows {
		kinds[i] = row.kind
	}
	return kinds
}

// A completed turn folds its steps under the line saying how long it worked; its reply and the
// files it changed stay out. Unfolded, a run of tool calls is one line that opens into them.
func TestAgentChatRowsFoldACompletedTurnsStepsUnderItsLastReply(t *testing.T) {
	conversation := workedTurn(true)
	want := []agentRowKind{agentRowUser, agentRowWorked, agentRowReply, agentRowActions}
	if got := rowKinds(conversation); !slices.Equal(got, want) {
		t.Fatalf("folded rows = %v, want %v", got, want)
	}
	if !slices.Equal(conversation.prompts, []int{0}) {
		t.Fatalf("prompt rows = %v, want [0]", conversation.prompts)
	}
	if took, ok := conversation.worked(1); !ok || took != 17*time.Minute+7*time.Second {
		t.Fatalf("worked = %v %v, want 17m7s", took, ok)
	}

	conversation.toggleUnfolded(1)
	want = []agentRowKind{agentRowUser, agentRowWorked, agentRowThought, agentRowTools, agentRowReply, agentRowActions}
	if got := rowKinds(conversation); !slices.Equal(got, want) {
		t.Fatalf("unfolded rows = %v, want %v", got, want)
	}
	tools := conversation.rows[3]
	if tools.count != 4 {
		t.Fatalf("the run covers %d tool calls, want 4", tools.count)
	}

	conversation.toggleOpened(conversation.transcript.Entries[tools.entry].Serial)
	want = []agentRowKind{agentRowUser, agentRowWorked, agentRowThought, agentRowTools,
		agentRowTool, agentRowTool, agentRowTool, agentRowTool, agentRowReply, agentRowActions}
	if got := rowKinds(conversation); !slices.Equal(got, want) {
		t.Fatalf("opened rows = %v, want %v", got, want)
	}
	if !conversation.rows[4].nested {
		t.Fatal("the calls of an opened run must be nested under it")
	}

	files := agentChangedFiles(conversation.transcript.Entries)
	if !slices.Equal(files, []string{"/work/cart.go"}) {
		t.Fatalf("changed files = %v, want the edited file only", files)
	}
}

// While its turn runs, the steps show as they come and the window says it works.
func TestAgentChatRowsShowARunningTurnsSteps(t *testing.T) {
	conversation := workedTurn(false)
	want := []agentRowKind{agentRowUser, agentRowThought, agentRowTools, agentRowReply, agentRowWorking}
	if got := rowKinds(conversation); !slices.Equal(got, want) {
		t.Fatalf("rows = %v, want %v", got, want)
	}
}

// A row keeps its key while rows are added around it, and no two rows share one.
func TestAgentRowKeysStayWithTheirEntries(t *testing.T) {
	conversation := workedTurn(false)
	conversation.layRows()
	reply := conversation.rowKey(3)
	conversation.transcript.Apply(agents.Event{Kind: "turnEnded", Turn: 1, Reason: "completed"})
	conversation.toggleUnfolded(1)
	conversation.layRows()
	at := slices.IndexFunc(conversation.rows, func(row agentRow) bool { return row.kind == agentRowReply })
	if got := conversation.rowKey(at); got != reply {
		t.Fatalf("the reply's key moved from %d to %d", reply, got)
	}
	seen := map[int]bool{}
	for i := range conversation.rows {
		key := conversation.rowKey(i)
		if seen[key] {
			t.Fatalf("row %d repeats key %d", i, key)
		}
		seen[key] = true
	}
}

func TestAgentToolsSummaryCountsEachKindOfWork(t *testing.T) {
	entries := workedTurn(true).transcript.Entries[2:6]
	for _, tc := range []struct {
		language i18n.Language
		want     string
	}{
		{i18n.English, "1 file read, 1 file changed and 2 commands run"},
		{i18n.Chinese, "已读取 1 个文件、已修改 1 个文件 和 已运行 2 条命令"},
	} {
		if got := agentToolsSummary(tc.language, entries); got != tc.want {
			t.Errorf("%v summary = %q, want %q", tc.language, got, tc.want)
		}
	}
	if got := agentToolsSummary(i18n.English, entries[1:3]); got != "2 commands run" {
		t.Errorf("summary of two commands = %q", got)
	}
}

func TestAgentDurationAndUsageWindowNames(t *testing.T) {
	for took, want := range map[time.Duration]string{
		42 * time.Second:                           "42s",
		17*time.Minute + 7*time.Second:             "17m 7s",
		time.Hour + 5*time.Minute + 59*time.Second: "1h 5m",
	} {
		if got := agentDuration(i18n.English, took); got != want {
			t.Errorf("duration %v = %q, want %q", took, got, want)
		}
	}
	for _, tc := range []struct {
		window agents.RateWindow
		want   string
	}{
		{agents.RateWindow{ID: "primary", WindowMinutes: 300}, "5h"},
		{agents.RateWindow{ID: "secondary", WindowMinutes: 7 * 24 * 60}, "Weekly"},
		{agents.RateWindow{ID: "days", WindowMinutes: 2 * 24 * 60}, "2d"},
		{agents.RateWindow{ID: "burst", Label: "Burst", WindowMinutes: 45}, "Burst"},
		{agents.RateWindow{ID: "other"}, "other"},
	} {
		if got := agentRateLabel(i18n.English, tc.window); got != tc.want {
			t.Errorf("window %+v = %q, want %q", tc.window, got, tc.want)
		}
	}
	now := time.Date(2026, 11, 28, 9, 0, 0, 0, time.Local)
	if got := agentResetTime(now, now.Add(3*time.Hour)); got != "12:00" {
		t.Errorf("a reset today = %q, want the time of day", got)
	}
	if got := agentResetTime(now, now.Add(48*time.Hour)); got != "11-30 09:00" {
		t.Errorf("a later reset = %q, want the date and time", got)
	}
}

// sessionSettings are a backend's model and reasoning effort settings.
func sessionSettings(model, effort string) []agents.ConfigOption {
	return []agents.ConfigOption{
		{ID: "model", Name: "Model", Category: "model", CurrentValue: model, Options: []agents.ConfigValue{
			{Value: "model-a", Name: "Model A"}, {Value: "model-b", Name: "Model B"},
		}},
		{ID: "effort", Name: "Effort", Category: "thoughtLevel", CurrentValue: effort, Options: []agents.ConfigValue{
			{Value: "low", Name: "Low"}, {Value: "medium", Name: "Medium"}, {Value: "high", Name: "High"},
		}},
	}
}

// A picked model shows at once and goes to the backend; the settings the backend reports next
// replace the pick.
func TestAgentSettingPickShowsUntilTheBackendReports(t *testing.T) {
	conversation := sampleAgentConversation()
	conversation.transcript.Apply(agents.Event{Kind: "configOptions", ConfigOptions: sessionSettings("model-a", "medium")})
	h, kernel := showAgentConversationWith(t, conversation)
	if got := agentSettingsLabel(conversation); got != "Model A Medium" {
		t.Fatalf("chip = %q, want the model and effort in force", got)
	}

	h.app.setAgentOption(h.app.project, conversation, "model", "model-b")
	if got := agentSettingsLabel(conversation); got != "Model B Medium" {
		t.Fatalf("chip after the pick = %q, want the picked model at once", got)
	}
	h.settleUntil("the setting sent", func() bool { return kernel.count("agents.setConfigOption") == 1 })

	v := &h.app.agentsView
	applyAgentBatch(v, agents.EventBatch{Next: 2, Events: []agents.SessionEvent{{Sequence: 1, Session: "agent-1",
		Event: agents.Event{Kind: "configOptions", ConfigOptions: sessionSettings("model-a", "medium")}}}}, time.Time{})
	if conversation.picks != nil {
		t.Fatalf("picks = %v, want them dropped once the backend reported its settings", conversation.picks)
	}
	if got := agentSettingsLabel(conversation); got != "Model A Medium" {
		t.Fatalf("chip = %q, want what the backend reports in force", got)
	}
}

// Letting go of the effort slider picks the value under its thumb.
func TestAgentEffortSliderPicksTheValueLetGoOf(t *testing.T) {
	conversation := sampleAgentConversation()
	conversation.transcript.Apply(agents.Event{Kind: "configOptions", ConfigOptions: sessionSettings("model-a", "medium")})
	h, kernel := showAgentConversationWith(t, conversation)
	h.clickNamed("Model A Medium")
	h.settle()
	if !conversation.settingsOpen || !h.shows("Reasoning effort") {
		t.Fatal("clicking the settings chip did not show the effort slider")
	}
	if conversation.effort.Value != 1 {
		t.Fatalf("slider at %v, want the value in force, 1", conversation.effort.Value)
	}

	slider := h.pageHit("Reasoning effort").Bounds
	h.drag(center(slider), gfx.Point{X: slider.X + slider.Width - 1, Y: center(slider).Y})
	h.settleUntil("the effort sent", func() bool { return kernel.count("agents.setConfigOption") == 1 })
	if got := conversation.picks["effort"]; got != "high" {
		t.Fatalf("picked effort = %q, want high, the nearest value", got)
	}
	if conversation.effort.Value != 2 {
		t.Fatalf("slider at %v, want it put on the picked value", conversation.effort.Value)
	}
}

// A conversation moves into an editor tab and back, both ways; closing its tab moves it back
// too, and its session keeps running until the conversation is closed.
func TestAgentConversationMovesBetweenTheToolWindowAndAnEditorTab(t *testing.T) {
	conversation := sampleAgentConversation()
	conversation.transcript.AddPrompt("Why does the total lose a cent?")
	h, kernel := showAgentConversationWith(t, conversation)
	p := h.app.project
	lang := h.app.language()

	h.clickNamed(i18n.Shared(lang, "desktop.agents.openInEditor"))
	h.settle()
	if conversation.tab == 0 {
		t.Fatal("Open in editor left the conversation in the tool window")
	}
	g := p.terms.bench.GroupOf(agentMember(conversation.tab))
	if g == nil || h.app.selectedAgentTab(g.ID) != conversation {
		t.Fatal("no editor tab shows the conversation")
	}
	if h.app.sidebarConversation() != nil {
		t.Fatal("the tool window still shows the conversation an editor tab shows")
	}

	h.clickNamed(i18n.Shared(lang, "desktop.agents.moveToSidebar"))
	h.settle()
	if conversation.tab != 0 || p.terms.bench.GroupOf(agentMember(1)) != nil {
		t.Fatal("Move to sidebar left the editor tab open")
	}
	if h.app.sidebarConversation() != conversation {
		t.Fatal("the tool window does not show the conversation moved back")
	}

	h.clickNamed(i18n.Shared(lang, "desktop.agents.openInEditor"))
	h.settle()
	tabs, _ := h.app.groupTabs(p.terms.bench.GroupOf(agentMember(conversation.tab)).ID)
	at := slices.IndexFunc(tabs, func(s shownTab) bool { return s.agent == conversation })
	if at < 0 {
		t.Fatal("the editor's tab strip does not list the conversation")
	}
	h.app.closeTab(tabs[at])
	h.settle()
	if conversation.tab != 0 || !conversation.transcript.Live() || kernel.count("agents.close") != 0 {
		t.Fatal("closing the tab must move the conversation back and keep its session")
	}

	h.app.openAgentTab(p, conversation)
	member := agentMember(conversation.tab)
	h.app.closeConversation(p, conversation)
	h.settleUntil("the session closed", func() bool { return kernel.count("agents.close") == 1 })
	if p.terms.bench.GroupOf(member) != nil {
		t.Fatal("closing the conversation left its editor tab open")
	}
}

// navDot is the navigator's dot of the prompt named title: a control as narrow as the
// navigator, which the prompt's own row is not.
func (h *harness) navDot(title string) gfx.Rect {
	h.t.Helper()
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == title && hit.Bounds.Width <= agentNavWidth {
			return hit.Bounds
		}
	}
	h.t.Fatalf("the navigator has no dot for %q", title)
	return gfx.Rect{}
}

// A dot of the prompt navigator scrolls the transcript to its prompt; resting on it shows which
// prompt it is.
func TestAgentPromptNavigatorScrollsToAPrompt(t *testing.T) {
	conversation := sampleAgentConversation()
	paragraph := strings.Repeat("A sentence long enough to wrap a few times in the tool window. ", 6)
	reply := strings.Repeat(paragraph+"\n\n", 4)
	const turns = 8
	for i := range turns {
		turn := uint64(i + 1)
		conversation.transcript.AddPrompt(fmt.Sprintf("Question %d", turn))
		conversation.transcript.PromptAccepted(turn)
		conversation.transcript.Apply(agents.Event{Kind: "message", Turn: turn, Role: "assistant",
			MessageID: fmt.Sprintf("m%d", turn), Text: reply})
		conversation.transcript.Apply(agents.Event{Kind: "turnEnded", Turn: turn, Reason: "completed"})
	}
	h, _ := showAgentConversationWith(t, conversation)
	if len(conversation.prompts) != turns {
		t.Fatalf("prompt rows = %v, want %d", conversation.prompts, turns)
	}
	if got := conversation.currentPrompt(); got != turns-1 {
		t.Fatalf("the transcript opens at prompt %d, want the last, %d", got, turns-1)
	}
	if _, ok := h.findPageHit("Scroll to bottom"); ok {
		t.Fatal("the transcript at its end offers to scroll to the bottom")
	}

	if h.shows("Question 3") {
		t.Fatal("the third prompt shows before the navigator scrolled to it")
	}
	dot := h.navDot("Question 3")
	h.click(center(dot))
	// The list measures the rows around the prompt in the paints that follow.
	if err := h.driver.Advance(200 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if !h.shows("Question 3") {
		t.Fatal("the navigator's dot does not scroll to its prompt")
	}
	if got := conversation.currentPrompt(); got != 2 {
		t.Fatalf("the navigator marks prompt %d, want the third, 2", got)
	}
	if _, ok := h.findPageHit("Scroll to bottom"); !ok {
		t.Fatal("the transcript scrolled back does not offer to scroll to the bottom")
	}

	if err := h.driver.Move(center(dot).X, center(dot).Y); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.Advance(400 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if !h.shows("3 of 8") {
		t.Fatal("resting on the dot does not show which prompt it is")
	}
}
