package pluginview

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"slices"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/vivaui/viva/ui"
)

// settleDelay is how long a canvas stays still, the view's width stays the same, or the
// settings stay unchanged, before the host sends the viewport, resize or settings event:
// the contract's 400 ms for viewport and resize, which settings follow so typing in a
// declared row does not call the backend per key.
const settleDelay = 400 * time.Millisecond

// Call sends one view event to the plugin's backend and has Core check the answer. It
// runs on a goroutine of its own and returns the whole view to draw and whether it
// differs from view, the view the host drew last. ctx ends when the view closes, so the
// caller drops a late answer. A close event (closing) returns nothing.
type Call func(ctx context.Context, event, view json.RawMessage, closing bool) (json.RawMessage, bool, error)

// Options connect a Session to its host.
type Options struct {
	// Call sends events; nil leaves the view empty.
	Call Call
	// Params are the params every event of the surface carries, such as surface,
	// language and settings. It runs on the window thread when an event is sent, so an
	// event carries the values in force at that moment.
	Params func() map[string]any
	// Wake asks the window for a frame. It is called from the call's goroutine once an
	// answer arrives, and must be safe to call from any goroutine.
	Wake func()
	// Failed logs, on the window thread, a view the session cannot read although Core
	// accepted it, which the view then shows as a failure. A call's own failure is logged
	// by Call, which knows the call.
	Failed func(error)
	// Now is the clock that settles viewport and settings events; nil is time.Now.
	// Tests inject a fixed clock so a debounce never depends on real time.
	Now func() time.Time
	// Context bounds every call: the host's context for the place the view is shown in,
	// such as the open project. nil is context.Background().
	Context context.Context
	// Go runs one call off the window thread; nil starts a goroutine. It is called on the
	// window thread, so a host that waits for its background work when it ends can count
	// the call before it starts.
	Go func(work func())
	// Watch connects one showing to a backend invalidation callback.
	Watch func(instance string, refresh func()) func()
	// Page asks Core whether a changed viewport should load another bounded page.
	Page func(context.Context, any, any) error
}

// Event is one view event the host sends. Name is the contract's event name; the other
// fields apply to the events the contract lists them for.
type Event struct {
	Name     string
	Node     string
	Canvas   string
	Value    any
	Setting  string
	Item     string
	Viewport *Viewport
	Cursor   string
}

// Viewport is the visible part of a canvas in view-box coordinates.
type Viewport struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

// outcome is the answer of one call, handed from its goroutine to the window thread.
type outcome struct {
	generation uint64
	event      Event
	view       json.RawMessage
	changed    bool
	err        error
}

// settling is a viewport or settings event waiting for the input to stop.
type settling struct {
	event Event
	due   time.Time
}

// instances numbers the showings of every view in this process, so each open gets a
// new instance string.
var instances atomic.Uint64

// Session is one showing of one plugin view: a tool window's body in one workspace, or
// one settings region on an open page. All methods except the call's own goroutine run
// on the window thread.
type Session struct {
	options Options

	mu   sync.Mutex
	done *outcome

	open     bool
	instance string
	raw      json.RawMessage
	nodes    []Node
	err      error
	// failed is the event whose call failed last; Retry sends it again.
	failed     *Event
	busy       bool
	generation uint64
	cancel     context.CancelFunc
	queue      []Event
	unwatch    func()
	refresh    atomic.Bool
	watchEpoch atomic.Uint64
	settings   *settling
	viewports  map[string]*settling

	// width is the width the view's nodes are laid out in, in whole points, as the last
	// paint measured it: 0 until the first paint, and open waits for it. heard is the
	// width the last open or resize event carried, and changed is when width last
	// changed, so resize goes out once the width stays the same for settleDelay.
	width   int
	heard   int
	changed time.Time
	// inset is how much narrower than the view the nodes are laid out, and measure the
	// paint callback that measures the width, made once so a paint does not allocate it.
	inset   float32
	measure func(*ui.DrawContext)

	// fields, selects, toggles, trees and canvases are the host's own state of the
	// drawn nodes, by node ID. They live in memory and end with the showing.
	fields   map[string]*fieldState
	selects  map[string]*selectState
	toggles  map[string]*toggleState
	trees    map[string]*treeState
	canvases map[string]*canvasState
}

