package workbench

import (
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// agentQuotaRingSize is the side of the quota ring, and agentQuotaRingWidth its stroke width,
// both in points on a 16-unit grid.
const (
	agentQuotaRingSize  = 16
	agentQuotaRingWidth = 2
)

// agentQuotaRingFraction is the window the ring shows: the most used one, so it fills and
// changes colour as soon as any window nears its limit. It reports false when no window has a
// known value, which the ring shows as an empty grey track.
func agentQuotaRingFraction(windows []agentQuotaWindow) (fraction, percent float64, ok bool) {
	for _, window := range windows {
		if !ok || window.UsedPercent > percent {
			percent, ok = window.UsedPercent, true
		}
	}
	fraction = math.Min(math.Max(percent/100, 0), 1)
	return fraction, percent, ok
}

// agentRingTrack is the full grey circle.
func agentRingTrack() gfx.Icon {
	return agentRingIcon(1)
}

// agentRingIcon is a circle stroked from the top, sweeping fraction of a turn clockwise. It
// is built from cubic segments of at most a quarter turn each, so it is exact at every size.
func agentRingIcon(fraction float64) gfx.Icon {
	const center, radius = 8.0, 6.0
	icon := gfx.Icon{ViewBox: agentQuotaRingSize, Stroke: agentQuotaRingWidth, Cap: gfx.CapRound, Join: gfx.JoinRound}
	if fraction <= 0 {
		return icon
	}
	sweep := fraction * 2 * math.Pi
	start := -math.Pi / 2
	point := func(theta float64) (float64, float64) {
		return center + radius*math.Cos(theta), center + radius*math.Sin(theta)
	}
	x0, y0 := point(start)
	icon.Commands = append(icon.Commands, gfx.MoveTo(float32(x0), float32(y0)))
	segments := int(math.Ceil(sweep / (math.Pi / 2)))
	if segments < 1 {
		segments = 1
	}
	step := sweep / float64(segments)
	k := 4.0 / 3.0 * math.Tan(step/4)
	for i := 0; i < segments; i++ {
		t0 := start + float64(i)*step
		t1 := t0 + step
		x0, y0 := point(t0)
		x1, y1 := point(t1)
		c1x, c1y := x0-k*radius*math.Sin(t0), y0+k*radius*math.Cos(t0)
		c2x, c2y := x1+k*radius*math.Sin(t1), y1-k*radius*math.Cos(t1)
		icon.Commands = append(icon.Commands, gfx.CubicTo(float32(c1x), float32(c1y), float32(c2x), float32(c2y), float32(x1), float32(y1)))
	}
	return icon
}

// agentQuotaRing declares the subscription quota as one ring beside the composer's send
// controls. Its tooltip lists every window. Unknown or stale values stay grey.
func (a *App) agentQuotaRing(c ui.C, p *project) {
	act := &p.agent.activity
	if !act.quotaSeen {
		return
	}
	fraction, percent, known := agentQuotaRingFraction(act.quota)
	color := a.colors.Subtle
	if known {
		color = a.agentUsageColor(int(percent))
	}
	a.agentRingBox(c.Key("quota-ring"), fraction, known, color, a.agentQuotaTooltip(act))
}

// agentContextRing shows the context window in use as a ring: the share of the configured
// window (see agent_limits.go) that the conversation occupies. It is empty while unknown.
func (a *App) agentContextRing(c ui.C, p *project) {
	s := p.agent.activity.current(p.agent.sessionID)
	if s == nil || !s.usageKnown || s.size == 0 {
		return
	}
	percent := agentUsagePercent(s.used, s.size)
	fraction := float64(min(percent, 100)) / 100
	t := a.text.Agent.Activity
	tip := t.Context(agentCompactCount(s.used), agentCompactCount(s.size), fmt.Sprint(percent))
	a.agentRingBox(c.Key("context-ring"), fraction, true, a.agentUsageColor(percent), tip)
}

// agentRingBox draws a grey track with a coloured arc of fraction, and shows tip on hover.
func (a *App) agentRingBox(c ui.C, fraction float64, known bool, color gfx.Color, tip string) {
	box := ui.Row(c).Size(agentQuotaRingSize+4, agentQuotaRingSize+4).Shrink(0).Items(ui.Center).
		Draw(func(d *ui.DrawContext) {
			bounds := gfx.Rect{X: d.Rect.X + 2, Y: d.Rect.Y + 2, Width: agentQuotaRingSize, Height: agentQuotaRingSize}
			track := a.colors.Subtle
			track.Alpha *= 0.35
			d.Canvas.DrawIcon(agentRingTrack(), bounds, track)
			if known {
				d.Canvas.DrawIcon(agentRingIcon(fraction), bounds, color)
			}
		})
	if tip != "" {
		box = box.Tooltip(tip)
	}
	box.Children(func() {})
}

// agentQuotaTooltip lists each window on its own line, with its reset time when known.
func (a *App) agentQuotaTooltip(act *agentActivityState) string {
	t := a.text.Agent.Activity
	lines := make([]string, 0, len(act.quota)+1)
	if act.quotaFailed != "" {
		lines = append(lines, t.QuotaFailed(act.quotaFailed))
	}
	for _, window := range act.quota {
		line := t.Quota(window.Name, fmt.Sprintf("%.0f", window.UsedPercent))
		if window.ResetsAt > 0 {
			line += " · " + t.QuotaReset(time.Unix(window.ResetsAt, 0).Local().Format("01-02 15:04"))
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}
