package pluginview

import (
	"math"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// A canvas draws its scene in view-box coordinates. One without pan shows its whole view box
// at zoom 1: scaled to the width of the view, but never taller than the canvas, from the
// canvas's top-left corner, so a scene designed at the narrowest page keeps its size and
// stays whole as the window widens. One with pan is scaled to the width of the view: at
// zoom 1 the view box's width fills the canvas and its top edge is at the canvas's top; a
// scene narrower than the canvas is centered, one shorter starts at the top. The user drags
// the empty area to pan (pan) and zooms with ⌘ or Control and the wheel, about the pointer,
// or with the host's zoom buttons, about the middle (zoom). The plain wheel scrolls the page.
// There is no pinch to zoom: Viva reports no trackpad magnify yet (#2182).
const (
	// canvasZoomStep is how far a zoom button zooms.
	canvasZoomStep = 1.25
	// canvasWheelZoom is how far a point of the wheel zooms: by exp(-delta*canvasWheelZoom).
	canvasWheelZoom = 0.01
	// canvasTooltipDelay is how long the pointer rests on a group before its tooltip shows.
	canvasTooltipDelay = 500 * time.Millisecond
	// canvasMinTextSize is the smallest text in pixels the canvas draws; smaller text,
	// zoomed far out, cannot be read and is left out.
	canvasMinTextSize = 4
)

// canvasState is the host's state of one canvas: where the user panned and zoomed it, the
// drag under way, and the groups the pointer rests on. It lives in memory and ends with the
// showing.
type canvasState struct {
	// zoom is the user's zoom, 1 at the canvas's fitted scale (scale); x and y are the
	// view-box point at the canvas's top-left corner. placed reports that x and y were set.
	zoom, x, y float64
	placed     bool

	dragging     bool
	from         gfx.Point
	fromX, fromY float64

	// rect is where the canvas was drawn last.
	rect gfx.Rect
	// node, host and session are those of the last paint, for the handlers that run between
	// paints.
	node    *Node
	host    *Host
	session *Session

	input ui.Handlers
	draw  func(*ui.DrawContext)
	made  bool

	// keys number the clickable groups' IDs in the order they were first drawn, so a group
	// keeps its part, and its focus, as the scene changes around it; ids are the reverse.
	keys map[string]int
	ids  []string

	// pointer is the part the pointer is over, -1 for none; hover is the part whose tooltip
	// is timed, and since when.
	pointer, hover int
	since          time.Duration
	// tip is the tooltip of the hovered group and anchor its rectangle, found in each draw.
	tip    string
	anchor gfx.Rect
	lines  []string
}

// make gives the state its handlers and draw function, once.
func (s *canvasState) make() {
	s.made, s.pointer, s.hover = true, -1, -1
	s.keys = map[string]int{}
	s.input = ui.Handlers{Scroll: s.scroll, Pointer: s.pointerEvent}
	s.draw = s.paint
}

// key is the stable part number of a clickable group, given on first sight.
func (s *canvasState) key(id string) int {
	key, ok := s.keys[id]
	if !ok {
		key = len(s.ids)
		s.keys[id] = key
		s.ids = append(s.ids, id)
	}
	return key
}

// zoomRange is the zoom range of n, [1, 1] for a canvas without zoom.
func zoomRange(n *Node) (low, high float64) {
	if n.Zoom == nil {
		return 1, 1
	}
	return n.Zoom[0], n.Zoom[1]
}

// scale is how many pixels one view-box unit takes in rect at the state's zoom; 0 for a
// view box without area, which draws nothing. At zoom 1 the view box's width fills rect,
// and a canvas without pan also keeps the view box's height within rect's.
func (s *canvasState) scale(rect gfx.Rect, n *Node) float64 {
	if n.ViewBox[2] <= 0 || n.ViewBox[3] <= 0 || rect.Width <= 0 {
		return 0
	}
	k := float64(rect.Width) / n.ViewBox[2]
	if !n.Pan && rect.Height > 0 {
		k = math.Min(k, float64(rect.Height)/n.ViewBox[3])
	}
	return k * s.zoom
}

// clamp keeps the visible part inside the view box: a view box narrower than the canvas
// is centered across it when the canvas pans and starts at its leading edge when it does
// not; one shorter than the canvas starts at its top.
func (s *canvasState) clamp(rect gfx.Rect, n *Node) {
	k := s.scale(rect, n)
	if k <= 0 {
		return
	}
	box := n.ViewBox
	if !s.placed {
		s.x, s.y, s.placed = box[0], box[1], true
	}
	width, height := float64(rect.Width)/k, float64(rect.Height)/k
	if width >= box[2] {
		s.x = box[0]
		if n.Pan {
			s.x -= (width - box[2]) / 2
		}
	} else {
		s.x = math.Min(math.Max(s.x, box[0]), box[0]+box[2]-width)
	}
	if height >= box[3] {
		s.y = box[1]
	} else {
		s.y = math.Min(math.Max(s.y, box[1]), box[1]+box[3]-height)
	}
}

// zoomAt zooms to zoom, within the canvas's range, keeping the view-box point under the
// pixel (px, py) where it is. It reports whether the zoom changed.
func (s *canvasState) zoomAt(rect gfx.Rect, n *Node, zoom float64, px, py float32) bool {
	low, high := zoomRange(n)
	zoom = math.Min(math.Max(zoom, low), high)
	before := s.scale(rect, n)
	if zoom == s.zoom || before <= 0 {
		return false
	}
	s.clamp(rect, n)
	dx, dy := float64(px-rect.X), float64(py-rect.Y)
	vx, vy := s.x+dx/before, s.y+dy/before
	s.zoom = zoom
	after := s.scale(rect, n)
	s.x, s.y = vx-dx/after, vy-dy/after
	s.clamp(rect, n)
	return true
}

// viewport is the visible part of the canvas in view-box coordinates.
func (s *canvasState) viewport(rect gfx.Rect, n *Node) Viewport {
	k := s.scale(rect, n)
	if k <= 0 {
		return Viewport{}
	}
	return Viewport{X: s.x, Y: s.y, Width: float64(rect.Width) / k, Height: float64(rect.Height) / k}
}

// moved tells the plugin where the canvas now lies, once it stops moving, when it asked.
func (s *canvasState) moved() {
	if s.node != nil && slices.Contains(s.node.On, "viewport") {
		s.session.ViewportMoved(s.node.ID, s.viewport(s.rect, s.node))
	}
}

// scroll zooms about the pointer for ⌘ or Control and the wheel, and leaves the plain
// wheel to the page around the canvas.
func (s *canvasState) scroll(event gfx.ScrollEvent) gfx.EventResult {
	n := s.node
	if n == nil || n.Zoom == nil || event.Modifiers&(gfx.ModifierControl|gfx.ModifierMeta) == 0 {
		return gfx.EventResult{}
	}
	if s.zoomAt(s.rect, n, s.zoom*math.Exp(-float64(event.DeltaY)*canvasWheelZoom), event.X, event.Y) {
		s.moved()
	}
	return gfx.EventResult{Handled: true, Repaint: true}
}

// pointerEvent drags the empty area to pan and notes the group the pointer is over. An
// event aimed at a group stays unhandled, so the page presses, clicks and focuses it.
func (s *canvasState) pointerEvent(event gfx.PointerEvent) gfx.EventResult {
	n := s.node
	if n == nil {
		return gfx.EventResult{}
	}
	part, onPart := event.Target.In(s.input.Parts())
	switch event.Kind {
	case gfx.PointerDown:
		if !n.Pan || onPart || event.Button != gfx.PointerButtonPrimary {
			return gfx.EventResult{}
		}
		s.dragging, s.from, s.fromX, s.fromY = true, gfx.Point{X: event.X, Y: event.Y}, s.x, s.y
		return gfx.EventResult{Handled: true}
	case gfx.PointerMove:
		if s.dragging {
			if k := s.scale(s.rect, n); k > 0 {
				s.x = s.fromX - float64(event.X-s.from.X)/k
				s.y = s.fromY - float64(event.Y-s.from.Y)/k
				s.clamp(s.rect, n)
				s.moved()
			}
			return gfx.EventResult{Handled: true, Repaint: true}
		}
		over := -1
		if onPart {
			over = part
		}
		if over != s.pointer {
			s.pointer = over
			return gfx.EventResult{Repaint: true}
		}
	case gfx.PointerUp:
		if s.dragging {
			s.dragging = false
			return gfx.EventResult{Handled: true, Repaint: true}
		}
	case gfx.PointerExit:
		if s.dragging && !event.Captured {
			s.dragging = false
		}
		if !s.dragging && s.pointer >= 0 {
			s.pointer = -1
			return gfx.EventResult{Repaint: true}
		}
	}
	return gfx.EventResult{}
}

// canvas declares a canvas: the zoom buttons above it when it zooms, then the scene, and
// sends click for a group clicked or activated with Enter or Space.
func (r *renderer) canvas(c ui.C, n *Node) {
	state := r.s.canvas(n.ID)
	if !state.made {
		state.make()
	}
	state.node, state.host, state.session = n, r.host, r.s
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		if n.Zoom != nil {
			r.zoomButtons(c, state)
		}
		ui.Control(c.Part("canvas"), n.Label, &state.input).FillWidth().Height(float32(n.Height)).Clip().Draw(state.draw)
	})
	canvas := c.Canvas()
	if canvas == nil {
		return
	}
	if i, ok := canvas.ClickedIn(state.input.Parts()); ok && i < len(state.ids) {
		r.s.Send(Event{Name: "click", Canvas: n.ID, Node: state.ids[i]})
	}
	// The tooltip shows once the pointer has rested on a group for canvasTooltipDelay.
	now := canvas.Now()
	if state.pointer != state.hover {
		state.hover, state.since = state.pointer, now
	}
	if state.hover >= 0 {
		if left := canvasTooltipDelay - (now - state.since); left > 0 {
			canvas.RequestFrameIn(left)
		}
	}
}

