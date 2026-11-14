package workbench

import (
	"math"
	"slices"
	"time"

	"github.com/vivaui/viva/gfx"
)

// The status bar's frame readout says how many of the display's frames in the last second the
// window thread was free to present. It is there to tell a window thread that is held up from
// work that is still running in the background: the first lowers the readout, the second does
// not touch it.
//
// It cannot be a count of paints. Viva paints only when something changed, so an idle window
// paints for the caret alone, twice a second, and a count of paints reads 2 however free the
// thread is. The meter times the thread's work instead: every callback the window makes into
// the workbench, which windowSessions.config is the single entry of. A stretch of work no
// longer than one frame holds back no frame; a longer one holds back each further frame it
// lasts, as the display shows the old picture until the thread comes back. The readout is the
// display's rate less the frames held back by the stretches that ended in the last second.
// An idle window and one whose work runs off the window thread read the display's rate, and a
// stuck thread reads less, down to zero, for a second after it comes back. While it is stuck
// nothing paints at all, the readout included.
//
// Viva does not say what the display's rate is. A window presents on the display's beat, so
// the frame after a paint that left a transition running starts one period after it; the
// meter takes the period from those intervals, and assumes 60 Hz until it has seen enough of
// them. Viva's own work after a paint (handing the scene to the renderer and presenting it) is
// not a callback and is not timed.
//
// Like the rest of the workbench the meter asks for no frame while nothing changes. It asks
// for one when work it has not shown yet ended, and one when the oldest stretch it shows
// leaves the second, and only when no paint is coming sooner anyway. The paints it asked for
// are not counted, so a slow paint cannot keep asking for the next one.

const (
	// frameWindow is how far back the readout looks.
	frameWindow = time.Second
	// frameJoin joins two callbacks closer than this into one stretch of work: a wake and the
	// paint after it, or the two or three paints of one repaint.
	frameJoin = time.Millisecond
	// frameRateAssumed is the rate before the meter has measured the display's.
	frameRateAssumed = 60
	// framePeriodMin and framePeriodMax bound the intervals taken as the display's period, so
	// a second paint of the same repaint or a pause between two transitions is not one.
	framePeriodMin = time.Second / 250
	framePeriodMax = time.Second / 24
	// framePeriods is how many intervals the period is the median of, and framePeriodsNeeded
	// how many it takes before the measured rate replaces the assumed one.
	framePeriods       = 16
	framePeriodsNeeded = 5
	// frameHeldCap bounds the stretches kept. They do not overlap and each lasts longer than
	// one period, so one second holds fewer than this.
	frameHeldCap = 256
)

// frameRates are the refresh rates displays run at. A measured rate within 5% of one of them is
// taken as it, so the jitter of the measurement does not show as 119 and 121.
var frameRates = [...]int{24, 30, 48, 50, 60, 72, 75, 90, 100, 120, 144, 165, 180, 240}

// frameMeter measures the window thread for the status bar's frame readout. Its zero value is
// ready; it runs on the window thread only.
type frameMeter struct {
	// now is the clock, time.Now unless a test sets one.
	now func() time.Time
	// depth is how many callbacks are running: a callback the window makes from another one is
	// part of the outer one's stretch.
	depth int
	// open is the stretch of work going on or the last one, which the next callback joins when
	// it starts within frameJoin of its end. Its end is zero while it runs.
	open frameStretch
	// held are the closed stretches that held back a frame, in the order they ended. Those
	// that ended frameWindow ago or more no longer count and are dropped.
	held []frameHeld
	// due is when the paint the meter asked for may come, zero when it asked for none, and
	// event says an event came since it asked, which makes the next paint the event's.
	due   time.Time
	event bool
	// woke says a wake came since the last paint and no event after it, so the next paint is
	// the first of a redraw. Viva wakes the workbench before every redraw; the further paints
	// of one redraw, and the passes that deliver an event to a control, come without one.
	woke bool
	// periods is a ring of the last intervals between two frames on the display's beat;
	// counted is how many it holds, next where the next one goes and rate what they measure,
	// zero until there are framePeriodsNeeded.
	periods [framePeriods]time.Duration
	counted int
	next    int
	rate    int
	// paintStart is when the last redraw began and paintLength how long its paints ran; paced
	// says they left a transition running, so the next redraw came on the display's beat.
	paintStart  time.Time
	paintLength time.Duration
	paced       bool
	// shown is what the paint being declared shows, and shownHeld the frames it subtracted.
	shown     int
	shownHeld int
}

// frameStretch is a stretch of the window thread's work.
type frameStretch struct {
	start, end time.Time
	// own says the stretch is a paint the meter asked for, which is not counted.
	own bool
}

// frameHeld is a stretch that held back frames: when it ended and how many.
type frameHeld struct {
	end    time.Time
	frames int
}

// frameRate is the readout the window shows: frames in the last second the window thread was
// free to present. A workbench made without a window has none and reads zero.
func (s *windowSessions) frameRate() int {
	if s == nil {
		return 0
	}
	return s.meter.shown
}

func (m *frameMeter) clock() time.Time {
	if m.now != nil {
		return m.now()
	}
	return time.Now()
}

// begin marks the start of a callback of the window other than a paint: a wake when event is
// false, an event when it is true. An event is any callback but a wake or a paint; a wake comes
// before every redraw, the one the meter asked for included.
func (m *frameMeter) begin(event bool) {
	if event {
		m.event = true
	}
	if m.depth == 0 {
		m.woke = !event
	}
	m.beginAt(m.clock(), event, false)
}

