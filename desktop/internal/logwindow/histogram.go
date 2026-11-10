package logwindow

import (
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The metrics of the strip, after the macOS client's LogHistogramView.
const (
	// histogramHeight is the height of the whole strip, with its bottom line.
	histogramHeight = 72
	// histogramInset is the strip's padding at its leading and trailing ends.
	histogramInset = 10
	// histogramBarMax is the height of the tallest bucket.
	histogramBarMax = 34
	// histogramGap is the space between two buckets.
	histogramGap = 1
	// histogramTimeFormat writes the times under the chart and in the bucket tooltips:
	// month, day and the time to the second. The macOS client lets the system's locale
	// order them; this one writes them in one order in every language.
	histogramTimeFormat = "01/02 15:04:05"
)

// histogramState is the part of the histogram that outlives a frame: the control that takes
// the pointer on the chart, the bucket it rests on and the time range the user is dragging
// out.
type histogramState struct {
	window *window
	// handlers and draw are made once: the page holds the handlers for a paint, and a method
	// value made in each paint would allocate.
	handlers ui.Handlers
	draw     func(*ui.DrawContext)
	// bars is where the chart was drawn, in window coordinates, which maps the pointer to a
	// bucket.
	bars ui.Rect
	// hover is the bucket under the pointer, or -1.
	hover int
	// active says a press on the chart is held and start..end is being dragged out. start is
	// the bucket the press began on, end the bucket the pointer is over now. The range is
	// highlighted from the lower of the two to the higher.
	active     bool
	start, end int
}

func (h *histogramState) init(w *window) {
	h.window = w
	h.hover = -1
	h.handlers = ui.Handlers{Pointer: h.pointer}
	h.draw = h.paint
}

// histogramStrip is the strip above the table: a legend and a hint at the leading end, the
// events of the log over time as stacked bars, and the first, middle and last time of the
// chart under the bars. A click on a bar jumps to the first record from that time; a drag
// limits the table to the time range it covers.
func (w *window) histogramStrip(c ui.C) {
	histogram := w.model.histogram
	h := &w.histogram
	ui.Stack(c).FillWidth().Height(histogramHeight).Shrink(0).Background(w.pal.bg2).Children(func() {
		ui.Row(c).Fill().PadSides(6, histogramInset, 4, histogramInset).Children(func() {
			w.histogramLegend(c)
			ui.Column(c).Grow(1).MinWidth(0).Gap(2).Children(func() {
				bars := ui.Control(c, w.text.Logs.EventsOverTime, &h.handlers).Grow(1).MinHeight(0).FillWidth().Draw(h.draw)
				if histogram != nil && h.hover >= 0 && h.hover < len(histogram.Buckets) {
					bucket := histogram.Buckets[h.hover]
					bars.Tooltip(w.text.Logs.HistogramTooltip(
						histogramTime(histogram.StartEpochMs+int64(h.hover)*histogram.BucketMs),
						bucket.Error, bucket.Warn, bucket.Info+bucket.Debug))
				}
				if histogram != nil {
					w.histogramTimes(c, histogram)
				}
			})
		})
		// The line along the bottom edge is drawn over the strip and takes no room from it.
		ui.Row(c).Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
	})
}

// histogramLegend is the text at the leading end of the strip: the chart's title, what the
// colors stand for and how to use the chart. It is as wide as the channel list below it and
// centered along the strip, as the macOS client's is.
func (w *window) histogramLegend(c ui.C) {
	text := func(s string) ui.Box {
		return w.mono(c, s, 11, w.pal.tx3).LineHeight(13)
	}
	ui.Column(c).Width(sidebarWidth).Shrink(0).Self(ui.Center).Children(func() {
		text(w.text.Logs.EventsOverTime).Ellipsis()
		ui.Row(c).Gap(4).Children(func() {
			for _, key := range []struct {
				name  string
				color ui.Color
			}{{"ERROR", w.pal.red}, {"WARN", w.pal.yel}, {"INFO", w.pal.blu}} {
				w.mono(c, "■", 11, key.color).LineHeight(13)
				text(key.name)
			}
		})
		// The hint is longer than the legend is wide in some languages, and ends in an
		// ellipsis there.
		text(w.text.Logs.HistogramHint).Ellipsis()
	})
}

// paint draws one column per bucket, side by side, each one stacking its errors on its
// warnings on the rest, from the top down, and growing from the bottom of the chart. The
// tallest bucket reaches histogramBarMax. The buckets of the range being dragged out are
// tinted.
func (h *histogramState) paint(d *ui.DrawContext) {
	h.bars = d.Rect
	w := h.window
	histogram := w.model.histogram
	if histogram == nil || len(histogram.Buckets) == 0 {
		return
	}
	n := len(histogram.Buckets)
	maximum := 1
	for _, bucket := range histogram.Buckets {
		maximum = max(maximum, bucket.Debug+bucket.Info+bucket.Warn+bucket.Error)
	}
	scale := float32(histogramBarMax) / float32(maximum)
	lo, hi := min(h.start, h.end), max(h.start, h.end)
	width := max(0, (d.Rect.Width-float32(n-1)*histogramGap)/float32(n))
	bottom := d.Rect.Y + d.Rect.Height
	for i, bucket := range histogram.Buckets {
		x := d.Rect.X + float32(i)*(width+histogramGap)
		if h.active && i >= lo && i <= hi {
			// The gap between two buckets belongs to the chart as well, so a drag never
			// crosses a dead line.
			d.Canvas.Fill(gfx.Rect{X: x, Y: d.Rect.Y, Width: width + histogramGap, Height: d.Rect.Height}, d.Fade(w.pal.blu.WithAlpha(0.16)))
		}
		other := bucket.Info + bucket.Debug
		y := bottom
		for _, bar := range [3]struct {
			count int
			color ui.Color
		}{{other, w.pal.blu.WithAlpha(0.4)}, {bucket.Warn, w.pal.yel}, {bucket.Error, w.pal.red}} {
			if bar.count <= 0 {
				continue
			}
			height := float32(bar.count) * scale
			y -= height
			d.Canvas.Fill(gfx.Rect{X: x, Y: y, Width: width, Height: height}, d.Fade(bar.color))
		}
	}
}

// histogramTimes is the line under the bars with the time the chart starts, the time in its
// middle and the time it ends.
func (w *window) histogramTimes(c ui.C, histogram *core.LogHistogram) {
	stamp := func(ms int64) {
		w.mono(c, histogramTime(ms), 10, w.pal.tx3).LineHeight(12).Shrink(0)
	}
	ui.Row(c).Shrink(0).Items(ui.Center).Children(func() {
		stamp(histogram.StartEpochMs)
		ui.Spacer(c)
		stamp(histogram.StartEpochMs + (histogram.EndEpochMs-histogram.StartEpochMs)/2)
		ui.Spacer(c)
		stamp(histogram.EndEpochMs)
	})
}

// pointer follows the pointer on the chart. Pressing starts a range at the bucket under the
// pointer, moving with the press held stretches it, and releasing either jumps to the time of
// the bucket (the range is one bucket) or limits the table to the buckets covered.
func (h *histogramState) pointer(event gfx.PointerEvent) gfx.EventResult {
	repaint := gfx.EventResult{Handled: true, Repaint: true}
	histogram := h.window.model.histogram
	if histogram == nil || len(histogram.Buckets) == 0 {
		h.active, h.hover = false, -1
		return gfx.EventResult{}
	}
	at := histogramBucket(event.X-h.bars.X, h.bars.Width, len(histogram.Buckets))
	switch event.Kind {
	case gfx.PointerDown:
		if event.Button != gfx.PointerButtonPrimary {
			return gfx.EventResult{}
		}
		h.active, h.start, h.end = true, at, at
		return repaint
	case gfx.PointerMove:
		h.hover = at
		if h.active {
			h.end = at
		}
		return repaint
	case gfx.PointerExit:
		h.hover = -1
		return repaint
	case gfx.PointerUp:
		if !h.active {
			return gfx.EventResult{}
		}
		h.active = false
		if h.start == at {
			h.window.model.jump(histogram.StartEpochMs + int64(at)*histogram.BucketMs)
			return repaint
		}
		lo, hi := min(h.start, at), max(h.start, at)
		h.window.model.setRange(
			histogram.StartEpochMs+int64(lo)*histogram.BucketMs,
			histogram.StartEpochMs+int64(hi+1)*histogram.BucketMs-1)
		return repaint
	}
	return gfx.EventResult{}
}

// histogramBucket is the bucket under x, a distance from the chart's leading edge, when the
// chart is width wide and has count buckets. A point outside the chart is on the nearest
// bucket, so a drag that leaves the chart keeps its range at the chart's end.
func histogramBucket(x, width float32, count int) int {
	position := x / max(1, width) * float32(count)
	position = min(max(position, 0), float32(count))
	return min(int(position), max(0, count-1))
}

// histogramTime writes a time in milliseconds since the epoch, in the local time zone.
func histogramTime(ms int64) string {
	return time.UnixMilli(ms).Format(histogramTimeFormat)
}
