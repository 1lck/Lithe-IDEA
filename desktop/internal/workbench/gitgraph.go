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
// current branch backgrounds) are list rows declared by gitlog_view.go; what is drawn in them
// is painted here by the row's draw callback, into the rectangle the row was laid out at,
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
	// logRootStripWidth is the strip at a row's left edge in the color of its repository, in a
	// folder with several; the first lane's node starts past it.
	logRootStripWidth = 3
)

// The logical grid of the graph, scaled from the 22 point rows of IntelliJ's log.
const (
	graphScale       = logRowHeight / 22.0
	graphLaneSpacing = 16 * graphScale
	graphTextGap     = 2 * graphScale
)

// graphMetrics aligns the graph's grid and stroke widths to device pixels. Node
// radii remain exactly half their diameters so edges and nodes share a center.
type graphMetrics struct {
	rowCenter, laneSpacing, laneCenter, lineWidth, nodeRadius float32
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
	return graphMetrics{
		rowCenter:   align(logRowHeight/2, true),
		laneSpacing: align(16*graphScale, true),
		laneCenter:  align(8*graphScale, false),
		lineWidth:   max(1/scale, align(1.5*graphScale, true)),
		nodeRadius:  align(8*graphScale, true) / 2,
	}
}

// line is the segment an element draws in its row, in the row's coordinates: from the
// center of its lane to the row boundary. Diagonal half edges meet on the line
// between adjacent node centers, even when pixel alignment shifts the row center.
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
		y1 = logRowHeight
		if up {
			y1 = 0
		}
	}
	fraction := float32(math.Abs(float64(y1-y0))) / logRowHeight
	x1 = x0 + float32(e.AdjacentPosition-e.Position)*m.laneSpacing*fraction
	return x0, y0, x1, y1
}

func (m graphMetrics) strokeLine(e core.GraphElement, highlight bool) (x0, y0, x1, y1 float32) {
	x0, y0, x1, y1 = m.line(e)
	if !e.IsTerminal {
		overlap := max(m.lineWidth, 1)
		if highlight || e.IsDotted && !e.HasArrow {
			// Let the row clip cut across the full width of a dash or outline.
			overlap += m.lineWidth
		}
		x1, y1 = extendGraphEndpoint(x0, y0, x1, y1, overlap)
	}
	return x0, y0, x1, y1
}

func (m graphMetrics) marker(row core.GraphRow) (center gfx.Point, headRadius float32) {
	center = gfx.Point{X: m.laneCenter + float32(row.Lane)*m.laneSpacing, Y: m.rowCenter}
	if slices.ContainsFunc(row.Labels, func(label core.GraphLabel) bool { return label.Kind == "head" }) {
		headRadius = m.nodeRadius + m.lineWidth
	}
	return center, headRadius
}

// titleOffset keeps six lanes for the graph and leaves room for the actual
// stroke at a wide diagonal's row boundary, where its end can pass its midpoint.
func (m graphMetrics) titleOffset(row core.GraphRow) float32 {
	last := float32(row.Lane)
	right := float32(0)
	// Include the hover outline and at least half a device pixel of fringe.
	reach := m.lineWidth + max(m.lineWidth, 1)
	for _, e := range row.PrintElements {
		last = max(last, float32(e.Position), float32(e.Position+e.AdjacentPosition)/2)
		if e.AdjacentPosition > e.Position {
			_, _, x, _ := m.line(e)
			slope := float32(e.AdjacentPosition-e.Position) * m.laneSpacing / logRowHeight
			// A diagonal's stroke extends farther horizontally where it crosses
			// the row clip. 1+slope bounds the length of its slanted cross-section.
			right = max(right, x+reach*(1+slope))
		}
		if e.HasArrow {
			tip, wings := graphArrowPoints(m, e)
			right = max(right, max(tip.X, wings[0].X, wings[1].X)+reach)
		}
	}
	nominal := float32(math.Floor(float64(max(last+1, 6)*graphLaneSpacing + graphTextGap)))
	return max(nominal, float32(math.Ceil(float64(right)))) + 2
}

