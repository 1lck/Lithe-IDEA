package workbench

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// sessionToolsCore answers the records commands the session tools make: search and list from
// the given hits and sessions, narrowed to the agents the call names the way Core narrows
// them, and read like recordCore.
type sessionToolsCore struct {
	recordCore
	hits     []agents.SearchHit
	searches []agents.SearchQuery
	lists    []agents.ListQuery
}

func (f *sessionToolsCore) Execute(ctx context.Context, command string, params, result any) error {
	var answer any
	switch command {
	case "agentSessions.search":
		query := params.(agents.SearchQuery)
		f.mu.Lock()
		f.searches = append(f.searches, query)
		f.mu.Unlock()
		hits := []agents.SearchHit{}
		for _, hit := range f.hits {
			if slices.Contains(query.Agents, hit.Agent) && len(hits) < query.Limit {
				hits = append(hits, hit)
			}
		}
		answer = map[string]any{"hits": hits}
	case "agentSessions.list":
		query := params.(agents.ListQuery)
		f.mu.Lock()
		f.lists = append(f.lists, query)
		f.mu.Unlock()
		sessions := []agents.RecordedSession{}
		for _, session := range f.sessions {
			if slices.Contains(query.Agents, session.Agent) && session.SessionID == query.SessionID && len(sessions) < query.Limit {
				sessions = append(sessions, session)
			}
		}
		answer = map[string]any{"sessions": sessions}
	default:
		return f.recordCore.Execute(ctx, command, params, result)
	}
	data, err := json.Marshal(answer)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, result)
}

const (
	sessionToolsAgent = "dev.lithe.test.agent/sample"
	sessionToolsOther = "dev.lithe.test.other/sample"
	sessionToolsPath  = "/fixture/home/.agent/sessions/s-1.jsonl"
)

// sessionToolsHarness opens a project in an English window whose agents are two synthetic agents
// that both read sessions, with Core answering the records commands from fake. Nothing is
// allowed yet: the switch is off and no agent's sessions are consented.
func sessionToolsHarness(t *testing.T, fake *sessionToolsCore) (*harness, *ideAPIConnection, *faultLog) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, settingsFile), []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarnessWithOptions(t, Options{
		Kernel: &testKernel{Client: core.NewClient()}, Store: store.At(dir), Languages: []string{"en-US"},
		AgentKernel: agents.NewClient(fake),
	})
	h.open(t.TempDir())
	h.settle()
	h.app.agentsView.catalog = []agents.CatalogAgent{
		{PluginID: "dev.lithe.test.agent", AgentID: "sample", DisplayName: "Sample", ReadsSessions: true, MayReadSessions: true},
		{PluginID: "dev.lithe.test.other", AgentID: "sample", DisplayName: "Other", ReadsSessions: true, MayReadSessions: true},
	}
	log := &faultLog{}
	h.app.logSink = log
	conn := &ideAPIConnection{workspaceKey: h.app.project.root}
	conn.cursorKey[0] = 1
	return h, conn, log
}

// sessionToolsFake is a session of the first agent made of ten 30 KiB lines, so one page holds
// eight of them, with one search hit in each agent.
func sessionToolsFake() *sessionToolsCore {
	fake := &sessionToolsCore{}
	for range 10 {
		fake.lines = append(fake.lines, 30<<10)
	}
	fake.sessions = []agents.RecordedSession{{
		Agent: sessionToolsAgent, SessionID: "s-1", Path: sessionToolsPath, ReadBytes: fake.size(),
		Cwd: "/fixture/home/project", PluginID: "dev.lithe.test.agent", AgentID: "sample", Title: "Retry policy",
	}}
	fake.hits = []agents.SearchHit{
		{Agent: sessionToolsAgent, Path: sessionToolsPath, SessionID: "s-1", AtMs: 1700000000000, Range: agents.ByteRange{Start: 30 << 10, End: 60 << 10}},
		{Agent: sessionToolsOther, Path: "/fixture/home/.other/s-2.jsonl", SessionID: "s-2", Range: agents.ByteRange{Start: 0, End: 10}},
	}
	return fake
}