// zoomButtons declares the zoom buttons over the canvas's trailing edge: zoom out, the
// percentage, which resets the zoom to 100%, and zoom in. They zoom about the middle.
func (r *renderer) zoomButtons(c ui.C, state *canvasState) {
	p := &r.host.Palette
	language := r.host.Language
	zoomTo := func(zoom float64) {
		c.After(func() {
			rect := state.rect
			if state.zoomAt(rect, state.node, zoom, rect.X+rect.Width/2, rect.Y+rect.Height/2) {
				state.moved()
			}
		})
	}
	ui.Row(c.Part("zoom")).FillWidth().Items(ui.Center).Justify(ui.End).Gap(2).Children(func() {
		if zoomButton(c.Part("zoom-out"), i18n.Shared(language, "desktop.viewer.zoomOut"), icons.ZoomOut) {
			zoomTo(state.zoom / canvasZoomStep)
		}
		k := c.Part("zoom-reset")
		percent := strconv.Itoa(int(math.Round(state.zoom*100))) + "%"
		button := ui.Row(k).Size(44, 26).Shrink(0).Center().Radius(6).
			HitWith(ui.ID(k), i18n.Shared(language, "desktop.pluginView.zoom"), gfx.HitOptions{
				Role: gfx.RoleButton, Value: percent, Hint: i18n.Shared(language, "desktop.pluginView.resetZoomHint"), Cursor: gfx.PointerCursorHand,
			}).
			Hover(ui.Look{}.Background(p.Hover)).Pressed(ui.Look{}.Background(p.Selection)).
			Tooltip(i18n.Shared(language, "desktop.pluginView.resetZoom"))
		button.Children(func() {
			ui.Text(c, percent).FontSize(11).Weight(gfx.WeightMedium).Mono().Color(p.Text)
		})
		if button.Clicked() {
			zoomTo(1)
		}
		if zoomButton(c.Part("zoom-in"), i18n.Shared(language, "desktop.viewer.zoomIn"), icons.ZoomIn) {
			zoomTo(state.zoom * canvasZoomStep)
		}
	})
}

