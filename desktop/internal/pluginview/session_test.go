package pluginview

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"
)

// received is one view event the test backend was sent.
type received struct {
	ctx     context.Context
	params  map[string]any
	view    json.RawMessage
	closing bool
}

// backend is a plugin backend under the test's control. Go only queues a call, and the test
// runs the queued calls in the order it chooses, so no assertion depends on a goroutine's
// timing; the clock moves only when the test moves it.
type backend struct {
	t       *testing.T
	now     time.Time
	params  map[string]any
	calls   []received
	pending []func()
	wakes   int
	failed  []error
	// answer is the answer to one event; nil answers a view of one label that names the event.
	answer func(params map[string]any) (json.RawMessage, bool, error)
}

func newBackend(t *testing.T) *backend {
	return &backend{
		t:      t,
		now:    time.Date(2026, 11, 19, 9, 0, 0, 0, time.UTC),
		params: map[string]any{"surface": map[string]any{"toolWindowID": "panel"}},
	}
}

func TestSessionRefreshCoalescesAndClosedShowingCannotRefreshTheNext(t *testing.T) {
	b := newBackend(t)
	var refresh func()
	unwatched := 0
	s := b.session(func(o *Options) {
		o.Watch = func(_ string, callback func()) func() {
			refresh = callback
			return func() { unwatched++ }
		}
	})
	show(s)
	refresh()
	refresh()
	s.Take()
	b.answered(s)
	b.answered(s)
	if got := b.events(); !slices.Equal(got, []string{"open", "refresh"}) {
		t.Fatalf("events=%v", got)
	}
	old := refresh
	s.Close()
	show(s)
	old()
	s.Take()
	if unwatched != 1 || len(s.queue) != 0 {
		t.Fatalf("old callback queued work after reopen: %v", s.queue)
	}
}

// session is a closed session wired to the backend; it closes with the test.
func (b *backend) session(adjust ...func(*Options)) *Session {
	options := Options{
		Call: b.call,
		Params: func() map[string]any {
			params := map[string]any{}
			for key, value := range b.params {
				params[key] = value
			}
			return params
		},
		Wake:   func() { b.wakes++ },
		Failed: func(err error) { b.failed = append(b.failed, err) },
		Now:    func() time.Time { return b.now },
		Go:     func(work func()) { b.pending = append(b.pending, work) },
	}
	for _, fn := range adjust {
		fn(&options)
	}
	s := NewSession(options)
	b.t.Cleanup(s.Close)
	return s
}

func (b *backend) call(ctx context.Context, event, view json.RawMessage, closing bool) (json.RawMessage, bool, error) {
	var params map[string]any
	if err := json.Unmarshal(event, &params); err != nil {
		b.t.Errorf("event %s is not a JSON object: %v", event, err)
	}
	b.calls = append(b.calls, received{ctx: ctx, params: params, view: view, closing: closing})
	if closing {
		return nil, false, nil
	}
	if b.answer != nil {
		return b.answer(params)
	}
	name, _ := params["event"].(string)
	return labelView(name), true, nil
}

// labelView is a view of one label with text.
func labelView(text string) json.RawMessage {
	view, _ := json.Marshal([]map[string]any{{"type": "label", "id": "status", "text": text}})
	return view
}

// run runs the oldest queued call.
func (b *backend) run() {
	b.t.Helper()
	if len(b.pending) == 0 {
		b.t.Fatal("no call is waiting to run")
	}
	work := b.pending[0]
	b.pending = b.pending[1:]
	work()
}

// answered runs the oldest queued call and has the session take its answer.
func (b *backend) answered(s *Session) {
	b.t.Helper()
	b.run()
	s.Take()
}

// events are the names of the events the backend was sent, in order.
func (b *backend) events() []string {
	names := make([]string, 0, len(b.calls))
	for _, call := range b.calls {
		name, _ := call.params["event"].(string)
		names = append(names, name)
	}
	return names
}

// last is the params of the last event the backend was sent.
func (b *backend) last() map[string]any {
	b.t.Helper()
	if len(b.calls) == 0 {
		b.t.Fatal("the backend was sent no event")
	}
	return b.calls[len(b.calls)-1].params
}