// The tools answer only while the switch is on and only for the agents the user allowed; a
// call names an agent the user did not allow and is refused, as is every call after the
// consent is taken back or in a remote workspace.
func TestIDEAPISessionToolsAnswerOnlyWhatTheUserAllows(t *testing.T) {
	fake := sessionToolsFake()
	h, conn, _ := sessionToolsHarness(t, fake)
	search := map[string]any{"query": "line"}

	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_sessions_search", search)); code != "NOT_SUPPORTED" {
		t.Fatalf("a search with the switch off answered %q, want NOT_SUPPORTED", code)
	}
	h.app.settings.AgentSessionsMCPSearch = true
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_sessions_search", search)); code != "NOT_AVAILABLE" {
		t.Fatalf("a search with no agent allowed answered %q, want NOT_AVAILABLE", code)
	}
	h.app.settings.AgentSessionConsent = map[string]bool{"dev.lithe.test.agent": true}

	found := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_sessions_search", search))
	hits := found["hits"].([]map[string]any)
	if len(hits) != 1 || hits[0]["agent"] != sessionToolsAgent || hits[0]["agentName"] != "Sample" ||
		hits[0]["sessionID"] != "s-1" || hits[0]["excerpt"] != "line 1" || found["truncated"] != false {
		t.Fatalf("search answered %#v, want the allowed agent's hit with its excerpt", found)
	}
	if len(fake.searches) != 1 || !slices.Equal(fake.searches[0].Agents, []string{sessionToolsAgent}) || fake.searches[0].Limit != ideAPISessionHits+1 {
		t.Fatalf("Core was asked %+v, want only the allowed agent and one hit past the bound", fake.searches)
	}
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_sessions_search", map[string]any{"query": "line", "agent": sessionToolsOther})); code != "PERMISSION_DENIED" {
		t.Fatalf("a search of an agent the user did not allow answered %q, want PERMISSION_DENIED", code)
	}

	read := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_sessions_read", map[string]any{"sessionID": "s-1"}))
	if read["title"] != "Retry policy" || read["hasMore"] != true || len(read["messages"].([]map[string]any)) != 8 {
		t.Fatalf("read answered %#v, want the first eight messages and more", read)
	}
	for _, answer := range []any{found, read} {
		data, err := json.Marshal(answer)
		if err != nil {
			t.Fatal(err)
		}
		if text := string(data); strings.Contains(text, "/fixture/home") || strings.Contains(text, `"path"`) || strings.Contains(text, `"cwd"`) {
			t.Fatalf("an answer carries a path: %s", text)
		}
	}

	h.app.settings.AgentSessionConsent = nil
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_sessions_read", map[string]any{"sessionID": "s-1"})); code != "NOT_AVAILABLE" {
		t.Fatalf("a read after the consent was taken back answered %q, want NOT_AVAILABLE", code)
	}
	h.app.settings.AgentSessionConsent = map[string]bool{"dev.lithe.test.agent": true}
	if code := ideAPIFailureCode(h.app.ideAPISessionGate(&project{remote: &remoteProject{}}, "")); code != "NOT_AVAILABLE" {
		t.Fatalf("a call in a remote workspace answered %q, want NOT_AVAILABLE", code)
	}
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_sessions_search", map[string]any{"query": "  "})); code != "INVALID_ARGUMENTS" {
		t.Fatalf("an empty query answered %q, want INVALID_ARGUMENTS", code)
	}
}

// A session is read page by page with the cursor each page answers; a cursor changed by the
// client, made for another session or answered on another connection is refused, and an
// unknown session is not found.
func TestIDEAPISessionReadPagesWithTheConnectionsCursor(t *testing.T) {
	fake := sessionToolsFake()
	h, conn, log := sessionToolsHarness(t, fake)
	h.app.settings.AgentSessionsMCPSearch = true
	h.app.settings.AgentSessionConsent = map[string]bool{"dev.lithe.test.agent": true}

	first := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_sessions_read", map[string]any{"sessionID": "s-1"}))
	cursor, _ := first["nextCursor"].(string)
	if first["hasMore"] != true || cursor == "" || !strings.HasPrefix(cursor, "245760.") {
		t.Fatalf("the first page answered %#v, want a cursor after eight lines", first)
	}
	second := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_sessions_read", map[string]any{"sessionID": "s-1", "cursor": cursor}))
	messages := second["messages"].([]map[string]any)
	if second["hasMore"] != false || second["nextCursor"] != nil || len(messages) != 2 || messages[0]["text"] != "line 8" {
		t.Fatalf("the second page answered %#v, want the last two lines and no cursor", second)
	}

	other := &ideAPIConnection{workspaceKey: conn.workspaceKey}
	other.cursorKey[0] = 2
	number, mac, _ := strings.Cut(cursor, ".")
	for name, test := range map[string]struct {
		conn   *ideAPIConnection
		cursor string
	}{
		"another offset":     {conn, "30720." + mac},
		"a changed MAC":      {conn, number + "." + strings.Repeat("0", len(mac))},
		"a leading zero":     {conn, "0" + cursor},
		"no MAC":             {conn, number},
		"another connection": {other, cursor},
	} {
		answer := ideAPICall(t, h, test.conn, "lithe_sessions_read", map[string]any{"sessionID": "s-1", "cursor": test.cursor})
		if code := ideAPIFailureCode(answer); code != "INVALID_ARGUMENTS" {
			t.Fatalf("a cursor with %s answered %q, want INVALID_ARGUMENTS", name, code)
		}
	}
	if conn.sessionCursor(sessionToolsAgent, "s-1", 245760) == conn.sessionCursor(sessionToolsAgent, "s-2", 245760) {
		t.Fatal("two sessions share a cursor")
	}
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_sessions_read", map[string]any{"sessionID": "s-9"})); code != "NOT_FOUND" {
		t.Fatalf("an unknown session answered %q, want NOT_FOUND", code)
	}

	// The log has the tool, the number of messages and the duration of each answered call, and
	// never the session ID or a message.
	var logged []recordedEvent
	log.mu.Lock()
	for _, event := range log.events {
		if event.event == "agent.records.inspected" {
			logged = append(logged, event)
		}
	}
	log.mu.Unlock()
	if len(logged) != 8 || logged[0].fields["tool"] != "lithe_sessions_read" || logged[0].fields["results"] != int64(8) {
		t.Fatalf("logged %+v, want one event for each read", logged)
	}
	for _, event := range logged {
		if len(event.fields) != 3 {
			t.Fatalf("event fields %v, want tool, results and duration only", event.fields)
		}
		for _, value := range event.fields {
			if text, ok := value.(string); ok && (strings.Contains(text, "s-1") || strings.Contains(text, "line")) {
				t.Fatalf("event %v logs what was read", event.fields)
			}
		}
	}
}