// zoomButton declares one icon button of the zoom buttons and reports a click.
func zoomButton(c ui.C, label string, icon gfx.Icon) bool {
	return ui.Button(c, label).Icon(icon).IconOnly().Ghost().Size(26, 26).Shrink(0).Tooltip(label).Clicked()
}

// place maps view-box coordinates to pixels: pixel = origin + point × k.
type place struct {
	ox, oy, k float64
}

func (t place) point(x, y float64) (float32, float32) {
	return float32(t.ox + x*t.k), float32(t.oy + y*t.k)
}

func (t place) rect(x, y, w, h float64) gfx.Rect {
	left, top := t.point(x, y)
	return gfx.Rect{X: left, Y: top, Width: float32(w * t.k), Height: float32(h * t.k)}
}

// inner is the place of a group's children: they start at (x, y) and are scale times as large.
func (t place) inner(x, y, scale float64) place {
	return place{ox: t.ox + x*t.k, oy: t.oy + y*t.k, k: t.k * scale}
}

// scaled is t scaled by scale about the middle of the w × h area at its origin.
func (t place) scaled(w, h, scale float64) place {
	if scale == 1 {
		return t
	}
	return place{ox: t.ox + t.k*(w/2)*(1-scale), oy: t.oy + t.k*(h/2)*(1-scale), k: t.k * scale}
}