// testWidth is the width the tests' first paint measures.
const testWidth = 600

// show opens the session and measures its width, as the first paint of the view does.
func show(s *Session) {
	s.Open()
	s.Measured(testWidth)
}

// resizeView is a view whose canvas lays itself out at the width and listens for resize.
func resizeView() json.RawMessage {
	return json.RawMessage(`[{"type":"canvas","id":"fit","label":"Fit","height":120,"viewBox":[0,0,600,120],"on":["resize"],"nodes":[]}]`)
}

// shown is the text of the session's label, which names the event that drew it.
func shown(t *testing.T, s *Session) string {
	t.Helper()
	nodes := s.View()
	if len(nodes) != 1 {
		t.Fatalf("view = %+v, want one label", nodes)
	}
	return nodes[0].Text
}

func TestSessionOpenSendsOpenAndDrawsTheAnswer(t *testing.T) {
	b := newBackend(t)
	s := b.session()
	s.Open()
	if !s.Opened() || s.Busy() || len(b.pending) != 0 {
		t.Fatalf("before the first paint: opened %v, busy %v, %d calls queued", s.Opened(), s.Busy(), len(b.pending))
	}
	if s.Measured(0.5) != 0 || len(b.pending) != 0 {
		t.Fatal("a width under one point sent open")
	}
	s.Measured(612.7)
	if !s.Busy() || len(b.pending) != 1 || s.Width() != 612 {
		t.Fatalf("after the first paint: busy %v, %d calls queued, width %d", s.Busy(), len(b.pending), s.Width())
	}
	if s.Drawn() {
		t.Fatal("a view is drawn before the backend answered")
	}
	b.run()
	if b.wakes != 1 {
		t.Fatalf("wakes = %d, want 1 once the answer arrived", b.wakes)
	}
	if wait := s.Take(); wait != 0 {
		t.Fatalf("Take waits %v with nothing settling", wait)
	}
	if s.Busy() || !s.Drawn() || s.Err() != nil || shown(t, s) != "open" {
		t.Fatalf("after the answer: busy %v, drawn %v, err %v", s.Busy(), s.Drawn(), s.Err())
	}
	call := b.calls[0]
	if call.params["event"] != "open" || call.view != nil || call.closing {
		t.Fatalf("open call = %+v, want open with no drawn view", call)
	}
	if call.params["width"] != 612.0 {
		t.Fatalf("open width = %v, want the measured width in whole points", call.params["width"])
	}
	if instance := s.Instance(); !strings.HasPrefix(instance, "view-") || call.params["instance"] != instance {
		t.Fatalf("instance = %q, sent %v", instance, call.params["instance"])
	}
	if _, ok := call.params["surface"]; !ok {
		t.Fatalf("open params %v lost the surface's own params", call.params)
	}
	s.Open()
	if len(b.pending) != 0 {
		t.Fatal("Open on a showing view sent another open")
	}
}

func TestSessionSendsOneEventAtATimeWithTheDrawnView(t *testing.T) {
	b := newBackend(t)
	s := b.session()
	show(s)
	b.answered(s)
	s.Send(Event{Name: "click", Node: "refresh"})
	s.Send(Event{Name: "change", Node: "filter", Value: "core"})
	if len(b.pending) != 1 {
		t.Fatalf("%d calls run at once, want one at a time", len(b.pending))
	}
	b.answered(s)
	if string(b.calls[1].view) != string(labelView("open")) {
		t.Fatalf("click carried view %s, want the view drawn last", b.calls[1].view)
	}
	if len(b.pending) != 1 {
		t.Fatalf("the change did not follow the click's answer: %d calls queued", len(b.pending))
	}
	b.answered(s)
	if got := b.events(); !slices.Equal(got, []string{"open", "click", "change"}) {
		t.Fatalf("events = %v", got)
	}
	if last := b.last(); last["node"] != "filter" || last["value"] != "core" {
		t.Fatalf("change params = %v", last)
	}
	if shown(t, s) != "change" {
		t.Fatalf("view shows %q, want the last answer", shown(t, s))
	}
}