// dashSpan is the full distance between adjacent row centers. Both halves
// fit the same dash period to that span so their phases meet at the row clip.
func (m graphMetrics) dashSpan(e core.GraphElement) float32 {
	if !e.IsDotted || e.HasArrow {
		return 0
	}
	if e.IsTerminal {
		x0, y0, x1, y1 := m.line(e)
		return 2 * float32(math.Hypot(float64(x1-x0), float64(y1-y0)))
	}
	return float32(math.Hypot(float64(float32(e.AdjacentPosition-e.Position)*m.laneSpacing), logRowHeight))
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

// paintLogRow paints row index of the commit list into rect, the rectangle its element was
// laid out at: the graph, the subject, the author, the date and the reference labels.
func (a *App) paintLogRow(canvas *gfx.Canvas, rect gfx.Rect, index int) {
	v := &a.logView
	if a.project == nil || rect.Width <= 0 || rect.Height <= 0 {
		return
	}
	l := &a.project.log
	if index >= len(l.graph.Rows) {
		return
	}
	dark := a.colors.Dark
	color, metadataWidth := a.graphColors(), v.metadataWidth(canvas)
	dateWidth := metadataWidth - logMetaGap
	m := newGraphMetrics(canvas.PixelScale())
	upstream := v.upstreams(l)
	row := l.graph.Rows[index]
	// The graph and its overlay stop before the fixed author and date columns.
	contentEnd := max(0, rect.Width-metadataWidth)
	start := min(contentEnd, m.titleOffset(row))
	bounds := logGraphRowBounds{index: index, rect: rect, width: start}
	commit, _ := l.commit(row.CommitHash)
	selected := row.CommitHash == l.selected
	a.paintGraphRowWithHover(canvas, m, rect, row, start, 0, color, index+1, 0)
	// Graph strokes and text each stay within this row's pixel clip.
	canvas.Clip(rect)
	defer canvas.Unclip()
	if slot, ok := a.project.repositorySlot(a.project.logCommitRepo(row.CommitHash)); ok && a.project.workspaceMode() {
		// As IDEA marks each commit with the color of its root, the strip at the left edge says which
		// repository of the folder the commit belongs to, also while the log walks several at once.
		canvas.Fill(gfx.Rect{X: rect.X, Y: rect.Y, Width: logRootStripWidth, Height: rect.Height}, repositoryColor(slot, dark))
		// The overlay paints after the strip. Use the strip's snapped edge as
		// the left boundary for highlight drawing and hit testing.
		painted := canvas.Rectangles()
		bounds.inset = painted[len(painted)-1].Bounds.Right() - rect.X
	}
	v.graphHover.rows = append(v.graphHover.rows, bounds)

	foreground := a.colors.Text
	if len(commit.ParentHashes) > 1 && !selected {
		foreground = mergeForeground(dark)
	}
	labelsWidth := float32(0)
	var group referenceGroup
	var labelRect gfx.Rect
	labelText := ""
	if l.decorations && len(row.Labels) > 0 {
		group = groupReferences(row.Labels, l.current, upstream)
		column := contentEnd - start
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
		labelRect = gfx.Rect{X: rect.X + contentEnd - width, Y: rect.Y, Width: width, Height: rect.Height}
	}
	a.paintText(canvas, commit.Subject, gfx.Rect{X: rect.X + start, Y: rect.Y, Width: contentEnd - start - labelsWidth, Height: rect.Height}, logFontSize, foreground, gfx.AlignStart)
	a.paintText(canvas, commit.AuthorName, gfx.Rect{X: rect.X + max(0, rect.Width-metadataWidth+logDatePad), Y: rect.Y, Width: logAuthorWidth, Height: rect.Height}, logMetaSize, foreground, gfx.AlignStart)
	a.paintText(canvas, v.date(commit), gfx.Rect{X: rect.X + max(0, rect.Width-dateWidth-logDatePad), Y: rect.Y, Width: dateWidth, Height: rect.Height}, logMetaSize, foreground, gfx.AlignEnd)
	if labelRect.Width > 0 {
		background := a.colors.Ground
		switch {
		case selected:
			background = a.colors.Selection
		case l.currentRows[row.CommitHash]:
			background = currentBranchBackground(dark)
		}
		a.paintLabels(canvas, labelRect, group, labelText, background)
	}
}

// graphColors is the color of each color id of the graph in the current theme, cached.
func (a *App) graphColors() func(int32) gfx.Color {
	v, dark := &a.logView, a.colors.Dark
	if v.colorsDark != dark || v.colors == nil {
		v.colors, v.colorsDark = map[int32]gfx.Color{}, dark
	}
	return func(id int32) gfx.Color {
		c, ok := v.colors[id]
		if !ok {
			c = graphColor(id, dark, a.colors.Text)
			v.colors[id] = c
		}
		return c
	}
}

// dateColumn is the width of the date column in the canvas's fonts, measured again when they
// change.
func (v *logView) dateColumn(canvas *gfx.Canvas) float32 {
	if fonts := canvas.FontGeneration(); v.dateWidth == 0 || v.dateFonts != fonts {
		v.dateWidth, v.dateFonts = canvas.TextWidth(logDateSample, logMetaSize), fonts
	}
	return v.dateWidth
}

func (v *logView) metadataWidth(canvas *gfx.Canvas) float32 {
	return v.dateColumn(canvas) + logMetaGap
}

// paintGraphRow strokes the edges of one row and paints its node. Each row owns
// its pixel clip; boundary edges extend beyond it to keep their antialiased caps
// outside the visible line, without blending either row's fringe twice.
// HEAD has a ring and central dot;
// clipping crossing edges keeps the gap transparent on any row background.
func (a *App) paintGraphRow(canvas *gfx.Canvas, m graphMetrics, rect gfx.Rect, row core.GraphRow, color func(int32) gfx.Color) float32 {
	width := m.titleOffset(row)
	a.paintGraphRowWithHover(canvas, m, rect, row, width, 0, color, 0, 0)
	return width
}

// A nonzero chain paints only that chain over the list's row backgrounds.
func (a *App) paintGraphRowWithHover(canvas *gfx.Canvas, m graphMetrics, rect gfx.Rect, row core.GraphRow, width, inset float32, color func(int32) gfx.Color, logRow, chain int) {
	if width <= inset {
		return
	}
	overlap := max(m.lineWidth, 1)
	box := gfx.Rect{X: rect.X, Y: rect.Y, Width: width, Height: logRowHeight}
	clip := box
	clip.X += inset
	clip.Width -= inset
	canvas.Clip(clip)
	defer canvas.Unclip()
	center, outerRadius := m.marker(row)
	edgeClipRadius := outerRadius
	if chain != 0 && (outerRadius > 0 || row.HoverChain != chain) {
		// The overlay is painted after the normal graph. Stop its round cap
		// outside the marker so branch points and the HEAD gap stay intact.
		edgeClipRadius = graphHighlightCutoff(max(outerRadius, m.nodeRadius), m.lineWidth, canvas.PixelScale())
	}
	stroke := gfx.PathStyle{StrokeWidth: m.lineWidth, Cap: gfx.CapRound, Join: gfx.JoinRound}
	for i := 0; i < len(row.PrintElements); i++ {
		e := row.PrintElements[i]
		if chain != 0 && e.HoverChain != chain {
			continue
		}
		stroke.Cap = gfx.CapRound
		x0, y0, x1, y1 := m.strokeLine(e, chain != 0)
		// Join passing halves to avoid blending caps. An ordinary commit dot
		// covers the join of the two straight halves in its own chain.
		solidNodeJoin := chain == 0 && outerRadius == 0 && row.HoverChain != 0 && e.HoverChain == row.HoverChain
		if (e.Position != row.Lane || solidNodeJoin) && e.Direction == "up" && straightGraphHalf(e) && i+1 < len(row.PrintElements) {
			next := row.PrintElements[i+1]
			if next.Position == e.Position && next.ColorID == e.ColorID && next.HoverChain == e.HoverChain && next.Direction == "down" && straightGraphHalf(next) {
				y0, y1 = y1, logRowHeight+overlap
				if edgeClipRadius == 0 {
					// Both ends of the unbroken stroke are outside the row clip.
					stroke.Cap = gfx.CapButt
				}
				i++
			}
		}
		b := canvas.PathBuilder()
		traceGraphLine(b, gfx.Point{X: x0, Y: y0}, gfx.Point{X: x1, Y: y1}, center, edgeClipRadius, m.dashSpan(e))
		stroke.Stroke = color(e.ColorID)
		if chain != 0 {
			drawGraphHighlight(canvas, b.Path(width, logRowHeight), box, stroke, a.colors.Text, m.lineWidth)
			continue
		}
		if e.HasArrow {
			arrowTip, wings := graphArrowPoints(m, e)
			arrow := logGraphArrowHighlight{logRow, i}
			if logRow != 0 && (a.logView.hoveredGraphArrow == arrow || a.logView.focusedGraphArrow == arrow) {
				canvas.DrawPath(b.Path(width, logRowHeight), box, stroke)
				b = canvas.PathBuilder()
				cutoff := outerRadius
				if outerRadius > 0 {
					cutoff = graphHighlightCutoff(outerRadius, m.lineWidth, canvas.PixelScale())
				}
				for _, wing := range wings {
					traceGraphLine(b, arrowTip, wing, center, cutoff, 0)
				}
				path := b.Path(width, logRowHeight)
				if outerRadius == 0 {
					drawGraphHighlight(canvas, path, box, stroke, a.colors.Text, m.lineWidth)
					continue
				}
				// Trim the wider halo separately to keep the colored wing intact.
				canvas.DrawPath(path, box, graphOutlineStyle(stroke, a.colors.Text, m.lineWidth))
				b = canvas.PathBuilder()
			}
			for _, wing := range wings {
				traceGraphLine(b, arrowTip, wing, center, outerRadius, 0)
			}
		}
		canvas.DrawPath(b.Path(width, logRowHeight), box, stroke)
	}
	if chain != 0 && row.HoverChain != chain {
		return
	}
	radius := m.nodeRadius
	if outerRadius > 0 {
		b := canvas.PathBuilder()
		if chain != 0 {
			// Keep both the ring and dot as painted in the base pass. Only the
			// outside of the ring receives the highlight.
			b.Arc(center.X, center.Y, outerRadius+m.lineWidth/2, 0, 360)
			b.Close()
			canvas.DrawPath(b.Path(width, logRowHeight), box, gfx.PathStyle{Stroke: a.colors.Text, StrokeWidth: m.lineWidth})
			return
		}
		b.Arc(center.X, center.Y, outerRadius-m.lineWidth/2, 0, 360)
		b.Close()
		ring := gfx.PathStyle{Stroke: color(row.ColorID), StrokeWidth: m.lineWidth}
		canvas.DrawPath(b.Path(width, logRowHeight), box, ring)
		radius /= 2
	}
	// Use the same path transform as the edges. Rounded rectangles snap their
	// bounds again, which moves the node when the list origin is fractional.
	b := canvas.PathBuilder()
	b.Arc(center.X, center.Y, radius, 0, 360)
	b.Close()
	node := gfx.PathStyle{Fill: color(row.ColorID)}
	if chain != 0 {
		node.Stroke, node.StrokeWidth = a.colors.Text, m.lineWidth
	}
	canvas.DrawPath(b.Path(width, logRowHeight), box, node)
}

func drawGraphHighlight(canvas *gfx.Canvas, path gfx.Path, box gfx.Rect, stroke gfx.PathStyle, outline gfx.Color, width float32) {
	canvas.DrawPath(path, box, graphOutlineStyle(stroke, outline, width))
	canvas.DrawPath(path, box, stroke)
}

func graphOutlineStyle(stroke gfx.PathStyle, outline gfx.Color, width float32) gfx.PathStyle {
	stroke.Stroke = outline
	stroke.StrokeWidth += 2 * max(width, 1)
	return stroke
}

// graphHighlightCutoff accounts for the round cap and its antialiased fringe.
func graphHighlightCutoff(radius, width, scale float32) float32 {
	return radius + width/2 + max(width, 1) + .5/scale
}

func straightGraphHalf(e core.GraphElement) bool {
	return e.Position == e.AdjacentPosition && !e.IsDotted && !e.IsMissing && !e.HasArrow && !e.IsTerminal
}

// extendGraphEndpoint moves a non-terminal edge's boundary endpoint beyond the
// row by overlap in Y, along the same line. Even wide diagonals keep their cap
// outside the row's clip; no pixel is shared with the neighboring row's stroke.
func extendGraphEndpoint(x0, y0, x1, y1, overlap float32) (float32, float32) {
	dy := y1 - y0
	if dy == 0 || (y1 != 0 && y1 != logRowHeight) {
		return x1, y1
	}
	fraction := overlap / float32(math.Abs(float64(dy)))
	return x1 + (x1-x0)*fraction, y1 + dy*fraction
}

var (
	sqrt07 = float32(math.Sqrt(0.7))
	sqrt03 = float32(math.Sqrt(0.3))
)

func traceGraphLine(b *gfx.PathBuilder, from, to, center gfx.Point, radius, dashSpan float32) {
	visitGraphLine(from, to, center, radius, dashSpan, func(from, to gfx.Point) {
		b.MoveTo(from.X, from.Y)
		b.LineTo(to.X, to.Y)
	})
}

// visitGraphLine gives painting and hover the same stroke segments. The HEAD
// disk cuts every crossing edge without moving the dash pattern.
func visitGraphLine(from, to, center gfx.Point, radius, dashSpan float32, visit func(from, to gfx.Point)) {
	if radius == 0 && dashSpan == 0 {
		visit(from, to)
		return
	}
	length := float32(math.Hypot(float64(to.X-from.X), float64(to.Y-from.Y)))
	if length <= 0 {
		return
	}
	dx, dy := (to.X-from.X)/length, (to.Y-from.Y)/length
	segment := func(start, end float32) {
		visit(gfx.Point{X: from.X + dx*start, Y: from.Y + dy*start}, gfx.Point{X: from.X + dx*end, Y: from.Y + dy*end})
	}
	trace := func(start, end float32) {
		if start >= end {
			return
		}
		if dashSpan > 0 {
			visitGraphDashes(dashSpan, start, end, segment)
		} else {
			segment(start, end)
		}
	}
	if radius > 0 {
		cx, cy := center.X-from.X, center.Y-from.Y
		middle, cross := cx*dx+cy*dy, cx*dy-cy*dx
		if cross*cross < radius*radius {
			reach := float32(math.Sqrt(float64(radius*radius - cross*cross)))
			trace(0, min(length, max(0, middle-reach)))
			trace(min(length, max(0, middle+reach)), length)
			return
		}
	}
	trace(0, length)
}

// visitGraphDashes fits a dash and gap into a row, starting half a dash in.
// start and end clip the visible interval without changing the dash phase.
func visitGraphDashes(length, start, end float32, visit func(start, end float32)) {
	space := float32(logRowHeight/2 - 2)
	dash := length/max(1, float32(math.Floor(float64(length/logRowHeight)))) - space
	if dash <= 0 {
		visit(start, end)
		return
	}
	for pos := -dash / 2; pos < end; pos += dash + space {
		from, to := max(pos, start), min(pos+dash, end)
		if to > from {
			visit(from, to)
		}
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
	if text != g.title {
		canvas.HoverHint(0, rect, g.title)
	}
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
	if line != text {
		canvas.HoverHint(0, rect, text)
	}
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