// painter draws one canvas scene in one draw.
type painter struct {
	d     *ui.DrawContext
	state *canvasState
	p     *Palette
	parts gfx.Scope
}

// paint draws the scene, the hovered group's tooltip over it, and nothing for a view box
// without area. It only paints: Viva may call it more than once a frame.
func (s *canvasState) paint(d *ui.DrawContext) {
	n := s.node
	if n == nil || s.host == nil {
		return
	}
	s.rect = d.Rect
	s.clamp(d.Rect, n)
	k := s.scale(d.Rect, n)
	if k <= 0 {
		return
	}
	s.tip = ""
	pt := &painter{d: d, state: s, p: &s.host.Palette, parts: s.input.Parts()}
	at := place{ox: float64(d.Rect.X) - s.x*k, oy: float64(d.Rect.Y) - s.y*k, k: k}
	pt.shapes(n.Nodes, at, d.Opacity)
	if s.tip != "" && s.hover >= 0 && d.Canvas.Now()-s.since >= canvasTooltipDelay {
		// Full text takes priority over the group's description while the pointer
		// rests on an ellipsized label. The page owns that shared tooltip.
		page := d.Frame.GetPage()
		if page == nil || page.HoveredText().Text == "" {
			pt.tooltip(s.tip, s.anchor)
		}
	}
}

// shapes draws shapes in order.
func (pt *painter) shapes(shapes []Shape, at place, opacity float32) {
	for i := range shapes {
		pt.shape(&shapes[i], at, opacity)
	}
}

// shape draws one shape.
func (pt *painter) shape(sh *Shape, at place, opacity float32) {
	opacity *= sh.opacity()
	if opacity <= 0 {
		return
	}
	switch sh.Type {
	case "rect":
		bounds := at.rect(sh.X, sh.Y, sh.W, sh.H)
		pt.area(bounds, float32(sh.Radius*at.k), sh.Fill, sh.Stroke, float32(sh.strokeWidth()*at.k), len(sh.Dash) > 0, sh.Shadow, opacity)
	case "path":
		pt.path(sh, at, opacity)
	case "text":
		pt.text(sh, at, opacity)
	case "image":
		// DrawBitmap takes no opacity, so an image is drawn opaque until Viva has one (#2182).
		if bitmap, ok := pt.state.host.Images.bitmap(sh.Src); ok {
			pt.d.Canvas.DrawBitmap(bitmap, at.rect(sh.X, sh.Y, sh.W, sh.H))
		}
	case "group":
		pt.group(sh, at, opacity)
	}
}