func TestSessionSettlesSettingsAndSendsTheValuesAtSending(t *testing.T) {
	b := newBackend(t)
	s := b.session()
	show(s)
	b.answered(s)
	s.SettingsChanged()
	b.now = b.now.Add(100 * time.Millisecond)
	if wait := s.Take(); wait != 300*time.Millisecond || len(b.pending) != 0 {
		t.Fatalf("100 ms after a change: wait %v, %d calls", wait, len(b.pending))
	}
	b.now = b.now.Add(200 * time.Millisecond)
	s.SettingsChanged()
	b.params["settings"] = map[string]any{"jdk": "21"}
	b.now = b.now.Add(300 * time.Millisecond)
	if wait := s.Take(); wait != 100*time.Millisecond || len(b.pending) != 0 {
		t.Fatalf("a second change did not restart the wait: wait %v, %d calls", wait, len(b.pending))
	}
	b.now = b.now.Add(100 * time.Millisecond)
	if wait := s.Take(); wait != 0 || len(b.pending) != 1 {
		t.Fatalf("once settled: wait %v, %d calls", wait, len(b.pending))
	}
	b.answered(s)
	if got := b.events(); !slices.Equal(got, []string{"open", "settings"}) {
		t.Fatalf("events = %v, want one settings event", got)
	}
	settings, _ := b.last()["settings"].(map[string]any)
	if settings["jdk"] != "21" {
		t.Fatalf("settings params = %v, want the values at sending", b.last())
	}
}

func TestSessionMergesWaitingViewportsPerCanvas(t *testing.T) {
	b := newBackend(t)
	s := b.session()
	show(s)
	s.ViewportMoved("graph", Viewport{X: 1, Width: 10, Height: 10})
	s.ViewportMoved("minimap", Viewport{X: 2, Width: 5, Height: 5})
	b.now = b.now.Add(settleDelay)
	s.Take()
	s.ViewportMoved("graph", Viewport{X: 3, Width: 10, Height: 10})
	b.now = b.now.Add(settleDelay)
	s.Take()
	for len(b.pending) > 0 {
		b.answered(s)
	}
	if got := b.events(); !slices.Equal(got, []string{"open", "viewport", "viewport"}) {
		t.Fatalf("events = %v, want open and one viewport per canvas", got)
	}
	minimap, graph := b.calls[1].params, b.calls[2].params
	if minimap["canvas"] != "minimap" || graph["canvas"] != "graph" {
		t.Fatalf("viewport canvases = %v, %v", minimap["canvas"], graph["canvas"])
	}
	if viewport, _ := graph["viewport"].(map[string]any); viewport["x"] != 3.0 {
		t.Fatalf("graph viewport = %v, want the latest one", graph["viewport"])
	}
}

func TestSessionCloseDropsTheLateAnswerAndSendsClose(t *testing.T) {
	b := newBackend(t)
	s := b.session()
	show(s)
	first := s.Instance()
	s.Close()
	if s.Opened() || s.Instance() != "" || len(b.pending) != 2 {
		t.Fatalf("after Close: opened %v, instance %q, %d calls queued", s.Opened(), s.Instance(), len(b.pending))
	}
	b.run()
	if err := b.calls[0].ctx.Err(); !errors.Is(err, context.Canceled) {
		t.Fatalf("the pending call's context = %v, want cancelled by Close", err)
	}
	b.run()
	closing := b.calls[1]
	if !closing.closing || closing.params["event"] != "close" || closing.params["instance"] != first {
		t.Fatalf("close call = %+v", closing)
	}
	if closing.params["width"] != float64(testWidth) {
		t.Fatalf("close width = %v", closing.params["width"])
	}
	if err := closing.ctx.Err(); err != nil {
		t.Fatalf("the close call's context = %v, want it to outlive the showing", err)
	}
	if s.Take() != 0 || s.Drawn() {
		t.Fatal("a closed session took the late answer")
	}
	show(s)
	if s.Instance() == first || s.Instance() == "" {
		t.Fatalf("reopening kept instance %q", s.Instance())
	}
	b.answered(s)
	if !s.Drawn() || s.Busy() || shown(t, s) != "open" {
		t.Fatalf("the reopened view: drawn %v, busy %v", s.Drawn(), s.Busy())
	}
}

