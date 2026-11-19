package pluginview

import (
	"math"
	"strconv"

	"github.com/vivaui/viva/gfx"
)

// pathGeometry is a canvas path parsed once: the Viva path in its own view box, which
// starts at (X, Y) of the canvas's view box and is W × H units large.
type pathGeometry struct {
	path       gfx.Path
	x, y, w, h float64
	empty      bool
}

// segment is one absolute path command: op is 'M', 'L', 'Q', 'C' or 'Z', with up
// to three points.
type segment struct {
	op     byte
	points [6]float64
}

// geometryOf parses the shape's path data on first use and keeps the result with
// the decoded view, so a frame draws a path without parsing it again.
func (s *Shape) geometryOf() *pathGeometry {
	if s.geometry != nil {
		return s.geometry
	}
	segments := parsePathData(s.D)
	geometry := &pathGeometry{empty: len(segments) == 0}
	if !geometry.empty {
		left, top, right, bottom := math.Inf(1), math.Inf(1), math.Inf(-1), math.Inf(-1)
		for _, segment := range segments {
			for index := 0; index < segment.count(); index++ {
				x, y := segment.points[2*index], segment.points[2*index+1]
				left, top = math.Min(left, x), math.Min(top, y)
				right, bottom = math.Max(right, x), math.Max(bottom, y)
			}
		}
		// One unit around the points keeps a horizontal or vertical line, which has
		// no height or width, a valid view box. The mapping to the canvas stays exact.
		geometry.x, geometry.y = left-1, top-1
		geometry.w, geometry.h = right-left+2, bottom-top+2
		commands := make([]gfx.PathCommand, 0, len(segments))
		at := func(index int, segment segment) (float32, float32) {
			return float32(segment.points[2*index] - geometry.x), float32(segment.points[2*index+1] - geometry.y)
		}
		for _, segment := range segments {
			switch segment.op {
			case 'M':
				x, y := at(0, segment)
				commands = append(commands, gfx.MoveTo(x, y))
			case 'L':
				x, y := at(0, segment)
				commands = append(commands, gfx.LineTo(x, y))
			case 'Q':
				cx, cy := at(0, segment)
				x, y := at(1, segment)
				commands = append(commands, gfx.QuadTo(cx, cy, x, y))
			case 'C':
				c1x, c1y := at(0, segment)
				c2x, c2y := at(1, segment)
				x, y := at(2, segment)
				commands = append(commands, gfx.CubicTo(c1x, c1y, c2x, c2y, x, y))
			case 'Z':
				commands = append(commands, gfx.ClosePath())
			}
		}
		geometry.path = gfx.NewPath(float32(geometry.w), float32(geometry.h), commands...)
	}
	s.geometry = geometry
	return geometry
}

// count is the number of points the segment carries.
func (s segment) count() int {
	switch s.op {
	case 'M', 'L':
		return 1
	case 'Q':
		return 2
	case 'C':
		return 3
	}
	return 0
}