// NewSession returns a closed session; Open shows it.
func NewSession(options Options) *Session {
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Context == nil {
		options.Context = context.Background()
	}
	if options.Go == nil {
		options.Go = func(work func()) { go work() }
	}
	return &Session{options: options}
}

// Open shows the view: it sends open with a new instance once Measured gives the
// view's width, so the plugin lays out its first view in the space it has. A session
// already open is left as it is.
func (s *Session) Open() {
	if s == nil || s.open {
		return
	}
	s.open = true
	s.instance = "view-" + strconv.FormatUint(instances.Add(1), 10)
	if s.options.Watch != nil {
		epoch := s.watchEpoch.Add(1)
		s.unwatch = s.options.Watch(s.instance, func() {
			s.mu.Lock()
			current := s.watchEpoch.Load() == epoch
			if current {
				s.refresh.Store(true)
			}
			s.mu.Unlock()
			if current && s.options.Wake != nil {
				s.options.Wake()
			}
		})
	}
	s.queue = append(s.queue[:0], Event{Name: "open"})
	s.pump()
}

// Close hides the view: it cancels the pending call, drops its late answer and every
// waiting event, sends close when open went out, and forgets the view and the host's
// state of it.
func (s *Session) Close() {
	if s == nil || !s.open {
		return
	}
	if s.cancel != nil {
		s.cancel()
	}
	s.mu.Lock()
	s.watchEpoch.Add(1)
	s.refresh.Store(false)
	s.mu.Unlock()
	if s.unwatch != nil {
		s.unwatch()
		s.unwatch = nil
	}
	// heard is set when open goes out, so a view closed before its first paint sends
	// neither open nor close.
	if s.options.Call != nil && s.heard > 0 {
		event := s.encode(Event{Name: "close"})
		view, call := s.raw, s.options.Call
		// The close event outlives the showing, so it is not cancelled with it.
		ctx := context.WithoutCancel(s.options.Context)
		s.options.Go(func() { _, _, _ = call(ctx, event, view, true) })
	}
	// The generation moves on so a late answer is dropped; mu stays, since the cancelled
	// call's goroutine may still be about to hand its answer over.
	s.generation++
	s.open, s.instance, s.raw, s.nodes, s.err, s.failed = false, "", nil, nil, nil, nil
	s.busy, s.cancel, s.queue, s.settings, s.viewports = false, nil, nil, nil, nil
	s.width, s.heard = 0, 0
	s.fields, s.selects, s.toggles, s.trees, s.canvases = nil, nil, nil, nil, nil
}

// Measured takes the width the view's nodes are laid out in, which the paint measures.
// The first width sends the open that waits for it. A later change sends resize once
// the width stays the same for settleDelay, while the drawn view has a canvas that
// listens for it; wait is then how long until it is due, so the host asks for a frame.
func (s *Session) Measured(width float32) (wait time.Duration) {
	if s == nil || !s.open {
		return 0
	}
	w := int(math.Floor(float64(width)))
	if w < 1 || w == s.width {
		return 0
	}
	first := s.width == 0
	s.width, s.changed = w, s.options.Now()
	if first {
		s.pump()
		return 0
	}
	if !listsResize(s.nodes) {
		return 0
	}
	return settleDelay
}

// Width is the width the view's nodes are laid out in, 0 before the first paint.
func (s *Session) Width() int {
	if s == nil {
		return 0
	}
	return s.width
}

// Opened reports whether the view is showing.
func (s *Session) Opened() bool { return s != nil && s.open }

// Instance is the instance string of the current showing, empty when closed.
func (s *Session) Instance() string {
	if s == nil {
		return ""
	}
	return s.instance
}