func TestSessionKeepsTheNewerAnswerWhenAClosedShowingAnswersLate(t *testing.T) {
	b := newBackend(t)
	b.answer = func(params map[string]any) (json.RawMessage, bool, error) {
		instance, _ := params["instance"].(string)
		return labelView(instance), true, nil
	}
	s := b.session()
	show(s)
	s.Close()
	show(s)
	if len(b.pending) != 3 {
		t.Fatalf("%d calls queued, want the first open, close and the second open", len(b.pending))
	}
	stale, closing, reopened := b.pending[0], b.pending[1], b.pending[2]
	b.pending = nil
	reopened()
	stale()
	closing()
	s.Take()
	if s.Busy() || !s.Drawn() || shown(t, s) != s.Instance() {
		t.Fatalf("after a late answer of the closed showing: busy %v, drawn %v", s.Busy(), s.Drawn())
	}
}

func TestSessionRetrySendsTheFailedEventAgain(t *testing.T) {
	b := newBackend(t)
	failures := 1
	b.answer = func(params map[string]any) (json.RawMessage, bool, error) {
		if params["event"] == "click" && failures > 0 {
			failures--
			return nil, false, errors.New("backend stopped")
		}
		name, _ := params["event"].(string)
		return labelView(name), true, nil
	}
	s := b.session()
	show(s)
	b.answered(s)
	s.Send(Event{Name: "click", Node: "refresh"})
	b.answered(s)
	if s.Err() == nil || !s.Drawn() || shown(t, s) != "open" {
		t.Fatalf("after a failed call: err %v, drawn %v, want the error over the last view", s.Err(), s.Drawn())
	}
	if len(b.failed) != 0 {
		t.Fatalf("Failed logged %v; a call's own failure is the caller's to log", b.failed)
	}
	s.Retry()
	if s.Err() != nil || len(b.pending) != 1 {
		t.Fatalf("after Retry: err %v, %d calls queued", s.Err(), len(b.pending))
	}
	b.answered(s)
	if got := b.events(); !slices.Equal(got, []string{"open", "click", "click"}) || b.last()["node"] != "refresh" {
		t.Fatalf("events = %v, last %v", got, b.last())
	}
	if s.Err() != nil || shown(t, s) != "click" {
		t.Fatalf("after the retried call: err %v", s.Err())
	}
}

func TestSessionLogsAViewItCannotRead(t *testing.T) {
	b := newBackend(t)
	b.answer = func(params map[string]any) (json.RawMessage, bool, error) {
		if params["event"] == "click" {
			return json.RawMessage(`{"type":"label"}`), true, nil
		}
		return labelView("open"), true, nil
	}
	s := b.session()
	show(s)
	b.answered(s)
	s.Send(Event{Name: "click", Node: "refresh"})
	b.answered(s)
	if len(b.failed) != 1 || s.Err() == nil {
		t.Fatalf("failed %v, err %v, want the unreadable view logged and shown", b.failed, s.Err())
	}
	if shown(t, s) != "open" {
		t.Fatal("an unreadable view replaced the last one")
	}
	s.Retry()
	if len(b.pending) != 1 {
		t.Fatal("Retry did not send the event whose view could not be read")
	}
}

func TestSessionIgnoresACancelledCall(t *testing.T) {
	b := newBackend(t)
	b.answer = func(params map[string]any) (json.RawMessage, bool, error) {
		if params["event"] == "click" {
			return nil, false, context.Canceled
		}
		return labelView("open"), true, nil
	}
	s := b.session()
	show(s)
	b.answered(s)
	s.Send(Event{Name: "click"})
	b.answered(s)
	if s.Err() != nil || s.Busy() {
		t.Fatalf("a cancelled call left err %v, busy %v", s.Err(), s.Busy())
	}
	s.Retry()
	if len(b.pending) != 0 {
		t.Fatal("Retry resent a cancelled call")
	}
}

