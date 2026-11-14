package workbench

import (
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// meterWindow drives a frameMeter the way Viva drives the workbench: a wake before every
// redraw, one or more paints in it, each between BeginFrame and EndFrame, and events in
// between. Its clock moves only when the test says so.
type meterWindow struct {
	now    time.Time
	meter  *frameMeter
	canvas gfx.Canvas
}

func newMeterWindow() *meterWindow {
	w := &meterWindow{now: time.Unix(1_700_000_000, 0)}
	w.meter = &frameMeter{now: func() time.Time { return w.now }}
	return w
}

func (w *meterWindow) wait(d time.Duration) { w.now = w.now.Add(d) }

// event runs an event callback that keeps the window thread for length.
func (w *meterWindow) event(length time.Duration) {
	w.meter.begin(true)
	w.wait(length)
	w.meter.end()
}

// wake runs the wake Viva makes before a redraw.
func (w *meterWindow) wake() {
	w.meter.begin(false)
	w.meter.end()
}

// paint runs one paint of length, which leaves a transition running when transition is true,
// and returns the readout it shows.
func (w *meterWindow) paint(length time.Duration, transition bool) int {
	w.canvas.BeginFrame()
	w.meter.beginPaint()
	w.wait(length)
	if transition {
		w.canvas.RequestFrame()
	}
	w.meter.endPaint(&w.canvas)
	w.canvas.EndFrame()
	return w.meter.shown
}

// redraw runs a wake and a paint for each of lengths, the paints of one redraw, and returns
// the readout the last one shows.
func (w *meterWindow) redraw(lengths ...time.Duration) int {
	w.wake()
	shown := 0
	for _, length := range lengths {
		shown = w.paint(length, false)
	}
	return shown
}

// next is the paint the last one asked for: after delay, or none when ok is false.
func (w *meterWindow) next() (delay time.Duration, ok bool) { return w.canvas.NextFrame() }

func TestFrameMeterIdleWindowReadsTheDisplayRate(t *testing.T) {
	w := newMeterWindow()
	// An idle editor paints for its caret alone, about twice a second; a count of paints
	// would read 2.
	for i := range 10 {
		if got := w.redraw(time.Millisecond); got != frameRateAssumed {
			t.Fatalf("idle paint %d reads %d, want %d", i, got, frameRateAssumed)
		}
		if delay, ok := w.next(); ok {
			t.Fatalf("idle paint %d asks for another after %v", i, delay)
		}
		w.wait(530 * time.Millisecond)
	}
}

func TestFrameMeterBackgroundWorkKeepsTheDisplayRate(t *testing.T) {
	w := newMeterWindow()
	// Work running off the window thread only wakes the window to show its progress, and
	// each of those paints is short.
	for i := range 200 {
		if got := w.redraw(time.Millisecond); got != frameRateAssumed {
			t.Fatalf("paint %d during background work reads %d, want %d", i, got, frameRateAssumed)
		}
		w.wait(16 * time.Millisecond)
	}
}

func TestFrameMeterStuckWindowThreadLowersTheReadoutForASecond(t *testing.T) {
	w := newMeterWindow()
	w.redraw(time.Millisecond)
	w.wait(100 * time.Millisecond)
	// A key handler keeps the window thread for half a second: thirty frames at 60 Hz, of
	// which the first was its own and 29 were held back.
	w.event(500 * time.Millisecond)
	w.wait(5 * time.Millisecond)
	if got := w.redraw(time.Millisecond); got != 31 {
		t.Fatalf("the paint after a half-second stall reads %d, want 31", got)
	}
	// The stall leaves the last second 1 ms after it: the paint after the stall was 5 ms
	// after it and ran 1 ms.
	delay, ok := w.next()
	if want := 995 * time.Millisecond; !ok || delay != want {
		t.Fatalf("the readout asks for its next paint after %v (%v), want %v", delay, ok, want)
	}
	w.wait(delay)
	if got := w.redraw(time.Millisecond); got != frameRateAssumed {
		t.Fatalf("a second after the stall the readout is %d, want %d", got, frameRateAssumed)
	}
	if delay, ok := w.next(); ok {
		t.Fatalf("the window at rest again still asks for a paint after %v", delay)
	}
}

func TestFrameMeterJoinsThePaintsOfOneRedraw(t *testing.T) {
	w := newMeterWindow()
	// A redraw that paints three times back to back runs for one stretch: three short paints
	// hold back nothing.
	if got := w.redraw(300*time.Microsecond, 300*time.Microsecond, 300*time.Microsecond); got != frameRateAssumed {
		t.Fatalf("three short paints of one redraw read %d, want %d", got, frameRateAssumed)
	}
	w.wait(200 * time.Millisecond)
	// Three paints of 10 ms are 30 ms of work, which holds back one frame. The third paint
	// is not taken for the one the second asked for: no wake came before it.
	if got := w.redraw(10*time.Millisecond, 10*time.Millisecond, 10*time.Millisecond); got != frameRateAssumed-1 {
		t.Fatalf("three 10 ms paints of one redraw read %d, want %d", got, frameRateAssumed-1)
	}
	if delay, ok := w.next(); !ok || delay != frameWindow+frameJoin {
		t.Fatalf("the redraw asks for its next paint after %v (%v), want %v", delay, ok, frameWindow+frameJoin)
	}
}

func TestFrameMeterOwnPaintsDoNotKeepAsking(t *testing.T) {
	w := newMeterWindow()
	w.redraw(time.Millisecond)
	w.wait(100 * time.Millisecond)
	w.event(time.Millisecond)
	w.wait(5 * time.Millisecond)
	// A 50 ms paint holds back two frames, which only a paint after it can show: it asks for
	// one at once.
	if got := w.redraw(50 * time.Millisecond); got != frameRateAssumed {
		t.Fatalf("the slow paint reads %d before it ran, want %d", got, frameRateAssumed)
	}
	if delay, ok := w.next(); !ok || delay != 0 {
		t.Fatalf("the slow paint asks for the next after %v (%v), want at once", delay, ok)
	}
	slowEnd := w.now
	w.wait(16 * time.Millisecond)
	// The paint it asked for is as slow, but is not counted, so it asks only for the paint
	// that shows the slow one leaving the second.
	if got := w.redraw(50 * time.Millisecond); got != frameRateAssumed-2 {
		t.Fatalf("the paint the meter asked for reads %d, want %d", got, frameRateAssumed-2)
	}
	delay, ok := w.next()
	if want := slowEnd.Add(frameWindow + frameJoin).Sub(w.now); !ok || delay != want {
		t.Fatalf("the meter's paint asks for the next after %v (%v), want %v", delay, ok, want)
	}
	w.wait(delay)
	if got := w.redraw(50 * time.Millisecond); got != frameRateAssumed {
		t.Fatalf("after the second the readout is %d, want %d", got, frameRateAssumed)
	}
	if delay, ok := w.next(); ok {
		t.Fatalf("the meter keeps asking for paints of its own, the next after %v", delay)
	}
}

func TestFrameMeterEventMakesTheNextPaintCounted(t *testing.T) {
	w := newMeterWindow()
	w.event(500 * time.Millisecond)
	w.wait(5 * time.Millisecond)
	w.redraw(time.Millisecond)
	delay, _ := w.next()
	w.wait(delay)
	// A key typed just as the meter's paint came makes the paint the key's: its time counts.
	w.event(time.Millisecond)
	w.wait(5 * time.Millisecond)
	if got := w.redraw(40 * time.Millisecond); got != frameRateAssumed {
		t.Fatalf("the paint after the key reads %d before it ran, want %d", got, frameRateAssumed)
	}
	if delay, ok := w.next(); !ok || delay != 0 {
		t.Fatalf("the 40 ms paint after a key asks for the next after %v (%v), want at once", delay, ok)
	}
	w.wait(16 * time.Millisecond)
	if got := w.redraw(time.Millisecond); got != frameRateAssumed-2 {
		t.Fatalf("the paint after the key's 40 ms paint reads %d, want %d", got, frameRateAssumed-2)
	}
}

func TestFrameMeterMeasuresTheDisplayRate(t *testing.T) {
	for _, test := range []struct {
		period time.Duration
		want   int
	}{
		{time.Second / 120, 120},
		{time.Second / 144, 144},
		{time.Second / 75, 75},
		{time.Second / 72, 72},
		// A 59.94 Hz display reads 60.
		{16_683_350 * time.Nanosecond, 60},
	} {
		w := newMeterWindow()
		// A transition runs: every redraw asks for the next on the display's beat.
		for range 20 {
			w.wake()
			w.paint(time.Millisecond, true)
			w.wait(test.period - time.Millisecond)
		}
		w.wait(time.Second)
		if got := w.redraw(time.Millisecond); got != test.want {
			t.Errorf("a window on a %v beat reads %d at rest, want %d", test.period, got, test.want)
		}
	}
}

func TestFrameMeterIgnoresIntervalsNoDisplayRuns(t *testing.T) {
	w := newMeterWindow()
	// Redraws closer together than any display runs, and further apart than a frame, are not
	// the display's beat.
	for range 20 {
		w.wake()
		w.paint(500*time.Microsecond, true)
		w.wait(2 * time.Millisecond)
	}
	for range 20 {
		w.wake()
		w.paint(time.Millisecond, true)
		w.wait(100 * time.Millisecond)
	}
	if w.meter.rate != 0 {
		t.Fatalf("redraws off any display's beat measure %d Hz, want none measured", w.meter.rate)
	}
}

func TestFrameMeterMeasuresRedrawsNotEventPasses(t *testing.T) {
	w := newMeterWindow()
	// While a transition runs at 120 Hz, a pointer press 3 ms after each redraw runs the paint
	// once more to deliver itself to a control. That pass comes without a wake and is not on
	// the display's beat.
	for range 20 {
		w.wake()
		w.paint(500*time.Microsecond, true)
		w.wait(2500 * time.Microsecond)
		w.paint(500*time.Microsecond, true)
		w.event(100 * time.Microsecond)
		w.wait(time.Second/120 - 3600*time.Microsecond)
	}
	if got := w.meter.frameRate(); got != 120 {
		t.Fatalf("a 120 Hz transition with event passes measures %d Hz, want 120", got)
	}
}

func TestFrameMeterKeepsOnlyTheLastSecondWithoutPaints(t *testing.T) {
	w := newMeterWindow()
	// A window that is never painted, as while it is hidden, still times its events: it
	// keeps only what the last second holds.
	for range 1000 {
		w.event(20 * time.Millisecond)
		w.wait(2 * time.Millisecond)
	}
	// One stretch ends every 22 ms.
	if got, most := len(w.meter.held), int(frameWindow/(22*time.Millisecond))+1; got > most {
		t.Fatalf("the meter keeps %d stretches, want at most %d", got, most)
	}
	if got := w.redraw(time.Millisecond); got != max(frameRateAssumed-len(w.meter.held), 0) {
		t.Fatalf("the readout is %d with %d stretches of one held frame", got, len(w.meter.held))
	}
}

// TestStatusBarFrameReadoutIsTheBareRate is the regression of a readout of "2 FPS" in an idle
// window: it counted paints, and an idle window paints only for its caret.
func TestStatusBarFrameReadoutIsTheBareRate(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.open(t.TempDir())
	h.button(itemFPS)
	for range 3 {
		if err := h.driver.Advance(time.Second); err != nil {
			t.Fatalf("Advance: %v", err)
		}
		if err := h.driver.Paint(); err != nil {
			t.Fatalf("Paint: %v", err)
		}
	}
	got := h.app.chromeStatusText(catalogIndex[itemFPS])
	if want := strconv.Itoa(h.app.sessions.meter.frameRate()); got != want {
		t.Fatalf("the frame readout is %q in an idle window, want the display rate %q", got, want)
	}
	if strings.Contains(got, "FPS") {
		t.Fatalf("the frame readout %q carries a unit", got)
	}
	if !h.shows(got) {
		t.Fatalf("the status bar does not show the frame readout %q", got)
	}
}