// area paints a rounded rectangle: its shadow, its fill (a color or a gradient), then its
// stroke, dashed or solid.
func (pt *painter) area(bounds gfx.Rect, radius float32, fill, stroke *Color, width float32, dashed bool, shadow int, opacity float32) {
	canvas := pt.d.Canvas
	if level, ok := shadowLevel(shadow); ok {
		canvas.ElevateFaded(bounds, radius, level, opacity)
	}
	if stops := pt.p.Stops(fill, opacity); stops != nil {
		canvas.FillGradient(bounds, radius, float32(fill.Angle), stops)
	} else if color, ok := pt.p.Solid(fill); ok {
		canvas.Rounded(bounds, radius, fade(color, opacity))
	}
	if color, ok := pt.p.Solid(stroke); ok && width > 0 {
		if dashed {
			canvas.DashedRoundedOutline(bounds, radius, width, fade(color, opacity))
		} else {
			canvas.RoundedOutline(bounds, radius, width, fade(color, opacity))
		}
	}
}

// shadowLevel is the host shadow of an elevation step 1–3; ok is false for none.
func shadowLevel(step int) (gfx.ShadowLevel, bool) {
	switch step {
	case 1:
		return gfx.ShadowSM, true
	case 2:
		return gfx.ShadowMD, true
	case 3:
		return gfx.ShadowLG, true
	}
	return gfx.ShadowNone, false
}

// path draws path data: its fill, a color or a gradient over its bounds, then its stroke.
func (pt *painter) path(sh *Shape, at place, opacity float32) {
	geometry := sh.geometryOf()
	if geometry.empty {
		return
	}
	style := gfx.PathStyle{Join: gfx.JoinRound}
	switch sh.Rule {
	case "evenodd":
		style.FillRule = gfx.PathFillEvenOdd
	default:
		style.FillRule = gfx.PathFillNonZero
	}
	switch sh.Cap {
	case "round":
		style.Cap = gfx.CapRound
	case "square":
		style.Cap = gfx.CapSquare
	default:
		style.Cap = gfx.CapButt
	}
	if stops := pt.p.Stops(sh.Fill, opacity); stops != nil {
		box := [4]float64{geometry.x + 1, geometry.y + 1, geometry.w - 2, geometry.h - 2}
		if sh.Bounds != nil {
			box = *sh.Bounds
		}
		style.FillGradient = pathGradient(stops, sh.Fill.Angle, box, geometry)
	} else if color, ok := pt.p.Solid(sh.Fill); ok {
		style.Fill = fade(color, opacity)
	}
	if color, ok := pt.p.Solid(sh.Stroke); ok {
		style.Stroke = fade(color, opacity)
		style.StrokeWidth = float32(sh.strokeWidth() * at.k)
		// Viva dashes are all one length: the lengths in dash wait for Viva (#2182).
		style.Dashed = len(sh.Dash) > 0
	}
	pt.d.Canvas.DrawPath(geometry.path, at.rect(geometry.x, geometry.y, geometry.w, geometry.h), style)
}

// pathGradient is the gradient of a path's fill over box, in the path's own units: the CSS
// gradient line through the middle of box at angle, between the first and the last stop.
// A Viva path gradient takes two colors, so stops between them are left out until it takes
// more (#2182).
func pathGradient(stops []gfx.GradientStop, angle float64, box [4]float64, geometry *pathGeometry) *gfx.LinearGradient {
	first, last := stops[0], stops[len(stops)-1]
	sin, cos := math.Sincos(angle * math.Pi / 180)
	dx, dy := sin, -cos
	length := math.Abs(box[2]*sin) + math.Abs(box[3]*cos)
	cx, cy := box[0]+box[2]/2-geometry.x, box[1]+box[3]/2-geometry.y
	sx, sy := cx-dx*length/2, cy-dy*length/2
	from, to := float64(first.At)*length, float64(last.At)*length
	return &gfx.LinearGradient{
		Start: gfx.Point{X: float32(sx + dx*from), Y: float32(sy + dy*from)},
		End:   gfx.Point{X: float32(sx + dx*to), Y: float32(sy + dy*to)},
		From:  first.Color,
		To:    last.Color,
	}
}

