package logwindow

import (
	"context"
	"maps"
	"slices"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The tests drive the window's page the way a person does, through the headless driver, and
// read what the model and the frame say afterwards. They find controls by the names the page
// gives them (Hit.Label) and rows by their role, never by a pixel offset.

// hitsWhere lists the hits of the current frame that match keep, top to bottom.
func hitsWhere(driver *app.Driver, keep func(gfx.Hit) bool) []gfx.Hit {
	var found []gfx.Hit
	for _, hit := range driver.Snapshot().Hits {
		if keep(hit) {
			found = append(found, hit)
		}
	}
	sort.SliceStable(found, func(i, j int) bool { return found[i].Bounds.Y < found[j].Bounds.Y })
	return found
}

func centerOf(hit gfx.Hit) (x, y float32) {
	return hit.Bounds.X + hit.Bounds.Width/2, hit.Bounds.Y + hit.Bounds.Height/2
}

// hitLabeled returns the topmost hit with the label.
func hitLabeled(t *testing.T, driver *app.Driver, label string) gfx.Hit {
	t.Helper()
	hits := hitsWhere(driver, func(h gfx.Hit) bool { return h.Label == label })
	if len(hits) == 0 {
		t.Fatalf("no control named %q in the frame", label)
	}
	return hits[len(hits)-1]
}

func clickLabeled(t *testing.T, driver *app.Driver, label string) {
	t.Helper()
	x, y := centerOf(hitLabeled(t, driver, label))
	if err := driver.Click(x, y); err != nil {
		t.Fatal(err)
	}
}

// tableRowHits are the rows of the table, as options to the right of the channel list.
func tableRowHits(driver *app.Driver) []gfx.Hit {
	return hitsWhere(driver, func(h gfx.Hit) bool {
		return h.Role == gfx.RoleOption && h.Bounds.X >= sidebarWidth && h.Bounds.Height >= tableRowHeight-1
	})
}

func sidebarRowHits(driver *app.Driver) []gfx.Hit {
	return hitsWhere(driver, func(h gfx.Hit) bool { return h.Role == gfx.RoleOption && h.Bounds.X < sidebarWidth })
}

func clickHit(t *testing.T, driver *app.Driver, hit gfx.Hit) {
	t.Helper()
	x, y := centerOf(hit)
	if err := driver.Click(x, y); err != nil {
		t.Fatal(err)
	}
}

// bigFixture is a window over n synthetic records that stays out of the way of a query.
func bigFixture(t testing.TB, n int) (*exportFixture, *window, *app.Driver) {
	t.Helper()
	fixture := newExportFixture(t)
	fixture.model.started = true
	fixture.model.follows = false
	w, driver := openTestWindow(t, fixture.model)
	settleWindow(t, driver)
	fillRecords(fixture.model, n)
	w.inv.Invalidate()
	settleWindow(t, driver)
	return fixture, w, driver
}

// settleWindow paints the window until what it asked of the next frame (a list that was
// scrolled places its rows from heights it has not measured yet) has settled.
func settleWindow(t testing.TB, driver *app.Driver) {
	t.Helper()
	for range 6 {
		if err := driver.Pump(); err != nil {
			t.Fatal(err)
		}
		if err := driver.Advance(20 * time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
}

func TestTableRowClickSelectsItAndTheDetailsShowIt(t *testing.T) {
	fixture, w, driver := bigFixture(t, 200)
	rows := tableRowHits(driver)
	if len(rows) < 3 {
		t.Fatalf("the table declared %d rows, want a screenful", len(rows))
	}
	clickHit(t, driver, rows[2])
	m := fixture.model
	if len(m.selection) != 1 {
		t.Fatalf("a click selected %d records, want 1", len(m.selection))
	}
	record, ok := m.selectedRecord()
	if !ok || record.Channel == "" {
		t.Fatal("the details have no record to show after a click")
	}
	if got := hitLabeled(t, driver, "⧉ "+w.text.Logs.CopyJSON); got.Disabled {
		t.Fatal("the details' copy action stays disabled with a record selected")
	}
}

func TestTableOnlyDeclaresTheVisibleRows(t *testing.T) {
	_, _, driver := bigFixture(t, maxRecords)
	rows := tableRowHits(driver)
	if len(rows) == 0 || len(rows) > 60 {
		t.Fatalf("a table of %d records declared %d rows, want only the visible ones", maxRecords, len(rows))
	}
}

func TestTableArrowKeysMoveTheSelectionAndShiftExtendsIt(t *testing.T) {
	fixture, _, driver := bigFixture(t, 200)
	m := fixture.model
	clickHit(t, driver, tableRowHits(driver)[1])
	first := slices.Collect(maps.Keys(m.selection))
	if len(first) != 1 {
		t.Fatalf("a click selected %d records, want 1", len(first))
	}
	rows := m.displayRows()
	at := tableRowIndex(rows, first[0])
	if err := driver.Key(gfx.KeyDown, 0); err != nil {
		t.Fatal(err)
	}
	if len(m.selection) != 1 || !m.selection[rows[at+1].id] {
		t.Fatalf("Down selected %v, want the row after %q", m.selection, first[0])
	}
	if err := driver.Key(gfx.KeyDown, gfx.ModifierShift); err != nil {
		t.Fatal(err)
	}
	if len(m.selection) != 2 || !m.selection[rows[at+1].id] || !m.selection[rows[at+2].id] {
		t.Fatalf("Shift+Down selected %v, want the two rows after %q", m.selection, first[0])
	}
}

func TestTableShiftAndPrimaryClicksChooseSeveralRows(t *testing.T) {
	fixture, _, driver := bigFixture(t, 200)
	m := fixture.model
	rows := tableRowHits(driver)
	clickHit(t, driver, rows[1])
	if err := driver.KeyDown(gfx.KeyShiftLeft, ""); err != nil {
		t.Fatal(err)
	}
	clickHit(t, driver, rows[4])
	if err := driver.KeyUp(gfx.KeyShiftLeft, ""); err != nil {
		t.Fatal(err)
	}
	if len(m.selection) != 4 {
		t.Fatalf("Shift-click selected %d records, want the 4 from the first row to the clicked one", len(m.selection))
	}
	if got := len(m.selectedRecords()); got != 4 {
		t.Fatalf("copy would take %d records, want 4", got)
	}
}

func TestTableEscapeClearsTheSelection(t *testing.T) {
	fixture, _, driver := bigFixture(t, 200)
	clickHit(t, driver, tableRowHits(driver)[2])
	if len(fixture.model.selection) == 0 {
		t.Fatal("a click selected nothing")
	}
	if err := driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	settleWindow(t, driver)
	if len(fixture.model.selection) != 0 {
		t.Fatalf("Escape left %d records selected", len(fixture.model.selection))
	}
}

func TestTableSelectionFollowsAJumpAndTheModel(t *testing.T) {
	fixture, w, driver := bigFixture(t, 200)
	m := fixture.model
	m.jump(m.records[147].EpochMs)
	w.inv.Invalidate()
	settleWindow(t, driver)
	if !m.selection[m.ids[147]] {
		t.Fatal("jump did not select the record")
	}
	if !w.table.chosen.Has(m.keyBase + 147) {
		t.Fatal("the list does not hold the choice the model made")
	}
}

func TestTableRightClickChoosesTheRowAndOpensItsMenu(t *testing.T) {
	fixture, w, driver := bigFixture(t, 200)
	row := tableRowHits(driver)[3]
	x, y := centerOf(row)
	if err := driver.ClickButton(x, y, gfx.PointerButtonSecondary); err != nil {
		t.Fatal(err)
	}
	if len(fixture.model.selection) != 1 {
		t.Fatalf("a secondary press selected %d records, want 1", len(fixture.model.selection))
	}
	if hitLabeled(t, driver, w.text.Logs.CopyLine).Disabled {
		t.Fatal("the row menu's copy item is disabled")
	}
}

func TestTableHeaderMenuHidesAColumn(t *testing.T) {
	fixture, w, driver := bigFixture(t, 50)
	header := hitLabeled(t, driver, w.text.Logs.Columns)
	x, y := centerOf(header)
	if err := driver.ClickButton(x, y, gfx.PointerButtonSecondary); err != nil {
		t.Fatal(err)
	}
	clickLabeled(t, driver, w.text.Logs.Time)
	if !fixture.model.columnHidden("time") {
		t.Fatal("choosing the Time item of the header menu left the column shown")
	}
}

func TestTableHeaderHandleResizesAColumn(t *testing.T) {
	fixture, w, driver := bigFixture(t, 50)
	before := fixture.model.columnWidthOf("time", float64(tableDefaultWidths[tableColTime]))
	handles := hitsWhere(driver, func(h gfx.Hit) bool {
		return h.Role == gfx.RoleSeparator && h.Label == w.text.Logs.Time
	})
	if len(handles) != 1 {
		t.Fatalf("found %d resize handles for the Time column, want 1", len(handles))
	}
	x, y := centerOf(handles[0])
	if err := driver.Press(x, y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if err := driver.Move(x+40, y); err != nil {
		t.Fatal(err)
	}
	if err := driver.Release(x+40, y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	after := fixture.model.columnWidthOf("time", float64(tableDefaultWidths[tableColTime]))
	if after <= before+20 {
		t.Fatalf("dragging the handle 40 points widened the column from %v to %v", before, after)
	}
}

func TestFollowingPausesWhenTheTableIsScrolledUp(t *testing.T) {
	fixture, w, driver := bigFixture(t, 500)
	m := fixture.model
	m.follows = true
	m.scrollRevision++
	w.inv.Invalidate()
	settleWindow(t, driver)
	if !m.follows {
		t.Fatal("the window stopped following by itself")
	}
	if err := driver.Scroll(gfx.ScrollEvent{X: 600, Y: 350, DeltaY: -300}); err != nil {
		t.Fatal(err)
	}
	settleWindow(t, driver)
	if m.follows {
		t.Fatal("scrolling up did not pause following")
	}
}

func TestFilterFieldTypingBecomesTheExpression(t *testing.T) {
	fixture, w, driver := bigFixture(t, 20)
	clickLabeled(t, driver, w.text.Logs.FilterPlaceholder)
	if err := driver.Type("level:error"); err != nil {
		t.Fatal(err)
	}
	settleWindow(t, driver)
	if got := fixture.model.prefs.Query.Expression; got != "level:error" {
		t.Fatalf("expression = %q, want what was typed", got)
	}
	// An expression the model changes (a composed term) replaces the field's text.
	fixture.model.replaceExpression("channel:app")
	settleWindow(t, driver)
	if w.filterText != "channel:app" {
		t.Fatalf("the field shows %q after the model replaced the expression", w.filterText)
	}
}

func TestFilterShortcutFocusesTheField(t *testing.T) {
	_, w, driver := bigFixture(t, 20)
	if err := driver.Chord(ui.Primary, "f"); err != nil {
		t.Fatal(err)
	}
	settleWindow(t, driver)
	settleWindow(t, driver)
	if driver.Snapshot().Focused != hitLabeled(t, driver, w.text.Logs.FilterPlaceholder).ID {
		t.Fatal("the focus is not in the filter field after the shortcut")
	}
}

func TestLevelToggleHidesALevel(t *testing.T) {
	fixture, _, driver := bigFixture(t, 20)
	if !fixture.model.levelEnabled(core.LevelError) {
		t.Fatal("ERROR is off in a new window")
	}
	clickLabeled(t, driver, "ERROR")
	if fixture.model.levelEnabled(core.LevelError) {
		t.Fatal("clicking the ERROR toggle left the level shown")
	}
}

func TestSessionMenuChoosesTheSession(t *testing.T) {
	fixture, w, driver := bigFixture(t, 20)
	clickLabeled(t, driver, w.text.Logs.SessionCurrent)
	clickLabeled(t, driver, w.text.Logs.SessionPrevious)
	if got := fixture.model.prefs.Query.Session; got != sessionPrevious {
		t.Fatalf("session = %q after choosing the previous one", got)
	}
}

func TestTimeRangeEditorAppliesAValidRange(t *testing.T) {
	fixture, w, driver := bigFixture(t, 20)
	clickLabeled(t, driver, w.text.Logs.TimeRange)
	hitLabeled(t, driver, w.text.Logs.StartTime)
	clickLabeled(t, driver, w.text.Logs.Apply)
	if fixture.model.prefs.Query.Since == "" || fixture.model.prefs.Query.Until == "" {
		t.Fatal("Apply in the time range editor left the range unset")
	}
}

func TestSavedFilterDialogSavesTheFilter(t *testing.T) {
	fixture, w, driver := bigFixture(t, 20)
	fixture.model.replaceExpression("level:warn")
	settleWindow(t, driver)
	clickLabeled(t, driver, "★ "+w.text.Logs.SavedFilters)
	clickLabeled(t, driver, w.text.Logs.SaveCurrentFilter)
	clickLabeled(t, driver, w.text.Logs.NameForFilter)
	if err := driver.Type("warnings"); err != nil {
		t.Fatal(err)
	}
	clickLabeled(t, driver, w.text.Logs.Save)
	bookmarks := fixture.model.prefs.Bookmarks
	if len(bookmarks) != 1 || bookmarks[0].Name != "warnings" || bookmarks[0].Query.Expression != "level:warn" {
		t.Fatalf("bookmarks = %+v, want the one the dialog saved", bookmarks)
	}
}

func TestSidebarClickRestrictsTheChannels(t *testing.T) {
	fixture, _, driver := bigFixture(t, 40)
	rows := sidebarRowHits(driver)
	if len(rows) < 3 {
		t.Fatalf("the channel list declared %d rows", len(rows))
	}
	clickHit(t, driver, rows[2])
	if got := fixture.model.prefs.Query.ChannelPrefixes; len(got) != 1 || got[0] != "lsp/java" {
		t.Fatalf("channels = %v after clicking the third row, want [lsp/java]", got)
	}
	clickHit(t, driver, rows[0])
	if got := fixture.model.prefs.Query.ChannelPrefixes; len(got) != 0 {
		t.Fatalf("channels = %v after choosing all channels, want none", got)
	}
}

func TestExportSheetOpensFromTheToolbarAndCancels(t *testing.T) {
	fixture, w, driver := bigFixture(t, 20)
	clickLabeled(t, driver, w.text.Logs.ExportLabel)
	if !fixture.model.export.presented {
		t.Fatal("the Export button did not present the sheet")
	}
	hitLabeled(t, driver, w.text.Logs.ExportDialog.Export)
	clickLabeled(t, driver, w.text.Logs.Cancel)
	if fixture.model.export.presented {
		t.Fatal("Cancel left the export sheet presented")
	}
}

func TestExportSheetClosesOnEscape(t *testing.T) {
	fixture, w, driver := bigFixture(t, 20)
	clickLabeled(t, driver, w.text.Logs.ExportLabel)
	if err := driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	settleWindow(t, driver)
	if fixture.model.export.presented {
		t.Fatal("Escape left the export sheet presented")
	}
}

func TestClearLogsAsksBeforeDeleting(t *testing.T) {
	fixture, w, driver := bigFixture(t, 20)
	clickLabeled(t, driver, w.text.Logs.Maintenance)
	clickLabeled(t, driver, w.text.Logs.ClearStorage(formatBytes(0)))
	hitLabeled(t, driver, w.text.Logs.ClearAction)
	if fixture.model.busy {
		t.Fatal("the logs were being cleared before the dialog was confirmed")
	}
	clickLabeled(t, driver, w.text.Logs.Cancel)
	if w.clearOpen {
		t.Fatal("Cancel left the confirmation open")
	}
}

func TestHistogramClickJumpsAndDragLimitsTheRange(t *testing.T) {
	fixture, w, driver := bigFixture(t, 200)
	m := fixture.model
	m.histogram = &core.LogHistogram{
		StartEpochMs: m.records[0].EpochMs,
		EndEpochMs:   m.records[len(m.records)-1].EpochMs,
		BucketMs:     (m.records[len(m.records)-1].EpochMs - m.records[0].EpochMs) / 10,
		Buckets:      make([]core.LogBucket, 10),
	}
	for i := range m.histogram.Buckets {
		m.histogram.Buckets[i] = core.LogBucket{Info: 3 + i, Error: i % 2}
	}
	settleWindow(t, driver)
	bars := hitLabeled(t, driver, w.text.Logs.EventsOverTime)
	y := bars.Bounds.Y + bars.Bounds.Height/2
	at := func(bucket float32) float32 { return bars.Bounds.X + bars.Bounds.Width*(bucket+0.5)/10 }

	if err := driver.Click(at(5), y); err != nil {
		t.Fatal(err)
	}
	if len(m.selection) != 1 {
		t.Fatalf("clicking a bucket selected %d records, want the first one from that time", len(m.selection))
	}
	if err := driver.Press(at(2), y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if err := driver.Move(at(6), y); err != nil {
		t.Fatal(err)
	}
	if err := driver.Release(at(6), y, gfx.PointerButtonPrimary); err != nil {
		t.Fatal(err)
	}
	if m.prefs.Query.Since == "" || m.prefs.Query.Until == "" {
		t.Fatal("dragging across buckets did not limit the time range")
	}
}

func TestDetailsTabsSwitchBetweenTheJSONAndTheCallChain(t *testing.T) {
	_, w, driver := bigFixture(t, 50)
	clickHit(t, driver, tableRowHits(driver)[1])
	clickLabeled(t, driver, w.text.Logs.CallChain)
	if w.details.tab != detailsTabTrace {
		t.Fatal("the call chain tab did not open")
	}
	clickLabeled(t, driver, w.text.Logs.Detail)
	if w.details.tab != detailsTabFields {
		t.Fatal("the detail tab did not open again")
	}
}

// querySource answers every query with a fixed collection, and holds the answer while gate
// is closed, so a test can look at a query in flight.
type querySource struct {
	*exportSource
	collection logstore.Collection

	mu      sync.Mutex
	queries []logstore.Query
	gate    chan struct{}
}

func (s *querySource) QueryWindow(ctx context.Context, q logstore.Query) (logstore.Collection, error) {
	s.mu.Lock()
	s.queries = append(s.queries, q)
	gate, collection := s.gate, s.collection
	s.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return logstore.Collection{}, ctx.Err()
		}
	}
	return collection, nil
}

func (s *querySource) seen() []logstore.Query {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.queries)
}

// pumpUntil paints the window, as its loop does when background work asks for it, until done
// holds, within a bound.
func pumpUntil(t *testing.T, driver *app.Driver, what string, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(settleLimit)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
		if err := driver.Advance(5 * time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
}

func TestQueryRunsAsTheWindowOpensAndAgainWhenTheFilterChanges(t *testing.T) {
	fixture := newExportFixture(t)
	source := &querySource{exportSource: fixture.source}
	records := make([]core.LogRecord, 30)
	for i := range records {
		records[i] = core.LogRecord{Line: "{}", Channel: "app", RelativePath: "sessions/s/app.jsonl", Ts: string(rune('a' + i)), Seq: uint64(i), Level: core.LevelInfo, Event: "app.test", Msg: "hello", FoldKey: string(rune('a' + i))}
	}
	source.collection = logstore.Collection{Directory: "/tmp/logs", Result: core.LogQueryResult{Records: records, FoldMinimumRun: 3}}
	fixture.model.opts.Source = source
	fixture.model.opts.Debounce = -1
	_, driver := openTestWindow(t, fixture.model)
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	pumpUntil(t, driver, "the first query's records", func() bool { return len(fixture.model.records) == len(records) })
	if got := len(source.seen()); got != 1 {
		t.Fatalf("the window asked %d times for its first records, want 1", got)
	}
	fixture.model.setExpression("level:warn")
	pumpUntil(t, driver, "the query for the new expression", func() bool { return len(source.seen()) == 2 })
	if got := source.seen()[1].Expression; got != "level:warn" {
		t.Fatalf("the second query's expression = %q, want the typed one", got)
	}
}

func TestANewFilterCancelsTheQueryInFlightAndOnlyItsAnswerIsApplied(t *testing.T) {
	fixture := newExportFixture(t)
	source := &querySource{exportSource: fixture.source, gate: make(chan struct{})}
	stale := []core.LogRecord{{Line: "{}", Channel: "app", RelativePath: "sessions/s/app.jsonl", Ts: "stale", Event: "app.stale", Level: core.LevelInfo}}
	source.collection = logstore.Collection{Directory: "/tmp/logs", Result: core.LogQueryResult{Records: stale, FoldMinimumRun: 3}}
	fixture.model.opts.Source = source
	fixture.model.opts.Debounce = -1
	_, driver := openTestWindow(t, fixture.model)
	if err := driver.Pump(); err != nil {
		t.Fatal(err)
	}
	pumpUntil(t, driver, "the first query to start", func() bool { return len(source.seen()) == 1 })
	fresh := []core.LogRecord{{Line: "{}", Channel: "app", RelativePath: "sessions/s/app.jsonl", Ts: "fresh", Event: "app.fresh", Level: core.LevelInfo}}
	source.mu.Lock()
	source.collection = logstore.Collection{Directory: "/tmp/logs", Result: core.LogQueryResult{Records: fresh, FoldMinimumRun: 3}}
	source.mu.Unlock()
	fixture.model.setExpression("event:app.fresh")
	pumpUntil(t, driver, "the second query to start", func() bool { return len(source.seen()) == 2 })
	close(source.gate)
	pumpUntil(t, driver, "the second query's answer", func() bool { return len(fixture.model.records) == 1 })
	if got := fixture.model.records[0].Event; got != "app.fresh" {
		t.Fatalf("the window holds the answer to %q, want the latest query's", got)
	}
}
