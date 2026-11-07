package logwindow

import (
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/flex"
	"github.com/vivaui/viva/ui"
)

// The identities of the histogram. Each bucket of the chart is a hit of its own, so each
// one has a tooltip and a press on it is captured while the pointer drags across the chart.
var (
	histogramScope       = tree.Sub(page, tree.Name("histogram"))
	histogramBucketScope = tree.Sub(histogramScope, tree.Name("buckets"))
)

// The metrics of the strip, after the macOS client's LogHistogramView.
const (
	// histogramHeight is the height of the whole strip, with its bottom line.
	histogramHeight = 72
	// histogramInset is the strip's padding at its leading and trailing ends.
	histogramInset = 10
	// histogramBarMax is the height of the tallest bucket.
	histogramBarMax = 34
	// histogramTimeFormat writes the times under the chart and in the bucket tooltips:
	// month, day and the time to the second. The macOS client lets the system's locale
	// order them; this one writes them in one order in every language.
	histogramTimeFormat = "01/02 15:04:05"
)

// histogramState is the part of the histogram that outlives a frame: the time range the
// user is dragging out.
type histogramState struct {
	// active says a press on the chart is held and start..end is being dragged out.
	active bool
	// start is the bucket the press began on, end the bucket the pointer is over now. The
	// range is highlighted from the lower of the two to the higher.
	start, end int
}

// drawHistogram is the strip above the table: a legend and a hint at the leading end, the
// events of the log over time as stacked bars, and the first, middle and last time of the
// chart under the bars. A click on a bar jumps to the first record from that time; a drag
// limits the table to the time range it covers.
func (w *window) drawHistogram(f *flex.Frame) {
	histogram := w.model.histogram
	// The strip spans the window and the bars start after the legend, so the bars' extent is
	// known without reading a box back from the layout, whose rectangle belongs to the
	// previous frame until the frame ends.
	bounds := f.Bounds()
	left := bounds.X + histogramInset + sidebarWidth
	width := bounds.Width - 2*histogramInset - sidebarWidth
	w.histogramPointer(f.Canvas(), histogram, left, width)

	f.Stack().FillWidth().Height(histogramHeight).Shrink(0).Background(w.pal.bg2).Children(func() {
		f.Row().Fill().PadSides(6, histogramInset, 4, histogramInset).Children(func() {
			w.drawHistogramLegend(f)
			f.Column().Grow(1).MinWidth(0).Gap(2).Children(func() {
				f.Row().Grow(1).MinHeight(0).Gap(1).Children(func() {
					if histogram != nil {
						w.drawHistogramBars(f, histogram)
					}
				})
				if histogram != nil {
					w.drawHistogramTimes(f, histogram)
				}
			})
		})
		// The line along the bottom edge is drawn over the strip and takes no room from it.
		f.Row().Absolute().Left(0).Right(0).Bottom(0).Height(1).Background(w.pal.line)
	})
}

// drawHistogramLegend is the text at the leading end of the strip: the chart's title, what
// the colors stand for and how to use the chart. It is as wide as the channel list below it
// and centered along the strip, as the macOS client's is.
func (w *window) drawHistogramLegend(f *flex.Frame) {
	text := func(s string) flex.Box {
		return w.mono(f, s, 11, w.pal.tx3).LineHeight(13)
	}
	f.Column().Width(sidebarWidth).Shrink(0).Self(flex.Center).Children(func() {
		text(w.text.Logs.EventsOverTime).Ellipsis()
		f.Row().Gap(4).Children(func() {
			for _, key := range []struct {
				name  string
				color ui.Color
			}{{"ERROR", w.pal.red}, {"WARN", w.pal.yel}, {"INFO", w.pal.blu}} {
				w.mono(f, "■", 11, key.color).LineHeight(13)
				text(key.name)
			}
		})
		// The hint is longer than the legend is wide in some languages, and ends in an
		// ellipsis there.
		text(w.text.Logs.HistogramHint).Ellipsis()
	})
}