func TestSessionKeepsTheViewForAnEmptyOrUnchangedAnswer(t *testing.T) {
	b := newBackend(t)
	b.answer = func(params map[string]any) (json.RawMessage, bool, error) {
		switch params["event"] {
		case "click":
			return nil, false, nil
		case "change":
			// Core reports the view unchanged, so the host does not read it again.
			return json.RawMessage(`not a view`), false, nil
		}
		return labelView("open"), true, nil
	}
	s := b.session()
	show(s)
	b.answered(s)
	s.Send(Event{Name: "click"})
	b.answered(s)
	s.Send(Event{Name: "change", Value: "x"})
	b.answered(s)
	if s.Err() != nil || len(b.failed) != 0 || shown(t, s) != "open" {
		t.Fatalf("err %v, failed %v, want the drawn view kept", s.Err(), b.failed)
	}
}

func TestSessionEncodesTheEventOverTheSurfaceParams(t *testing.T) {
	b := newBackend(t)
	b.params["event"], b.params["instance"] = "spoofed", "spoofed"
	s := b.session()
	show(s)
	b.answered(s)
	if _, ok := b.calls[0].params["node"]; ok {
		t.Fatalf("open params %v carry a node", b.calls[0].params)
	}
	s.Send(Event{
		Name: "activate", Node: "modules", Item: "core", Setting: "jdk", Value: 3, Canvas: "graph",
		Viewport: &Viewport{X: 1, Y: 2, Width: 30, Height: 40},
	})
	b.run()
	params := b.last()
	want := map[string]any{
		"event": "activate", "instance": s.Instance(), "node": "modules", "item": "core",
		"setting": "jdk", "value": 3.0, "canvas": "graph", "width": float64(testWidth),
	}
	for key, value := range want {
		if params[key] != value {
			t.Errorf("params[%q] = %v, want %v", key, params[key], value)
		}
	}
	viewport, _ := params["viewport"].(map[string]any)
	if viewport["y"] != 2.0 || viewport["height"] != 40.0 {
		t.Errorf("viewport = %v", params["viewport"])
	}
	if _, ok := params["surface"]; !ok {
		t.Errorf("params %v lost the surface's own params", params)
	}
}