// A search logs the tool and the number of hits, never the query.
func TestIDEAPISessionSearchLogsNoQuery(t *testing.T) {
	fake := sessionToolsFake()
	h, conn, log := sessionToolsHarness(t, fake)
	h.app.settings.AgentSessionsMCPSearch = true
	h.app.settings.AgentSessionConsent = map[string]bool{"dev.lithe.test.agent": true}
	ideAPICall(t, h, conn, "lithe_sessions_search", map[string]any{"query": "secret-word line"})
	log.mu.Lock()
	defer log.mu.Unlock()
	for _, event := range log.events {
		if event.event != "agent.records.inspected" {
			continue
		}
		data, _ := json.Marshal(event.fields)
		if strings.Contains(string(data), "secret-word") || event.fields["tool"] != "lithe_sessions_search" || event.fields["results"] != int64(1) {
			t.Fatalf("logged %s", data)
		}
		return
	}
	t.Fatal("the search was not logged")
}

// The excerpt starts a little before the first query word, stays within its bound and cuts only
// on character boundaries.
func TestIDEAPIExcerptStartsNearTheQuery(t *testing.T) {
	before := strings.Repeat("前文", 400)
	messages := []agents.RecordedMessage{{Text: "  " + before + " retry policy " + strings.Repeat("后文", 400)}, {Text: "   "}}
	excerpt, cut := ideAPIExcerpt(messages, "Retry")
	if !cut || len(excerpt) > ideAPIExcerptBytes || !utf8.ValidString(excerpt) || !strings.Contains(excerpt, "retry policy") {
		t.Fatalf("excerpt %q (%d bytes), cut %v", excerpt, len(excerpt), cut)
	}
	if lead := strings.Index(excerpt, "retry"); lead > ideAPIExcerptLead || lead < ideAPIExcerptLead-utf8.UTFMax {
		t.Fatalf("the excerpt starts %d bytes before the query, want about %d", lead, ideAPIExcerptLead)
	}
	if excerpt, cut := ideAPIExcerpt([]agents.RecordedMessage{{Text: "short reply"}}, "absent"); excerpt != "short reply" || cut {
		t.Fatalf("a short excerpt is %q, cut %v", excerpt, cut)
	}
}

// A page keeps each message within its bound, stops once it holds half its text, and a read made
// larger for a long line answers what fits and counts the rest.
func TestReadSessionPageBoundsItsMessages(t *testing.T) {
	long := &recordCore{lines: []uint64{10 << 10}, text: func(int) string { return strings.Repeat("长", 4000) }}
	page := readSessionPage(context.Background(), agents.NewClient(long), sessionToolsAgent, sessionToolsPath, 0, long.size())
	if len(page.messages) != 1 || page.messages[0]["truncated"] != true || len(page.messages[0]["text"].(string)) > ideAPIMessageBytes ||
		!utf8.ValidString(page.messages[0]["text"].(string)) || page.next != long.size() {
		t.Fatalf("page = %d messages, next %d; want one message cut to its bound", len(page.messages), page.next)
	}

	full := &recordCore{text: func(int) string { return strings.Repeat("x", 5<<10) }}
	for range 20 {
		full.lines = append(full.lines, 6<<10)
	}
	page = readSessionPage(context.Background(), agents.NewClient(full), sessionToolsAgent, sessionToolsPath, 0, full.size())
	if len(page.messages) != 10 || page.next != 60<<10 || page.omitted != 0 {
		t.Fatalf("page = %d messages, next %d, omitted %d; want two reads of five lines", len(page.messages), page.next, page.omitted)
	}

	// A 100 KiB line makes the read four times larger, and that read also holds 2,800 short
	// lines, more than a page has room for.
	crowded := &recordCore{lines: []uint64{100 << 10}}
	for range 2800 {
		crowded.lines = append(crowded.lines, 10)
	}
	page = readSessionPage(context.Background(), agents.NewClient(crowded), sessionToolsAgent, sessionToolsPath, 0, crowded.size())
	if len(page.messages) != ideAPIPageMessages || page.omitted != 2801-ideAPIPageMessages || page.next != crowded.size() {
		t.Fatalf("page = %d messages, omitted %d, next %d; want the page bound and the rest counted", len(page.messages), page.omitted, page.next)
	}
}