// canvasTextStyle is the font of a canvas text style at zoom 1.
func canvasTextStyle(style string) (size float32, weight float32, mono bool) {
	switch style {
	case "title":
		return 15, gfx.WeightSemibold, false
	case "strong":
		return 13, gfx.WeightSemibold, false
	case "caption":
		return 11, gfx.WeightRegular, false
	case "display":
		return 22, gfx.WeightSemibold, false
	case "mono":
		return 12, gfx.WeightRegular, true
	case "monoSmall":
		return 11, gfx.WeightRegular, true
	}
	return 13, gfx.WeightRegular, false
}

// text draws one line with its baseline at y: the text, or its runs one after another, each
// in its own color. align places the line's start, middle or end at x, and a line wider than
// maxWidth is cut and ends with an ellipsis.
func (pt *painter) text(sh *Shape, at place, opacity float32) {
	canvas := pt.d.Canvas
	size, weight, mono := canvasTextStyle(sh.Style)
	size *= float32(at.k)
	if size < canvasMinTextSize {
		return
	}
	style := gfx.TextStyle{Size: size, Weight: weight, Mono: mono}
	runs := sh.Runs
	if len(runs) == 0 {
		runs = []Run{{Text: sh.Text, Color: sh.Color}}
	}
	var total float32
	for _, run := range runs {
		total += canvas.TextWidthStyle(run.Text, style)
	}
	// Only a line wider than maxWidth is cut. The room left after some runs is a float32
	// difference that can come out a hair under the next run's own width, so a line that
	// fits must not fit its runs into that room.
	room := total
	cut := sh.MaxWidth > 0 && float32(sh.MaxWidth*at.k) < total
	if cut {
		room = float32(sh.MaxWidth * at.k)
	}
	x, baseline := at.point(sh.X, sh.Y)
	switch sh.Align {
	case "center":
		x -= room / 2
	case "end":
		x -= room
	}
	height := float32(math.Ceil(float64(size) * 1.5))
	left := room
	first := len(canvas.Texts())
	for _, run := range runs {
		if left <= 0 {
			break
		}
		color := pt.p.Text
		if own, ok := pt.p.Solid(run.Color); ok {
			color = own
		} else if own, ok := pt.p.Solid(sh.Color); ok {
			color = own
		}
		style.Color = fade(color, opacity)
		value, width := run.Text, canvas.TextWidthStyle(run.Text, style)
		if cut && width > left {
			value = pt.fit(value, style, left)
			width = left
		}
		canvas.LabelAlignedOnBaseline(value, gfx.Rect{X: x, Width: width + 1, Height: height}, baseline, style, gfx.AlignLeft)
		x += width
		left -= width
	}
	if cut && len(canvas.Texts()) > first {
		full := sh.Text
		if len(sh.Runs) > 0 {
			if sh.fullText == "" {
				var text strings.Builder
				for _, run := range sh.Runs {
					text.WriteString(run.Text)
				}
				sh.fullText = text.String()
			}
			full = sh.fullText
		}
		// The canvas resolves the font's real baseline; use the line box it
		// painted so the hover region follows proportional and mono text alike.
		bounds := canvas.Texts()[first].Bounds
		bounds.Width = room
		canvas.HoverHint(0, bounds, full)
	}
}

// fit is value cut to width with an ellipsis, in the font of style.
func (pt *painter) fit(value string, style gfx.TextStyle, width float32) string {
	if !style.Mono {
		return pt.d.Canvas.FitLine(value, style.Size, style.Weight, width)
	}
	lines := pt.d.Canvas.WrapLinesStyle(pt.state.lines[:0], value, style, width, 1, nil)
	pt.state.lines = lines
	if len(lines) == 0 {
		return ""
	}
	return lines[0]
}