func TestSessionCallsEndWithTheHostContext(t *testing.T) {
	b := newBackend(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s := b.session(func(options *Options) { options.Context = ctx })
	show(s)
	cancel()
	b.run()
	if err := b.calls[0].ctx.Err(); !errors.Is(err, context.Canceled) {
		t.Fatalf("call context = %v, want it to end with the host's", err)
	}
}

func TestSessionTakesNoInputWhileClosed(t *testing.T) {
	b := newBackend(t)
	s := b.session()
	s.Send(Event{Name: "click"})
	s.SettingsChanged()
	s.ViewportMoved("graph", Viewport{Width: 1, Height: 1})
	s.Retry()
	if s.Measured(500) != 0 || s.Width() != 0 {
		t.Fatal("a closed session took a width")
	}
	b.now = b.now.Add(settleDelay)
	if s.Take() != 0 || len(b.pending) != 0 || len(b.calls) != 0 {
		t.Fatalf("a closed session sent %d events", len(b.pending)+len(b.calls))
	}
	var none *Session
	none.Open()
	none.Send(Event{Name: "click"})
	none.Measured(500)
	none.Close()
	if none.Opened() || none.Drawn() || none.Busy() || none.Err() != nil || none.View() != nil || none.Instance() != "" {
		t.Fatal("a nil session reports a view")
	}
}

func TestSessionSendsResizeOnceTheWidthSettles(t *testing.T) {
	b := newBackend(t)
	b.answer = func(params map[string]any) (json.RawMessage, bool, error) { return resizeView(), true, nil }
	s := b.session()
	show(s)
	b.answered(s)
	if wait := s.Measured(500); wait != settleDelay {
		t.Fatalf("a new width waits %v, want %v", wait, settleDelay)
	}
	b.now = b.now.Add(100 * time.Millisecond)
	if wait := s.Take(); wait != 300*time.Millisecond || len(b.pending) != 0 {
		t.Fatalf("100 ms after the width changed: wait %v, %d calls", wait, len(b.pending))
	}
	b.now = b.now.Add(100 * time.Millisecond)
	s.Measured(450)
	b.now = b.now.Add(300 * time.Millisecond)
	if wait := s.Take(); wait != 100*time.Millisecond || len(b.pending) != 0 {
		t.Fatalf("a second change did not restart the wait: wait %v, %d calls", wait, len(b.pending))
	}
	// An event in between carries the width, but the plugin lays out again only on resize.
	s.Send(Event{Name: "click", Node: "refresh"})
	b.answered(s)
	if b.last()["width"] != 450.0 {
		t.Fatalf("click width = %v", b.last()["width"])
	}
	b.now = b.now.Add(100 * time.Millisecond)
	if wait := s.Take(); wait != 0 || len(b.pending) != 1 {
		t.Fatalf("once settled: wait %v, %d calls", wait, len(b.pending))
	}
	b.answered(s)
	if got := b.events(); !slices.Equal(got, []string{"open", "click", "resize"}) || b.last()["width"] != 450.0 {
		t.Fatalf("events = %v, last %v", got, b.last())
	}
	b.now = b.now.Add(time.Second)
	if wait := s.Take(); wait != 0 || len(b.pending) != 0 {
		t.Fatalf("a width the plugin laid out at sent resize again: wait %v, %d calls", wait, len(b.pending))
	}
}

func TestSessionMergesAWaitingResizeAndSendsTheWidthAtSending(t *testing.T) {
	b := newBackend(t)
	b.answer = func(params map[string]any) (json.RawMessage, bool, error) { return resizeView(), true, nil }
	s := b.session()
	show(s)
	b.answered(s)
	s.Send(Event{Name: "click", Node: "refresh"})
	s.Measured(500)
	b.now = b.now.Add(settleDelay)
	s.Take()
	s.Measured(450)
	b.now = b.now.Add(settleDelay)
	s.Take()
	for len(b.pending) > 0 {
		b.answered(s)
	}
	if got := b.events(); !slices.Equal(got, []string{"open", "click", "resize"}) || b.last()["width"] != 450.0 {
		t.Fatalf("events = %v, last %v, want one resize with the latest width", got, b.last())
	}
}

func TestSessionSendsNoResizeWithoutACanvasThatListens(t *testing.T) {
	b := newBackend(t)
	listens := false
	b.answer = func(params map[string]any) (json.RawMessage, bool, error) {
		if listens {
			return resizeView(), true, nil
		}
		return labelView("open"), true, nil
	}
	s := b.session()
	show(s)
	b.answered(s)
	if wait := s.Measured(500); wait != 0 {
		t.Fatalf("a view without a resize canvas waits %v", wait)
	}
	b.now = b.now.Add(time.Second)
	if wait := s.Take(); wait != 0 || len(b.pending) != 0 {
		t.Fatalf("a view without a resize canvas: wait %v, %d calls", wait, len(b.pending))
	}
	// A view that starts listening hears the width that changed before it at once.
	listens = true
	s.Send(Event{Name: "click", Node: "refresh"})
	b.answered(s)
	if len(b.pending) != 1 {
		t.Fatalf("%d calls queued, want the resize the new canvas listens for", len(b.pending))
	}
	b.answered(s)
	if got := b.events(); !slices.Equal(got, []string{"open", "click", "resize"}) || b.last()["width"] != 500.0 {
		t.Fatalf("events = %v, last %v", got, b.last())
	}
}

func TestSessionClosedBeforeItsFirstPaintSendsNothing(t *testing.T) {
	b := newBackend(t)
	s := b.session()
	s.Open()
	s.Close()
	if len(b.pending) != 0 || len(b.calls) != 0 {
		t.Fatalf("a view closed before its first paint sent %d events", len(b.pending)+len(b.calls))
	}
	show(s)
	b.answered(s)
	if got := b.events(); !slices.Equal(got, []string{"open"}) || shown(t, s) != "open" {
		t.Fatalf("events = %v after reopening", got)
	}
}