// parsePathData reads SVG path data (MmLlHhVvCcSsQqTtAaZz) into absolute moves,
// lines, quadratic and cubic curves. Arcs become cubic curves. Core checked the
// letters and the length; data that stops making sense ends the path where it
// does, as an SVG renderer draws an erroneous path up to the error.
func parsePathData(data string) []segment {
	var (
		scan             = scanner{text: data}
		out              []segment
		x, y             float64
		startX, startY   float64
		controlX         float64
		controlY         float64
		previous         byte
		command          byte
		haveCurrentPoint bool
	)
	for {
		scan.skipSeparators()
		if scan.done() {
			return out
		}
		if letter := scan.peek(); isPathLetter(letter) {
			command = letter
			scan.pos++
		} else if command == 0 || command == 'Z' || command == 'z' {
			return out
		}
		relative := command >= 'a'
		upper := command &^ 0x20
		if upper != 'M' && !haveCurrentPoint {
			return out
		}
		offset := func(px, py float64) (float64, float64) {
			if relative {
				return px + x, py + y
			}
			return px, py
		}
		switch upper {
		case 'Z':
			out = append(out, segment{op: 'Z'})
			x, y = startX, startY
		case 'M':
			px, py, ok := scan.pair()
			if !ok {
				return out
			}
			x, y = offset(px, py)
			startX, startY = x, y
			haveCurrentPoint = true
			out = append(out, segment{op: 'M', points: [6]float64{x, y}})
			// Further pairs after a move are lines, relative when the move was.
			command = 'L' | command&0x20
		case 'L':
			px, py, ok := scan.pair()
			if !ok {
				return out
			}
			x, y = offset(px, py)
			out = append(out, segment{op: 'L', points: [6]float64{x, y}})
		case 'H':
			value, ok := scan.number()
			if !ok {
				return out
			}
			if relative {
				value += x
			}
			x = value
			out = append(out, segment{op: 'L', points: [6]float64{x, y}})
		case 'V':
			value, ok := scan.number()
			if !ok {
				return out
			}
			if relative {
				value += y
			}
			y = value
			out = append(out, segment{op: 'L', points: [6]float64{x, y}})
		case 'C', 'S':
			c1x, c1y := x, y
			if upper == 'C' {
				px, py, ok := scan.pair()
				if !ok {
					return out
				}
				c1x, c1y = offset(px, py)
			} else if previous == 'C' || previous == 'S' {
				c1x, c1y = 2*x-controlX, 2*y-controlY
			}
			p2x, p2y, ok := scan.pair()
			if !ok {
				return out
			}
			p3x, p3y, ok := scan.pair()
			if !ok {
				return out
			}
			c2x, c2y := offset(p2x, p2y)
			ex, ey := offset(p3x, p3y)
			out = append(out, segment{op: 'C', points: [6]float64{c1x, c1y, c2x, c2y, ex, ey}})
			controlX, controlY = c2x, c2y
			x, y = ex, ey
		case 'Q', 'T':
			cx, cy := x, y
			if upper == 'Q' {
				px, py, ok := scan.pair()
				if !ok {
					return out
				}
				cx, cy = offset(px, py)
			} else if previous == 'Q' || previous == 'T' {
				cx, cy = 2*x-controlX, 2*y-controlY
			}
			px, py, ok := scan.pair()
			if !ok {
				return out
			}
			ex, ey := offset(px, py)
			out = append(out, segment{op: 'Q', points: [6]float64{cx, cy, ex, ey}})
			controlX, controlY = cx, cy
			x, y = ex, ey
		case 'A':
			rx, okRX := scan.number()
			ry, okRY := scan.number()
			rotation, okRotation := scan.number()
			large, okLarge := scan.flag()
			sweep, okSweep := scan.flag()
			px, py, okEnd := scan.pair()
			if !okRX || !okRY || !okRotation || !okLarge || !okSweep || !okEnd {
				return out
			}
			ex, ey := offset(px, py)
			out = appendArc(out, x, y, rx, ry, rotation, large, sweep, ex, ey)
			x, y = ex, ey
		}
		previous = upper
	}
}