// Declaring the session tools follows the switch, a consent and the catalog, and a connection
// opened afterwards declares what the window offers.
func TestIDEAPISessionToolsAreOfferedOnlyWhenAllowed(t *testing.T) {
	a := &App{agentKernel: agents.NewClient(&agentCore{})}
	a.agentsView.catalog = []agents.CatalogAgent{{PluginID: "dev.lithe.test.agent", AgentID: "sample", ReadsSessions: true, MayReadSessions: true}}
	for _, test := range []struct {
		name    string
		on      bool
		consent map[string]bool
		want    bool
	}{
		{"switch off", false, map[string]bool{"dev.lithe.test.agent": true}, false},
		{"no consent", true, nil, false},
		{"another plugin's consent", true, map[string]bool{"dev.lithe.test.other": true}, false},
		{"both", true, map[string]bool{"dev.lithe.test.agent": true}, true},
	} {
		a.settings.AgentSessionsMCPSearch, a.settings.AgentSessionConsent = test.on, test.consent
		a.refreshIDEAPISessionTools()
		if got := a.ideAPISessionsDeclared.Load(); got != test.want {
			t.Fatalf("%s: declared %v, want %v", test.name, got, test.want)
		}
	}
	a.agentsView.catalog[0].MayReadSessions = false
	a.refreshIDEAPISessionTools()
	if a.ideAPISessionsDeclared.Load() {
		t.Fatal("the tools are declared for an agent whose plugin may not read sessions")
	}
}

// Turning the switch on reconnects an open connection, which then declares the session tools
// with the same client configuration and a new cursor key, and turning it off reconnects it
// without them. A refresh with nothing to change keeps the connection.
func TestIDEAPISessionSwitchReconnectsTheConnection(t *testing.T) {
	h, _, _ := sessionToolsHarness(t, sessionToolsFake())
	app, p := h.app, h.app.project
	app.settings.AgentSessionConsent = map[string]bool{"dev.lithe.test.agent": true}
	helper, err := app.ideAPIHelperPath()
	if err != nil {
		t.Fatalf("locate the staged helper (run with desktop-go.sh): %v", err)
	}
	configuration, err := app.ideAPIEnable(p, core.IDEPermissions{}, helper)
	if err != nil {
		t.Fatalf("enable: %v", err)
	}
	t.Cleanup(func() { app.ideAPIDisable(p) })
	current := func() *ideAPIConnection {
		p.ideAPI.mu.Lock()
		defer p.ideAPI.mu.Unlock()
		return p.ideAPI.conn
	}
	if ideAPIServesSessions(current().exposure) {
		t.Fatal("the session tools were declared before the switch was on")
	}
	reconnect := func(on bool) *ideAPIConnection {
		t.Helper()
		before := current()
		app.setAgentMCPSearch(on)
		// The old connection is stopped and the new one opened off the window thread.
		awaitStateWithin(t, h, 10*time.Second, "the connection to reopen", func() bool {
			after := current()
			return after != nil && after != before
		})
		after := current()
		if after.cursorKey == before.cursorKey || ideAPIBridgeError(app) != "" {
			t.Fatalf("switch %v: the new connection kept the cursor key or failed: %q", on, ideAPIBridgeError(app))
		}
		return after
	}
	if on := reconnect(true); !ideAPIServesSessions(on.exposure) || !slices.Equal(on.configuration, configuration) {
		t.Fatalf("after the switch was turned on: exposure %v, configuration %s", on.exposure, on.configuration)
	}
	if off := reconnect(false); ideAPIServesSessions(off.exposure) {
		t.Fatalf("after the switch was turned off: exposure %v", off.exposure)
	}
	same := current()
	app.refreshIDEAPISessionTools()
	if current() != same {
		t.Fatal("a refresh with nothing changed reconnected")
	}
}

// ideAPIBridgeError is the error the IDE Connection settings page shows.
func ideAPIBridgeError(a *App) string {
	b := ideAPISettings{a: a}.bridge()
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.lastError
}
