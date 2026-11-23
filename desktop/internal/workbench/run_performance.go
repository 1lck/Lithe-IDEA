package workbench

import (
	"context"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// A running run's CPU and memory, sampled in the background every runSampleInterval while the run lives
// and drawn as two lines above its output. The sampler posts each sample to the window thread; a run that
// ends stops its sampler, and its samples stay until the entry is dropped.
const (
	runSampleInterval = 2 * time.Second
	runSampleLimit    = 150
	runChartHeight    = 48
)

// startRunSampling samples the process tree of a run on a timer until the run ends.
func (a *App) startRunSampling(entry *runEntry, pid int) {
	ctx, cancel := context.WithCancel(context.Background())
	entry.stopSampling = cancel
	go func() {
		ticker := time.NewTicker(runSampleInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				sample, ok := pluginservice.SampleProcessTree(ctx, pid)
				if !ok {
					continue
				}
				a.post(func(a *App) { entry.addSample(sample) })
			}
		}
	}()
}

// addSample appends a sample, dropping the oldest once the chart holds its limit.
func (r *runEntry) addSample(sample pluginservice.ProcessSample) {
	r.samples = append(r.samples, sample)
	if len(r.samples) > runSampleLimit {
		r.samples = append(r.samples[:0], r.samples[len(r.samples)-runSampleLimit:]...)
	}
}

// runPerformanceChart declares the chart of a run's samples and the latest reading beside it. Nothing
// shows until the first sample arrives.
func (a *App) runPerformanceChart(c ui.C, run *runEntry) {
	if len(run.samples) == 0 {
		return
	}
	samples := run.samples
	latest := samples[len(samples)-1]
	t := a.text.Run.Performance
	collapsed := a.settings.RunPerformanceCollapsed
	ui.Column(c.Part("performance")).FillWidth().Gap(2).PadX(8).Children(func() {
		// All executions share this view preference, but keep separate samples.
		if !collapsed {
			ui.Row(c.Part("chart")).FillWidth().Height(runChartHeight).Shrink(0).Draw(func(d *ui.DrawContext) {
				a.paintRunSamples(d, samples)
			})
		}
		ui.Row(c.Part("summary")).FillWidth().Height(24).Shrink(0).Items(ui.Center).Gap(8).Children(func() {
			label, icon := i18n.Shared(a.language(), "native.collapseSection"), icons.ChevronUp
			if collapsed {
				label, icon = i18n.Shared(a.language(), "native.expandSection"), icons.ChevronDown
			}
			if a.runToolIcon(c.Part("performanceToggle"), label, icon, a.colors.Subtle, false, false, gfx.HitOptions{
				Role:       gfx.RoleButton,
				Expandable: true,
				Expanded:   !collapsed,
			}) {
				c.After(func() {
					a.setRunPerformanceCollapsed(!collapsed)
				})
			}
			ui.Text(c, t.CPU(strconv.FormatFloat(latest.CPUPercent, 'f', 0, 64))).FontSize(11).Color(a.colors.Accent).Shrink(0)
			ui.Text(c, t.Memory(strconv.FormatUint(latest.MemoryBytes/(1<<20), 10))).FontSize(11).Color(a.colors.Subtle).Shrink(0)
		})
	})
	ui.Divider(c)
}

// setRunPerformanceCollapsed stores the Run performance graph collapse preference across
// every open workbench tab and persists it to settings.
func (a *App) setRunPerformanceCollapsed(collapsed bool) {
	if a.settings.RunPerformanceCollapsed == collapsed {
		return
	}
	a.performed("run.performance.toggle", surfaceButton)
	for _, tab := range a.sessions.everyOne() {
		tab.settings.RunPerformanceCollapsed = collapsed
	}
	a.settings.RunPerformanceCollapsed = collapsed
	a.saveSettings()
}

// paintRunSamples draws the CPU line against 100% or the highest reading, and the memory line against the
// highest memory seen, so both fit the chart.
func (a *App) paintRunSamples(d *ui.DrawContext, samples []pluginservice.ProcessSample) {
	if len(samples) < 2 {
		return
	}
	width, height := d.Rect.Width, d.Rect.Height
	maxCPU, maxMemory := 100.0, uint64(1)
	for _, sample := range samples {
		maxCPU = max(maxCPU, sample.CPUPercent)
		maxMemory = max(maxMemory, sample.MemoryBytes)
	}
	step := width / float32(len(samples)-1)
	// Canvas.PathBuilder reuses a single builder, so each line must finish before the next starts.
	drawSeries := func(yOf func(pluginservice.ProcessSample) float32, style gfx.PathStyle) {
		builder := d.Canvas.PathBuilder()
		for index, sample := range samples {
			x := float32(index) * step
			y := yOf(sample)
			if index == 0 {
				builder.MoveTo(x, y)
				continue
			}
			builder.LineTo(x, y)
		}
		d.Canvas.DrawPath(builder.Path(width, height), d.Rect, style)
	}
	drawSeries(func(sample pluginservice.ProcessSample) float32 {
		return height * (1 - float32(sample.CPUPercent/maxCPU))
	}, gfx.PathStyle{Stroke: a.colors.Accent, StrokeWidth: 1.5, Cap: gfx.CapRound, Join: gfx.JoinRound})
	drawSeries(func(sample pluginservice.ProcessSample) float32 {
		return height * (1 - float32(float64(sample.MemoryBytes)/float64(maxMemory)))
	}, gfx.PathStyle{Stroke: a.colors.Subtle, StrokeWidth: 1, Cap: gfx.CapRound, Join: gfx.JoinRound})
}