// appendArc appends the elliptical arc from (x1, y1) to (x2, y2) as cubic curves of
// at most a quarter turn each, following the endpoint-to-center conversion of SVG 1.1
// appendix F.6.5 and F.6.6.
func appendArc(out []segment, x1, y1, rx, ry, rotation float64, large, sweep bool, x2, y2 float64) []segment {
	if x1 == x2 && y1 == y2 {
		return out
	}
	rx, ry = math.Abs(rx), math.Abs(ry)
	if rx == 0 || ry == 0 {
		return append(out, segment{op: 'L', points: [6]float64{x2, y2}})
	}
	phi := rotation * math.Pi / 180
	cos, sin := math.Cos(phi), math.Sin(phi)
	dx, dy := (x1-x2)/2, (y1-y2)/2
	x1p, y1p := cos*dx+sin*dy, -sin*dx+cos*dy
	if lambda := x1p*x1p/(rx*rx) + y1p*y1p/(ry*ry); lambda > 1 {
		root := math.Sqrt(lambda)
		rx, ry = rx*root, ry*root
	}
	numerator := rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
	denominator := rx*rx*y1p*y1p + ry*ry*x1p*x1p
	coefficient := 0.0
	if numerator > 0 && denominator > 0 {
		coefficient = math.Sqrt(numerator / denominator)
	}
	if large == sweep {
		coefficient = -coefficient
	}
	cxp, cyp := coefficient*rx*y1p/ry, -coefficient*ry*x1p/rx
	cx := cos*cxp - sin*cyp + (x1+x2)/2
	cy := sin*cxp + cos*cyp + (y1+y2)/2
	ux, uy := (x1p-cxp)/rx, (y1p-cyp)/ry
	vx, vy := (-x1p-cxp)/rx, (-y1p-cyp)/ry
	start := math.Atan2(uy, ux)
	delta := math.Atan2(ux*vy-uy*vx, ux*vx+uy*vy)
	if !sweep && delta > 0 {
		delta -= 2 * math.Pi
	} else if sweep && delta < 0 {
		delta += 2 * math.Pi
	}
	pieces := int(math.Ceil(math.Abs(delta)/(math.Pi/2) - 1e-9))
	pieces = max(pieces, 1)
	step := delta / float64(pieces)
	handle := 4.0 / 3.0 * math.Tan(step/4)
	point := func(px, py float64) (float64, float64) {
		return cx + rx*px*cos - ry*py*sin, cy + rx*px*sin + ry*py*cos
	}
	for piece := 0; piece < pieces; piece++ {
		from := start + float64(piece)*step
		to := from + step
		c1x, c1y := point(math.Cos(from)-handle*math.Sin(from), math.Sin(from)+handle*math.Cos(from))
		c2x, c2y := point(math.Cos(to)+handle*math.Sin(to), math.Sin(to)-handle*math.Cos(to))
		ex, ey := point(math.Cos(to), math.Sin(to))
		if piece == pieces-1 {
			ex, ey = x2, y2
		}
		out = append(out, segment{op: 'C', points: [6]float64{c1x, c1y, c2x, c2y, ex, ey}})
	}
	return out
}

// isPathLetter reports whether b is one of the SVG path commands.
func isPathLetter(b byte) bool {
	switch b | 0x20 {
	case 'm', 'l', 'h', 'v', 'c', 's', 'q', 't', 'a', 'z':
		return true
	}
	return false
}

// scanner reads the numbers of SVG path data.
type scanner struct {
	text string
	pos  int
}

func (s *scanner) done() bool { return s.pos >= len(s.text) }

func (s *scanner) peek() byte { return s.text[s.pos] }

// skipSeparators skips white space and at most the commas between numbers.
func (s *scanner) skipSeparators() {
	for !s.done() {
		switch s.peek() {
		case ' ', '\t', '\n', '\r', '\f', ',':
			s.pos++
		default:
			return
		}
	}
}

// number reads one SVG number: an optional sign, digits with an optional fraction,
// and an optional exponent. "1.5.5" is two numbers and "1-2" is two, as in SVG.
func (s *scanner) number() (float64, bool) {
	s.skipSeparators()
	begin := s.pos
	if !s.done() && (s.peek() == '+' || s.peek() == '-') {
		s.pos++
	}
	digits := s.digits()
	if !s.done() && s.peek() == '.' {
		s.pos++
		digits += s.digits()
	}
	if digits == 0 {
		s.pos = begin
		return 0, false
	}
	if !s.done() && (s.peek() == 'e' || s.peek() == 'E') {
		mark := s.pos
		s.pos++
		if !s.done() && (s.peek() == '+' || s.peek() == '-') {
			s.pos++
		}
		if s.digits() == 0 {
			s.pos = mark
		}
	}
	value, err := strconv.ParseFloat(s.text[begin:s.pos], 64)
	return value, err == nil
}

// digits skips a run of decimal digits and returns its length.
func (s *scanner) digits() int {
	begin := s.pos
	for !s.done() && s.peek() >= '0' && s.peek() <= '9' {
		s.pos++
	}
	return s.pos - begin
}

// pair reads an x and y.
func (s *scanner) pair() (float64, float64, bool) {
	x, ok := s.number()
	if !ok {
		return 0, 0, false
	}
	y, ok := s.number()
	return x, y, ok
}

// flag reads an arc flag, a single 0 or 1 that may touch the next number.
func (s *scanner) flag() (bool, bool) {
	s.skipSeparators()
	if s.done() {
		return false, false
	}
	switch s.peek() {
	case '0':
		s.pos++
		return false, true
	case '1':
		s.pos++
		return true, true
	}
	return false, false
}