// Send queues one event and sends it once the events before it have their answers.
func (s *Session) Send(event Event) {
	if s == nil || !s.open {
		return
	}
	s.queue = append(s.queue, event)
	s.pump()
}

// Refresh coalesces backend invalidations on the window thread.
func (s *Session) Refresh() {
	s.refresh.Store(true)
	if s.options.Wake != nil {
		s.options.Wake()
	}
}

// SettingsChanged sends settings once the values stop changing for settleDelay. A
// change while one waits restarts the wait; the event carries the values at sending.
func (s *Session) SettingsChanged() {
	if s == nil || !s.open {
		return
	}
	s.settings = &settling{event: Event{Name: "settings"}, due: s.options.Now().Add(settleDelay)}
}

// ViewportMoved sends viewport for the canvas once it stops moving for settleDelay.
func (s *Session) ViewportMoved(canvas string, viewport Viewport) {
	if s == nil || !s.open {
		return
	}
	if s.viewports == nil {
		s.viewports = map[string]*settling{}
	}
	s.viewports[canvas] = &settling{
		event: Event{Name: "viewport", Canvas: canvas, Viewport: &viewport},
		due:   s.options.Now().Add(settleDelay),
	}
}

// Take applies an answer that arrived and sends the events that are due. The host calls
// it at the start of each frame that draws the view. wait is how long until the next
// waiting event is due, 0 when none waits, so the host asks for a frame then.
func (s *Session) Take() (wait time.Duration) {
	if s == nil || !s.open {
		return 0
	}
	if s.refresh.Swap(false) {
		s.enqueue(Event{Name: "refresh"})
	}
	s.mu.Lock()
	done := s.done
	s.done = nil
	s.mu.Unlock()
	if done != nil && done.generation == s.generation {
		s.busy, s.cancel = false, nil
		s.apply(done)
	}
	now := s.options.Now()
	if s.settings != nil {
		if !now.Before(s.settings.due) {
			s.enqueue(s.settings.event)
			s.settings = nil
		} else {
			wait = s.settings.due.Sub(now)
		}
	}
	for canvas, waiting := range s.viewports {
		if !now.Before(waiting.due) {
			s.enqueue(waiting.event)
			delete(s.viewports, canvas)
			continue
		}
		if left := waiting.due.Sub(now); wait == 0 || left < wait {
			wait = left
		}
	}
	// A width the plugin has not laid out at goes out as resize once it settles. A view
	// that starts listening later hears the width that changed before it at once.
	if s.heard > 0 && s.width != s.heard && !s.queued("resize") && listsResize(s.nodes) {
		due := s.changed.Add(settleDelay)
		if !now.Before(due) {
			s.enqueue(Event{Name: "resize"})
		} else if left := due.Sub(now); wait == 0 || left < wait {
			wait = left
		}
	}
	s.pump()
	return wait
}

// queued reports an event of the name waiting to be sent.
func (s *Session) queued(name string) bool {
	return slices.ContainsFunc(s.queue, func(event Event) bool { return event.Name == name })
}

// listsResize reports a canvas among nodes, at any depth, that lists resize in its on.
func listsResize(nodes []Node) bool {
	for i := range nodes {
		n := &nodes[i]
		if n.Type == "canvas" && slices.Contains(n.On, "resize") {
			return true
		}
		if listsResize(n.Children) {
			return true
		}
	}
	return false
}

// apply takes in the answer of the call that just finished.
func (s *Session) apply(done *outcome) {
	if done.err != nil {
		if errors.Is(done.err, context.Canceled) {
			return
		}
		s.err = done.err
		event := done.event
		s.failed = &event
		return
	}
	if len(done.view) == 0 {
		return
	}
	if s.raw == nil || done.changed {
		nodes, err := Decode(done.view)
		if err != nil {
			if s.options.Failed != nil {
				s.options.Failed(err)
			}
			s.err = err
			event := done.event
			s.failed = &event
			return
		}
		s.raw, s.nodes = done.view, nodes
	}
	s.err, s.failed = nil, nil
}