func (m *frameMeter) beginAt(now time.Time, event, own bool) {
	m.depth++
	if m.depth == 1 {
		if own || m.open.start.IsZero() || m.open.end.IsZero() || now.Sub(m.open.end) >= frameJoin {
			// A paint the meter asked for starts a stretch of its own, so it does not take the
			// work before it out of the count.
			m.close(now)
			m.open = frameStretch{start: now, own: own}
		} else {
			m.open.end = time.Time{}
		}
	}
	if event {
		m.open.own = false
	}
}

// end marks the end of the callback begin marked the start of.
func (m *frameMeter) end() {
	m.depth--
	if m.depth == 0 {
		m.open.end = m.clock()
	}
}

// close records the open stretch when it held back frames, dropping those that no longer
// count at now, so a window that does not paint does not keep them.
func (m *frameMeter) close(now time.Time) {
	if m.open.own || m.open.end.IsZero() {
		return
	}
	m.prune(now)
	if frames := m.frames(m.open.end.Sub(m.open.start)); frames > 0 {
		if len(m.held) == frameHeldCap {
			m.held = slices.Delete(m.held, 0, 1)
		}
		m.held = append(m.held, frameHeld{end: m.open.end, frames: frames})
	}
	m.open = frameStretch{}
}

// beginPaint marks the start of a paint and works out what its readout shows. The paint is
// the meter's own when it is the first of a redraw that came when the meter's request was due
// and no event came since the request.
func (m *frameMeter) beginPaint() {
	now := m.clock()
	top := m.depth == 0
	redraw := top && m.woke
	own := redraw && !m.due.IsZero() && !now.Before(m.due) && !m.event
	if top {
		// A request lasts for the paint that made it: the paint asks again when it still
		// wants one.
		m.due, m.event, m.woke = time.Time{}, false, false
	}
	if redraw {
		if interval := now.Sub(m.paintStart); m.paced && !m.paintStart.IsZero() &&
			interval >= framePeriodMin && interval <= framePeriodMax && 2*m.paintLength < interval {
			m.notePeriod(interval)
		}
		m.paintStart = now
	}
	m.beginAt(now, false, own)
	m.shownHeld = m.heldFrames(now)
	m.shown = max(m.frameRate()-m.shownHeld, 0)
}

// endPaint marks the end of a paint, asking canvas for the paint that shows what the readout
// will read next, if no paint is coming sooner.
func (m *frameMeter) endPaint(canvas *gfx.Canvas) {
	now := m.clock()
	if m.depth == 1 {
		m.paintLength = now.Sub(m.paintStart)
		delay, ok := canvas.NextFrame()
		m.paced = ok && delay == 0
		if wait, ok := m.nextChange(now); ok {
			if delay, coming := canvas.NextFrame(); !coming || delay > wait {
				canvas.RequestFrameIn(wait)
				m.due = now.Add(wait)
			}
		}
	}
	m.end()
}

// nextChange says how long after now the readout reads otherwise than the paint shows: at once
// when the work since it began held back frames, or when the oldest stretch it counts leaves
// the second, plus frameJoin so the paint comes after it, not on it.
func (m *frameMeter) nextChange(now time.Time) (time.Duration, bool) {
	if m.heldFrames(now) != m.shownHeld {
		return 0, true
	}
	oldest := time.Time{}
	if len(m.held) > 0 {
		oldest = m.held[0].end
	} else if !m.open.own && m.frames(now.Sub(m.open.start)) > 0 {
		oldest = now
	}
	if oldest.IsZero() {
		return 0, false
	}
	return max(oldest.Add(frameWindow+frameJoin).Sub(now), 0), true
}

// heldFrames is how many frames the work in the second before now held back: the stretches
// that ended in it and the open one, to now when it still runs.
func (m *frameMeter) heldFrames(now time.Time) int {
	m.prune(now)
	total := 0
	for _, held := range m.held {
		total += held.frames
	}
	if !m.open.own && !m.open.start.IsZero() {
		end := m.open.end
		if end.IsZero() {
			end = now
		}
		total += m.frames(end.Sub(m.open.start))
	}
	return total
}

// prune drops the stretches that ended frameWindow before now or earlier.
func (m *frameMeter) prune(now time.Time) {
	cutoff := now.Add(-frameWindow)
	drop := 0
	for drop < len(m.held) && !m.held[drop].end.After(cutoff) {
		drop++
	}
	m.held = slices.Delete(m.held, 0, drop)
}

// frames is how many frames a stretch of work of length holds back: each frame it lasts past
// the first. It counts in whole nanoseconds of length times the rate, as a period in whole
// nanoseconds is rounded and would make half a second at 60 Hz last one frame longer.
func (m *frameMeter) frames(length time.Duration) int {
	if length <= 0 {
		return 0
	}
	return int((length*time.Duration(m.frameRate()) - 1) / time.Second)
}

// frameRate is the display's rate, measured or assumed.
func (m *frameMeter) frameRate() int {
	if m.rate > 0 {
		return m.rate
	}
	return frameRateAssumed
}

// notePeriod records one interval between two frames on the display's beat and measures the
// rate again: the median of the intervals, so a frame that came late or early does not move
// it, taken as the display rate it is closest to when that is within 5%.
func (m *frameMeter) notePeriod(interval time.Duration) {
	m.periods[m.next] = interval
	m.next = (m.next + 1) % framePeriods
	m.counted = min(m.counted+1, framePeriods)
	if m.counted < framePeriodsNeeded {
		return
	}
	sorted := m.periods
	slices.Sort(sorted[:m.counted])
	measured := float64(time.Second) / float64(sorted[m.counted/2])
	rate, off := int(measured+0.5), 0.05
	for _, known := range frameRates {
		if diff := math.Abs(measured/float64(known) - 1); diff < off {
			rate, off = known, diff
		}
	}
	m.rate = rate
}