// group draws a group: a clickable one takes its w × h area as its hit, and the states
// the pointer, the focus and selected give it paint that area behind the children and
// scale and fade the whole group.
func (pt *painter) group(sh *Shape, at place, opacity float32) {
	if sh.Hidden {
		return
	}
	canvas := pt.d.Canvas
	inner := at.inner(sh.X, sh.Y, sh.scale())
	look := State{Shadow: sh.Shadow}
	var id gfx.ID
	var state gfx.State
	clickable := sh.clickable() && sh.ID != ""
	if clickable {
		key := pt.state.key(sh.ID)
		id = pt.parts.At(key)
		state = canvas.StateOf(id)
		canvas.HitWithOptions(id, inner.rect(0, 0, sh.W, sh.H), sh.Label, gfx.HitOptions{
			Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Selected: sh.Selected,
		})
		if sh.States != nil {
			if sh.Selected {
				look.merge(sh.States.Selected)
			}
			if state.Hovered {
				look.merge(sh.States.Hover)
			}
			if state.Pressed {
				look.merge(sh.States.Pressed)
			}
		}
		if key == pt.state.hover && sh.Tooltip != "" {
			pt.state.tip, pt.state.anchor = sh.Tooltip, inner.rect(0, 0, sh.W, sh.H)
		}
	}
	if look.Opacity != nil {
		opacity *= float32(*look.Opacity)
	}
	scale := 1.0
	if look.Scale != nil {
		scale = *look.Scale
	}
	inner = inner.scaled(sh.W, sh.H, scale)
	bounds := inner.rect(0, 0, sh.W, sh.H)
	radius := float32(sh.Radius * inner.k)
	width := float32(1 * inner.k)
	if look.Width != nil {
		width = float32(*look.Width * inner.k)
	}
	pt.area(bounds, radius, look.Fill, look.Stroke, width, false, look.Shadow, opacity)
	// Viva clips to a rectangle, so a rounded group clips square, and opacity fades each child
	// rather than the group as one layer, until Viva has both (#2182).
	if sh.Clip {
		canvas.Clip(bounds)
	}
	pt.shapes(sh.Children, inner, opacity)
	if sh.Clip {
		canvas.Unclip()
	}
	if clickable && state.FocusVisible {
		ring := gfx.Rect{X: bounds.X - 2, Y: bounds.Y - 2, Width: bounds.Width + 4, Height: bounds.Height + 4}
		canvas.RoundedOutline(ring, radius+2, 2, pt.p.Accent)
	}
}

// merge lays state over l: what state sets replaces what l had.
func (l *State) merge(state *State) {
	if state == nil {
		return
	}
	if state.Fill != nil {
		l.Fill = state.Fill
	}
	if state.Stroke != nil {
		l.Stroke = state.Stroke
	}
	if state.Width != nil {
		l.Width = state.Width
	}
	if state.Shadow != 0 {
		l.Shadow = state.Shadow
	}
	if state.Scale != nil {
		l.Scale = state.Scale
	}
	if state.Opacity != nil {
		l.Opacity = state.Opacity
	}
}

// tooltip draws the host's tooltip bubble for text under anchor, or over it where the
// canvas has no room below, kept inside the canvas.
func (pt *painter) tooltip(text string, anchor gfx.Rect) {
	canvas, rect := pt.d.Canvas, pt.d.Rect
	style := gfx.TextStyle{Size: 12, Color: pt.p.PopoverText}
	const padX, padY, line = 8, 5, 16
	room := min(float32(320), rect.Width-16) - 2*padX
	if room <= 0 {
		return
	}
	lines := canvas.WrapLinesStyle(pt.state.lines[:0], text, style, room, 4, nil)
	pt.state.lines = lines
	if len(lines) == 0 {
		return
	}
	var widest float32
	for _, value := range lines {
		widest = max(widest, canvas.TextWidthStyle(value, style))
	}
	width, height := widest+2*padX, float32(len(lines))*line+2*padY
	x := anchor.X + anchor.Width/2 - width/2
	x = max(rect.X+4, min(x, rect.X+rect.Width-width-4))
	y := anchor.Y + anchor.Height + 6
	if y+height > rect.Y+rect.Height-4 {
		y = anchor.Y - height - 6
	}
	y = max(y, rect.Y+4)
	bubble := gfx.Rect{X: x, Y: y, Width: width, Height: height}
	canvas.ElevateFaded(bubble, 6, gfx.ShadowMD, 1)
	canvas.Rounded(bubble, 6, pt.p.Popover)
	for i, value := range lines {
		canvas.Label(value, gfx.Rect{X: x + padX, Y: y + padY + float32(i)*line, Width: widest + 1, Height: line}, style)
	}
}