// drawHistogramBars declares one column per bucket, side by side, each one stacking its
// errors on its warnings on the rest, from the top down, and growing from the bottom of the
// chart. The tallest bucket reaches histogramBarMax.
func (w *window) drawHistogramBars(f *flex.Frame, histogram *core.LogHistogram) {
	maximum := 1
	for _, bucket := range histogram.Buckets {
		maximum = max(maximum, bucket.Debug+bucket.Info+bucket.Warn+bucket.Error)
	}
	scale := float32(histogramBarMax) / float32(maximum)
	lo, hi := min(w.histogram.start, w.histogram.end), max(w.histogram.start, w.histogram.end)
	for i, bucket := range histogram.Buckets {
		other := bucket.Info + bucket.Debug
		hint := w.text.Logs.HistogramTooltip(
			histogramTime(histogram.StartEpochMs+int64(i)*histogram.BucketMs), bucket.Error, bucket.Warn, other)
		column := f.Column().Grow(1).Basis(0).MinWidth(0).
			HitWith(histogramBucketScope.At(i), hint, ui.HitOptions{Hint: hint, SkipFocus: true}).
			// The one pixel between two buckets belongs to the chart as well, so a drag never
			// crosses a dead line.
			HitOutset(0, 0.5, 0, 0.5)
		if w.histogram.active && i >= lo && i <= hi {
			column = column.Background(w.pal.blu.WithAlpha(0.16))
		}
		column.Children(func() {
			// The spacer pushes the bars to the bottom of the column.
			f.Spacer()
			if bucket.Error > 0 {
				f.Row().Height(float32(bucket.Error) * scale).Shrink(0).Background(w.pal.red)
			}
			if bucket.Warn > 0 {
				f.Row().Height(float32(bucket.Warn) * scale).Shrink(0).Background(w.pal.yel)
			}
			if other > 0 {
				f.Row().Height(float32(other) * scale).Shrink(0).Background(w.pal.blu.WithAlpha(0.4))
			}
		})
	}
}

// drawHistogramTimes is the line under the bars with the time the chart starts, the time in
// its middle and the time it ends.
func (w *window) drawHistogramTimes(f *flex.Frame, histogram *core.LogHistogram) {
	stamp := func(ms int64) {
		w.mono(f, histogramTime(ms), 10, w.pal.tx3).LineHeight(12).Shrink(0)
	}
	f.Row().Shrink(0).Items(flex.Center).Children(func() {
		stamp(histogram.StartEpochMs)
		f.Spacer()
		stamp(histogram.StartEpochMs + (histogram.EndEpochMs-histogram.StartEpochMs)/2)
		f.Spacer()
		stamp(histogram.EndEpochMs)
	})
}

// histogramPointer follows a press on the chart. Pressing starts a range at the bucket under
// the pointer, moving with the press held stretches it, and releasing either jumps to the
// time of the bucket (the range is one bucket) or limits the table to the buckets covered.
// left and width are where the chart's bars are in the window.
func (w *window) histogramPointer(canvas *ui.Canvas, histogram *core.LogHistogram, left, width float32) {
	state := &w.histogram
	_, event, ok := canvas.PointerIn(histogramBucketScope)
	if !ok {
		// A press the system took away, or one that ended over another control, is never
		// delivered as a release. It shows as the press no longer being held on a bucket.
		if _, held := canvas.Pressed().In(histogramBucketScope); state.active && !held {
			state.active = false
		}
		return
	}
	if histogram == nil || len(histogram.Buckets) == 0 {
		return
	}
	at := histogramBucket(event.X-left, width, len(histogram.Buckets))
	switch event.Kind {
	case ui.PointerDown:
		if event.Button != ui.PointerButtonPrimary {
			return
		}
		state.active, state.start, state.end = true, at, at
		canvas.Consume()
	case ui.PointerMove:
		if state.active {
			state.end = at
			canvas.Consume()
		}
	case ui.PointerUp:
		if !state.active {
			return
		}
		state.active = false
		canvas.Consume()
		if state.start == at {
			w.model.jump(histogram.StartEpochMs + int64(at)*histogram.BucketMs)
			return
		}
		lo, hi := min(state.start, at), max(state.start, at)
		w.model.setRange(
			histogram.StartEpochMs+int64(lo)*histogram.BucketMs,
			histogram.StartEpochMs+int64(hi+1)*histogram.BucketMs-1)
	}
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