// enqueue queues a settled event, merging it into a waiting one of the same kind: the
// latest settings, the latest viewport of the same canvas, or one resize, which carries
// the width at sending, is all the plugin needs.
func (s *Session) enqueue(event Event) {
	for i, waiting := range s.queue {
		if waiting.Name == event.Name && (event.Name != "viewport" || waiting.Canvas == event.Canvas) {
			s.queue = append(s.queue[:i], s.queue[i+1:]...)
			break
		}
	}
	s.queue = append(s.queue, event)
}

// pump starts the next waiting event when no call is pending and the width is known.
func (s *Session) pump() {
	if s.busy || len(s.queue) == 0 || s.options.Call == nil || s.width == 0 {
		return
	}
	event := s.queue[0]
	s.queue = s.queue[1:]
	if event.Name == "open" || event.Name == "resize" {
		// The plugin lays out its whole view at the width these carry.
		s.heard = s.width
	}
	encoded := s.encode(event)
	s.busy = true
	s.generation++
	generation, view, call, wake := s.generation, s.raw, s.options.Call, s.options.Wake
	ctx, cancel := context.WithCancel(s.options.Context)
	s.cancel = cancel
	s.options.Go(func() {
		defer cancel()
		answer, changed, err := call(ctx, encoded, view, false)
		s.mu.Lock()
		// A call of a showing that closed can answer after the call of the next showing, so
		// an older generation never replaces a newer answer that waits to be taken.
		if s.done == nil || s.done.generation < generation {
			s.done = &outcome{generation: generation, event: event, view: answer, changed: changed, err: err}
		}
		s.mu.Unlock()
		if wake != nil {
			wake()
		}
	})
}

// encode is the event's params: the surface's own params, then the event's fields.
func (s *Session) encode(event Event) json.RawMessage {
	params := map[string]any{}
	if s.options.Params != nil {
		for key, value := range s.options.Params() {
			params[key] = value
		}
	}
	params["event"], params["instance"] = event.Name, s.instance
	if s.width > 0 {
		params["width"] = s.width
	}
	if event.Node != "" {
		params["node"] = event.Node
	}
	if event.Canvas != "" {
		params["canvas"] = event.Canvas
	}
	if event.Value != nil {
		params["value"] = event.Value
	}
	if event.Setting != "" {
		params["setting"] = event.Setting
	}
	if event.Item != "" {
		params["item"] = event.Item
	}
	if event.Cursor != "" {
		params["cursor"] = event.Cursor
	}
	if event.Viewport != nil {
		params["viewport"] = event.Viewport
	}
	encoded, err := json.Marshal(params)
	if err != nil {
		encoded, _ = json.Marshal(map[string]any{"event": event.Name, "instance": s.instance})
	}
	return encoded
}

// View is the decoded view to draw, nil before the first answer.
func (s *Session) View() []Node {
	if s == nil {
		return nil
	}
	return s.nodes
}

// Drawn reports whether the view has an answer to draw.
func (s *Session) Drawn() bool { return s != nil && s.raw != nil }

// Err is the failure of the last call, nil after one succeeds.
func (s *Session) Err() error {
	if s == nil {
		return nil
	}
	return s.err
}

// Busy reports a call waiting for its answer.
func (s *Session) Busy() bool { return s != nil && s.busy }

// Retry sends the event that failed again and clears the error it left.
func (s *Session) Retry() {
	if s == nil || !s.open || s.failed == nil {
		return
	}
	event := *s.failed
	s.err, s.failed = nil, nil
	s.queue = append([]Event{event}, s.queue...)
	s.pump()
}

// fieldState is a text field's text while the user types. last is the value the view
// gave it, so a new value from the plugin replaces the text unless the field is focused;
// sent is the text the field last committed, so Enter or leaving the field sends change
// only for text that differs from it. started reports that sent holds the first text.
type fieldState struct {
	text    string
	last    string
	sent    string
	started bool
	focused bool
}

