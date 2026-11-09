package workbench

import (
	"math"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// This file paints the rows of the commit list: the graph, the subject, the author, the
// date and the reference labels. The rows themselves (their hit, selection, hover and
// current branch backgrounds) are ui boxes declared by gitlog_view.go; what is drawn
// in them is painted here after Draw, into the rectangles the boxes were laid out at,
// because the graph is vector geometry no ui box can show.
//
// The measurements are those of the macOS log, which scales the 22 point grid of the
// IntelliJ log to its 26 point rows.

const (
	logRowHeight = 26
	logFontSize  = 13
	logMetaSize  = 12
	logRefSize   = 12
	// logAuthorWidth is the author column; logMetaGap is the room the author column and
	// the gaps around it take before the date.
	logAuthorWidth = 104
	logMetaGap     = 120
	logDatePad     = 8
	logDateFormat  = "2006/1/2 15:04"
	logDateSample  = "0000/00/00 00:00"
)

// The logical grid of the graph, scaled from the 22 point rows of IntelliJ's log.
const (
	graphScale       = logRowHeight / 22.0
	graphLaneSpacing = 16 * graphScale
	graphTextGap     = 2 * graphScale
)

// graphMetrics is the graph's grid aligned to device pixels, as the macOS painter
// aligns it: the centers of rows and lanes and the widths of lines and nodes fall on
// whole pixels, the ones that must be odd on odd pixels.
type graphMetrics struct {
	rowCenter, laneSpacing, laneCenter, lineWidth, nodeDiameter, nodeRadius float32
}

func newGraphMetrics(scale float32) graphMetrics {
	if scale <= 0 || math.IsInf(float64(scale), 0) || math.IsNaN(float64(scale)) {
		scale = 1
	}
	align := func(v float32, odd bool) float32 {
		px := float32(math.Floor(float64(v * scale)))
		if odd && int(px)%2 == 0 {
			px--
		}
		return px / scale
	}
	m := graphMetrics{
		rowCenter:    align(logRowHeight/2, true),
		laneSpacing:  align(16*graphScale, true),
		laneCenter:   align(8*graphScale, false),
		lineWidth:    max(1/scale, align(1.5*graphScale, true)),
		nodeDiameter: align(8*graphScale, true),
	}
	m.nodeRadius = align(m.nodeDiameter/2, false)
	return m
}

// line is the segment an element draws in its row, in the row's coordinates: from the
// center of its lane to the row's edge, or to the middle of the way to the lane it
// meets in the next row.
func (m graphMetrics) line(e core.GraphElement) (x0, y0, x1, y1 float32) {
	x0, y0 = m.laneCenter+float32(e.Position)*m.laneSpacing, m.rowCenter
	up := e.Direction == "up"
	if e.Position == e.AdjacentPosition {
		gap := float32(0)
		if e.IsTerminal {
			gap = m.nodeRadius/2 + 1
		}
		y1 = logRowHeight - gap
		if up {
			y1 = gap
		}
	} else {
		y1 = m.rowCenter + logRowHeight/2
		if up {
			y1 = m.rowCenter - logRowHeight/2
		}
	}
	x1 = m.laneCenter + float32(e.Position+e.AdjacentPosition)/2*m.laneSpacing
	return x0, y0, x1, y1
}

// titleOffset is where the subject of a row starts: the graph's width with six lanes
// kept for it, so the subjects of a narrow graph line up, plus the text inset.
func titleOffset(row core.GraphRow) float32 {
	last := float32(row.Lane)
	for _, e := range row.PrintElements {
		last = max(last, float32(e.Position), float32(e.Position+e.AdjacentPosition)/2)
	}
	return float32(math.Floor(float64(max(last+1, 6)*graphLaneSpacing+graphTextGap))) + 2
}

// graphColor is the color of an edge or node with a color id: a hue derived from the id
// as the IntelliJ log derives it, at the saturation and brightness of the theme.
func graphColor(id int32, dark bool, text gfx.Color) gfx.Color {
	if id == 0 {
		return text
	}
	part := func(m, o int32) float64 {
		v := (id*m + o) % 100
		if v < 0 {
			v = -v
		}
		return float64(v+70) / 255
	}
	r, g, b := part(200, 30), part(130, 50), part(90, 100)
	brightness := 0.7
	if dark {
		brightness = 0.6
	}
	return hsb(hue(r, g, b), 0.6, brightness)
}

// hue is the hue of an RGB color, in turns.
func hue(r, g, b float64) float64 {
	hi, lo := max(r, g, b), min(r, g, b)
	if hi == lo {
		return 0
	}
	d := hi - lo
	var h float64
	switch hi {
	case r:
		h = (g - b) / d
	case g:
		h = 2 + (b-r)/d
	default:
		h = 4 + (r-g)/d
	}
	h /= 6
	if h < 0 {
		h++
	}
	return h
}

// hsb is the color with a hue in turns, a saturation and a brightness.
func hsb(h, s, v float64) gfx.Color {
	h = (h - math.Floor(h)) * 6
	f := h - math.Floor(h)
	p, q, t := v*(1-s), v*(1-s*f), v*(1-s*(1-f))
	var r, g, b float64
	switch int(h) {
	case 0:
		r, g, b = v, t, p
	case 1:
		r, g, b = q, v, p
	case 2:
		r, g, b = p, v, t
	case 3:
		r, g, b = p, q, v
	case 4:
		r, g, b = t, p, v
	default:
		r, g, b = v, p, q
	}
	return gfx.Color{Red: float32(r), Green: float32(g), Blue: float32(b), Alpha: 1}
}

// referenceColor is the color of a reference label's icon by kind.
func referenceColor(kind string, dark bool) gfx.Color {
	switch kind {
	case "head":
		return pick(dark, 0xF5D273, 0xFFAF0F)
	case "branch":
		return pick(dark, 0x5FAD65, 0x369650)
	case "remote":
		return pick(dark, 0xB589EC, 0x834DF0)
	default:
		return pick(dark, 0x868A91, 0x6C707E)
	}
}

func pick(dark bool, darkRGB, lightRGB uint32) gfx.Color {
	if dark {
		return gfx.RGB24(darkRGB)
	}
	return gfx.RGB24(lightRGB)
}

// currentBranchBackground is the background of the rows of the checked out branch.
func currentBranchBackground(dark bool) gfx.Color {
	if dark {
		return gfx.RGB(29, 35, 54)
	}
	return gfx.RGB(237, 243, 255)
}

// mergeForeground is the text color of a merge commit's row.
func mergeForeground(dark bool) gfx.Color {
	if dark {
		return gfx.RGB(111, 115, 122)
	}
	return gfx.RGB(129, 133, 148)
}

// referenceGroup is what a row's reference labels show: one title, the icons of the
// kinds it holds (at most two of a kind) and every label for the detail pane.
type referenceGroup struct {
	title  string
	labels []core.GraphLabel
	kinds  []string
}

// groupReferences orders a row's labels and picks the title as the macOS log does:
// the checked out branch, else a local branch with the remote branch it tracks, shown
// as "remote & branch", else the first label that is not a tag.
func groupReferences(labels []core.GraphLabel, current string, upstream map[string]string) referenceGroup {
	rank := func(l core.GraphLabel) int {
		switch l.Kind {
		case "head":
			return 0
		case "branch":
			switch {
			case l.Title == current:
				return 1
			case l.Title == "main" || l.Title == "master":
				return 2
			}
			return 4
		case "remote":
			if l.Title == "origin/main" || l.Title == "origin/master" {
				return 3
			}
			return 5
		}
		return 6
	}
	sorted := slices.Clone(labels)
	slices.SortStableFunc(sorted, func(x, y core.GraphLabel) int {
		if rx, ry := rank(x), rank(y); rx != ry {
			return rx - ry
		}
		return strings.Compare(strings.ToLower(x.Title), strings.ToLower(y.Title))
	})
	remotes := map[string]core.GraphLabel{}
	byBranch := map[string]core.GraphLabel{}
	for _, l := range sorted {
		if l.Kind != "remote" {
			continue
		}
		if _, ok := remotes[l.Title]; !ok {
			remotes[l.Title] = l
		}
		name := l.Title
		if i := strings.IndexByte(name, '/'); i >= 0 {
			name = name[i+1:]
		}
		if _, ok := byBranch[name]; !ok {
			byBranch[name] = l
		}
	}
	paired := map[string]bool{}
	tracked := ""
	for _, l := range sorted {
		if l.Kind != "branch" {
			continue
		}
		remote, ok := remotes[upstream[l.Title]]
		if !ok {
			remote, ok = byBranch[l.Title]
		}
		if !ok {
			continue
		}
		if tracked == "" {
			name, _, _ := strings.Cut(remote.Title, "/")
			tracked = name + " & " + l.Title
		}
		paired[l.ID], paired[remote.ID] = true, true
	}
	g := referenceGroup{labels: sorted}
	var first *core.GraphLabel
	for i, l := range sorted {
		if l.Kind == "head" || paired[l.ID] {
			continue
		}
		if l.Kind == "branch" && l.Title == current {
			g.title = l.Title
			first = nil
			break
		}
		if first == nil {
			first = &sorted[i]
		}
	}
	switch {
	case g.title != "":
	case tracked != "":
		g.title = tracked
	case first != nil:
		if first.Kind != "tag" {
			g.title = first.Title
		}
	case slices.ContainsFunc(sorted, func(l core.GraphLabel) bool { return l.Kind == "head" }):
		g.title = "HEAD"
	}
	for _, l := range sorted {
		n := 0
		for _, k := range g.kinds {
			if k == l.Kind {
				n++
			}
		}
		if n < 2 {
			g.kinds = append(g.kinds, l.Kind)
		}
	}
	return g
}

// iconWidth is the width of the group's overlapping icons at a height.
func (g referenceGroup) iconWidth(h float32) float32 {
	if len(g.labels) == 0 {
		return 0
	}
	return float32(math.Round(float64(h + float32(len(g.kinds)-1)*h/6.25*2)))
}

// shortenTitle keeps at least 22 characters of a title, shortening a long one first by
// its leading folder and then from the end.
func shortenTitle(canvas *gfx.Canvas, title string, available, size float32) string {
	if utf8.RuneCountInString(title) <= 22 || canvas.TextWidth(title, size) <= available {
		return title
	}
	result := title
	if i := strings.IndexByte(result, '/'); i > 2 {
		result = ".." + result[i:]
	}
	if available > 0 && canvas.TextWidth(result, size) <= available {
		return result
	}
	runes := []rune(strings.TrimSuffix(result, "…"))
	for len(runes) > 22 {
		runes = runes[:len(runes)-1]
		result = string(runes) + "…"
		if canvas.TextWidth(result, size) <= available {
			return result
		}
	}
	return result
}

// tagIcon traces the reference label icon, a tag, in a size×size box.
func tagIcon(b *gfx.PathBuilder, size float32) gfx.Path {
	s := size / 16
	b.MoveTo(13.4495*s, 7.5001*s)
	b.LineTo(7.01028*s, 13.9394*s)
	b.CubicTo(6.81502*s, 14.1347*s, 6.49843*s, 14.1347*s, 6.30317*s, 13.9394*s)
	b.LineTo(2.06053*s, 9.69679*s)
	b.CubicTo(1.86527*s, 9.50152*s, 1.86527*s, 9.18494*s, 2.06053*s, 8.98968*s)
	b.LineTo(8.49978*s, 2.55035*s)
	b.CubicTo(8.61106*s, 2.43907*s, 8.76824*s, 2.38667*s, 8.92404*s, 2.40893*s)
	b.LineTo(12.6363*s, 2.93926*s)
	b.CubicTo(12.8563*s, 2.97069*s, 13.0292*s, 3.14354*s, 13.0606*s, 3.36352*s)
	b.LineTo(13.5909*s, 7.07584*s)
	b.CubicTo(13.6132*s, 7.23163*s, 13.5608*s, 7.38882*s, 13.4495*s, 7.5001*s)
	b.Close()
	return b.Path(size, size)
}

// paintGitLog paints the rows of the commit list the frame declared.
func (a *App) paintGitLog(canvas *gfx.Canvas) {
	v := &a.logView
	if len(v.rows) == 0 || a.project == nil {
		return
	}
	l := &a.project.log
	clip := v.list.Rect()
	if clip.Width <= 0 || clip.Height <= 0 {
		return
	}
	dark := a.colors.Dark
	if v.colorsDark != dark || v.colors == nil {
		v.colors, v.colorsDark = map[int32]gfx.Color{}, dark
	}
	color := func(id int32) gfx.Color {
		c, ok := v.colors[id]
		if !ok {
			c = graphColor(id, dark, a.colors.Text)
			v.colors[id] = c
		}
		return c
	}
	m := newGraphMetrics(canvas.PixelScale())
	dateWidth := canvas.TextWidth(logDateSample, logMetaSize)
	upstream := v.upstreams(l)
	canvas.Clip(clip)
	defer canvas.Unclip()
	for _, pr := range v.rows {
		rect := pr.box.Rect()
		if pr.index >= len(l.graph.Rows) || rect.Y+rect.Height < clip.Y || rect.Y > clip.Y+clip.Height {
			continue
		}
		row := l.graph.Rows[pr.index]
		commit, _ := l.commit(row.CommitHash)
		selected := row.CommitHash == l.selected
		a.paintGraphRow(canvas, m, rect, row, color)

		foreground := a.colors.Text
		if len(commit.ParentHashes) > 1 && !selected {
			foreground = mergeForeground(dark)
		}
		start := titleOffset(row)
		labelsWidth := float32(0)
		var group referenceGroup
		var labelRect gfx.Rect
		labelText := ""
		if l.decorations && len(row.Labels) > 0 {
			group = groupReferences(row.Labels, l.current, upstream)
			end := max(start, rect.Width-dateWidth-logMetaGap)
			column := end - start
			subject := canvas.TextWidth(commit.Subject, logFontSize)
			available := max(0, min(column-subject, column/3))
			icon := group.iconWidth(logRefSize + 3)
			labelText = shortenTitle(canvas, group.title, available-icon-9, logRefSize)
			textW := float32(0)
			if labelText != "" {
				textW = float32(math.Ceil(float64(canvas.TextWidth(labelText, logRefSize)))) + 1
			}
			width := min(column, icon+textW+8)
			labelsWidth = width
			labelRect = gfx.Rect{X: rect.X + end - width, Y: rect.Y, Width: width, Height: rect.Height}
		}
		a.paintText(canvas, commit.Subject, gfx.Rect{X: rect.X + start, Y: rect.Y, Width: max(0, rect.Width-start-dateWidth-logMetaGap-labelsWidth), Height: rect.Height}, logFontSize, foreground, gfx.AlignStart)
		a.paintText(canvas, commit.AuthorName, gfx.Rect{X: rect.X + max(0, rect.Width-dateWidth-112), Y: rect.Y, Width: logAuthorWidth, Height: rect.Height}, logMetaSize, foreground, gfx.AlignStart)
		a.paintText(canvas, v.date(commit), gfx.Rect{X: rect.X + max(0, rect.Width-dateWidth-logDatePad), Y: rect.Y, Width: dateWidth, Height: rect.Height}, logMetaSize, foreground, gfx.AlignEnd)
		if labelRect.Width > 0 {
			background := a.colors.Editor
			switch {
			case selected:
				background = a.colors.Selection
			case l.currentRows[row.CommitHash]:
				background = currentBranchBackground(dark)
			}
			a.paintLabels(canvas, labelRect, group, labelText, background)
		}
	}
}

// paintGraphRow strokes the edges of one row and fills its node.
func (a *App) paintGraphRow(canvas *gfx.Canvas, m graphMetrics, rect gfx.Rect, row core.GraphRow, color func(int32) gfx.Color) {
	width := titleOffset(row)
	box := gfx.Rect{X: rect.X, Y: rect.Y, Width: width, Height: logRowHeight}
	for _, e := range row.PrintElements {
		x0, y0, x1, y1 := m.line(e)
		b := canvas.PathBuilder()
		if e.IsDotted && !e.HasArrow {
			dashLine(b, x0, y0, x1, y1)
		} else {
			b.MoveTo(x0, y0)
			b.LineTo(x1, y1)
		}
		if e.HasArrow {
			length := max(1, float32(math.Hypot(float64(x1-x0), float64(y1-y0))))
			vx := (x0 - x1) / length * logRowHeight * 0.3
			vy := (y0 - y1) / length * logRowHeight * 0.3
			for _, sign := range [2]float32{-1, 1} {
				b.MoveTo(x1, y1)
				b.LineTo(x1+vx*sqrt07-sign*vy*sqrt03, y1+sign*vx*sqrt03+vy*sqrt07)
			}
		}
		canvas.DrawPath(b.Path(width, logRowHeight), box, gfx.PathStyle{
			Stroke: color(e.ColorID), StrokeWidth: m.lineWidth, Cap: gfx.CapRound, Join: gfx.JoinRound,
		})
	}
	x := rect.X + m.laneCenter + float32(row.Lane)*m.laneSpacing - m.nodeRadius
	node := gfx.Rect{X: x, Y: rect.Y + m.rowCenter - m.nodeRadius, Width: m.nodeDiameter, Height: m.nodeDiameter}
	canvas.Rounded(node, m.nodeDiameter/2, color(row.ColorID))
}

var (
	sqrt07 = float32(math.Sqrt(0.7))
	sqrt03 = float32(math.Sqrt(0.3))
)

// dashLine traces a dotted edge as the IntelliJ log dashes it: one dash and one gap
// fitted into a row, the pattern starting half a dash in.
func dashLine(b *gfx.PathBuilder, x0, y0, x1, y1 float32) {
	space := float32(logRowHeight/2 - 2)
	segment := float32(math.Hypot(float64(x1-x0), float64(y1-y0)))
	if segment <= 0 {
		return
	}
	length := segment * 2
	dash := length/max(1, float32(math.Floor(float64(length/logRowHeight)))) - space
	if dash <= 0 {
		b.MoveTo(x0, y0)
		b.LineTo(x1, y1)
		return
	}
	dx, dy := (x1-x0)/segment, (y1-y0)/segment
	for pos := -dash / 2; pos < segment; pos += dash + space {
		from, to := max(pos, 0), min(pos+dash, segment)
		if to <= from {
			continue
		}
		b.MoveTo(x0+dx*from, y0+dy*from)
		b.LineTo(x0+dx*to, y0+dy*to)
	}
}

// paintLabels paints a row's reference group: the overlapping tag icons of its kinds,
// the last with its hole, and the title beside them.
func (a *App) paintLabels(canvas *gfx.Canvas, rect gfx.Rect, g referenceGroup, text string, background gfx.Color) {
	size := float32(logRefSize + 3)
	canvas.Clip(rect)
	defer canvas.Unclip()
	for i := len(g.kinds) - 1; i >= 0; i-- {
		kind := g.kinds[i]
		index := len(g.kinds) - 1 - i
		box := gfx.Rect{X: rect.X + 4 + float32(index)*size/6.25*2, Y: rect.Y + rect.Height/2 - size/2, Width: size, Height: size}
		stroke := referenceColor(kind, a.colors.Dark)
		canvas.DrawPath(tagIcon(canvas.PathBuilder(), size), box, gfx.PathStyle{
			Fill: background, Stroke: stroke, StrokeWidth: size / 16, Join: gfx.JoinRound,
		})
		if index == len(g.kinds)-1 {
			hole := gfx.Rect{X: box.X + 9.5*size/16, Y: box.Y + 4.5*size/16, Width: size / 8, Height: size / 8}
			canvas.Rounded(hole, size/16, stroke)
		}
	}
	icon := g.iconWidth(size)
	a.paintText(canvas, text, gfx.Rect{X: rect.X + 5 + icon, Y: rect.Y, Width: max(0, rect.Width-icon-9), Height: rect.Height}, logRefSize, a.colors.Text, gfx.AlignStart)
}

// paintText paints one line cut to its rectangle with an ellipsis.
func (a *App) paintText(canvas *gfx.Canvas, text string, rect gfx.Rect, size float32, color gfx.Color, align gfx.Alignment) {
	if rect.Width <= 0 || text == "" {
		return
	}
	line := canvas.FitLine(text, size, gfx.WeightRegular, rect.Width)
	if line == "" {
		return
	}
	canvas.LabelAligned(line, rect, gfx.TextStyle{Size: size, Color: color}, align)
}

// date is the date a row shows, in local time, cached by commit.
func (v *logView) date(c core.GitCommit) string {
	if s, ok := v.dates[c.Hash]; ok {
		return s
	}
	var t time.Time
	if parsed, err := time.Parse(time.RFC3339, c.Date); err == nil {
		t = parsed
	} else if c.DateUnixSeconds != nil {
		t = time.Unix(*c.DateUnixSeconds, 0)
	}
	s := c.Date
	if !t.IsZero() {
		s = t.Local().Format(logDateFormat)
	}
	if v.dates == nil || len(v.dates) > 20000 {
		v.dates = map[string]string{}
	}
	v.dates[c.Hash] = s
	return s
}

// upstreams maps each local branch to the remote branch it tracks.
func (v *logView) upstreams(l *gitLogState) map[string]string {
	if v.upstreamFor == &l.sections[0] && v.upstreamRefs == len(l.sections[0].refs) && v.upstream != nil {
		return v.upstream
	}
	v.upstream = map[string]string{}
	for _, r := range l.sections[0].refs {
		if r.UpstreamShortName != "" {
			v.upstream[r.ShortName] = r.UpstreamShortName
		}
	}
	v.upstreamFor, v.upstreamRefs = &l.sections[0], len(l.sections[0].refs)
	return v.upstream
}