// selectState is a select's or segmented control's chosen value, kept by the host so
// the choice shows at once while the change event is on its way.
type selectState struct {
	value string
	last  string
}

// toggleState is a toggle's state, kept as selectState is.
type toggleState struct {
	on   bool
	last bool
}

// A tree keeps stable selection and expansion while the backend supplies its
// complete retained range. Lazy branches also emit expansion events.
type pageKey struct {
	Cursor, LastCursor              string
	Count, LastCount, Rows, Visible int
}

type treeState struct {
	tree ui.TreeState
	// open holds the items the user opened or closed, by item ID; an item not in it is
	// open as the plugin's expanded says.
	open map[string]bool
	// keys number the item IDs in the order they were first shown, so a row keeps its
	// focus as rows open and close above it.
	keys map[string]int
	// rows are the visible items, flattened in order, as the last paint showed them.
	rows     []treeRow
	selected string
	cursor   string
	count    int
	paging   *ui.EffectState[bool, pageKey]
}

// treeRow is one visible tree item and its depth.
type treeRow struct {
	item  *Item
	depth int
}

// flatten lists the visible items of items: each, then its children when it is open.
func (t *treeState) flatten(items []Item) {
	t.rows = t.rows[:0]
	var walk func(items []Item, depth int)
	walk = func(items []Item, depth int) {
		for i := range items {
			item := &items[i]
			t.rows = append(t.rows, treeRow{item: item, depth: depth})
			if len(item.Children) > 0 && t.expanded(item) {
				walk(item.Children, depth+1)
			}
		}
	}
	walk(items, 0)
}

// expanded reports whether item shows its children: as the user left it, else as the
// plugin's expanded says.
func (t *treeState) expanded(item *Item) bool {
	if open, ok := t.open[item.ID]; ok {
		return open
	}
	return item.Expanded
}

// key is the stable number of an item ID, given on first sight.
func (t *treeState) key(id string) int {
	key, ok := t.keys[id]
	if !ok {
		key = len(t.keys)
		t.keys[id] = key
	}
	return key
}

func (s *Session) field(id, value string) *fieldState {
	if s.fields == nil {
		s.fields = map[string]*fieldState{}
	}
	state := s.fields[id]
	if state == nil {
		state = &fieldState{text: value, last: value, sent: value}
		s.fields[id] = state
	}
	return state
}

func (s *Session) selection(id, value string) *selectState {
	if s.selects == nil {
		s.selects = map[string]*selectState{}
	}
	state := s.selects[id]
	if state == nil || state.last != value {
		state = &selectState{value: value, last: value}
		s.selects[id] = state
	}
	return state
}

func (s *Session) toggle(id string, value bool) *toggleState {
	if s.toggles == nil {
		s.toggles = map[string]*toggleState{}
	}
	state := s.toggles[id]
	if state == nil || state.last != value {
		state = &toggleState{on: value, last: value}
		s.toggles[id] = state
	}
	return state
}

func (s *Session) tree(id string) *treeState {
	if s.trees == nil {
		s.trees = map[string]*treeState{}
	}
	state := s.trees[id]
	if state == nil {
		state = &treeState{open: map[string]bool{}, keys: map[string]int{}}
		state.tree.RowHeight = 24
		state.tree.Key = func(i int) int { return state.key(state.rows[i].item.ID) }
		state.tree.Label = func(i int) string { return state.rows[i].item.Label }
		state.tree.Node = func(i int) ui.TreeNode {
			row := state.rows[i]
			return ui.TreeNode{
				Depth:    row.depth,
				Branch:   len(row.item.Children) > 0 || row.item.HasChildren,
				Expanded: state.expanded(row.item),
				Selected: row.item.ID == state.selected,
			}
		}
		s.trees[id] = state
	}
	return state
}

func (s *Session) canvas(id string) *canvasState {
	if s.canvases == nil {
		s.canvases = map[string]*canvasState{}
	}
	state := s.canvases[id]
	if state == nil {
		state = &canvasState{zoom: 1}
		s.canvases[id] = state
	}
	return state
}
