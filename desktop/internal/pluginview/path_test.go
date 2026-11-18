package pluginview

import (
	"math"
	"testing"
)

// seg is a segment written briefly: op and its points.
func seg(op byte, points ...float64) segment {
	s := segment{op: op}
	copy(s.points[:], points)
	return s
}

// sameSegments compares two segment lists to a tolerance that absorbs arc arithmetic.
func sameSegments(got, want []segment) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i].op != want[i].op {
			return false
		}
		for j := range got[i].points {
			if math.Abs(got[i].points[j]-want[i].points[j]) > 1e-9 {
				return false
			}
		}
	}
	return true
}

func TestParsePathDataReadsEveryCommand(t *testing.T) {
	for _, tc := range []struct {
		name string
		data string
		want []segment
	}{
		{"absolute lines", "M10 20 L30 40", []segment{seg('M', 10, 20), seg('L', 30, 40)}},
		{"relative lines, H, V and Z", "m10 20 l5 5 h10 v-5 z",
			[]segment{seg('M', 10, 20), seg('L', 15, 25), seg('L', 25, 25), seg('L', 25, 20), seg('Z')}},
		{"absolute H and V", "M1 2 H8 V9", []segment{seg('M', 1, 2), seg('L', 8, 2), seg('L', 8, 9)}},
		{"pairs after a move are lines", "M0 0 10 10 20 0", []segment{seg('M', 0, 0), seg('L', 10, 10), seg('L', 20, 0)}},
		{"pairs after a relative move are relative lines", "m1 1 2 2", []segment{seg('M', 1, 1), seg('L', 3, 3)}},
		{"a move after Z starts from the subpath's start", "M5 5 L9 5 Z m1 1 l1 0",
			[]segment{seg('M', 5, 5), seg('L', 9, 5), seg('Z'), seg('M', 6, 6), seg('L', 7, 6)}},
		{"S reflects the previous control", "M0 0 C10 0 20 10 30 10 S50 20 60 20",
			[]segment{seg('M', 0, 0), seg('C', 10, 0, 20, 10, 30, 10), seg('C', 40, 10, 50, 20, 60, 20)}},
		{"S after a line starts at the current point", "M0 0 L5 5 S10 10 20 0",
			[]segment{seg('M', 0, 0), seg('L', 5, 5), seg('C', 5, 5, 10, 10, 20, 0)}},
		{"relative C and S", "M10 10 c0 -10 10 -10 10 0 s10 10 10 0",
			[]segment{seg('M', 10, 10), seg('C', 10, 0, 20, 0, 20, 10), seg('C', 20, 20, 30, 20, 30, 10)}},
		{"T reflects the previous quadratic control", "M0 0 Q10 10 20 0 T40 0",
			[]segment{seg('M', 0, 0), seg('Q', 10, 10, 20, 0), seg('Q', 30, -10, 40, 0)}},
		{"T after a move uses the current point", "M3 4 T10 4", []segment{seg('M', 3, 4), seg('Q', 3, 4, 10, 4)}},
		{"SVG number forms", "M1.5.5L1-2M1e1 2E-1", []segment{seg('M', 1.5, 0.5), seg('L', 1, -2), seg('M', 10, 0.2)}},
		{"commas and line breaks separate numbers", "M1,2\nL3,4", []segment{seg('M', 1, 2), seg('L', 3, 4)}},
		{"a zero radius arc is a line", "M0 0 A0 5 0 0 1 10 0", []segment{seg('M', 0, 0), seg('L', 10, 0)}},
		{"an arc to its own start draws nothing", "M4 4 A5 5 0 0 1 4 4", []segment{seg('M', 4, 4)}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := parsePathData(tc.data); !sameSegments(got, tc.want) {
				t.Fatalf("parsePathData(%q) = %v, want %v", tc.data, got, tc.want)
			}
		})
	}
}

func TestParsePathDataStopsAtTheFirstError(t *testing.T) {
	for _, tc := range []struct {
		name string
		data string
		want []segment
	}{
		{"a line missing its y", "M0 0 L10", []segment{seg('M', 0, 0)}},
		{"a command before any move", "L10 10", nil},
		{"numbers after Z", "M0 0 L1 1 Z 5 5", []segment{seg('M', 0, 0), seg('L', 1, 1), seg('Z')}},
		{"a letter that is no command", "M0 0 X1 1", []segment{seg('M', 0, 0)}},
		{"an arc flag that is not 0 or 1", "M0 0 A5 5 0 2 1 10 0", []segment{seg('M', 0, 0)}},
		{"no data", "", nil},
		{"only separators", " ,\n", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := parsePathData(tc.data); !sameSegments(got, tc.want) {
				t.Fatalf("parsePathData(%q) = %v, want %v", tc.data, got, tc.want)
			}
		})
	}
}

func TestParsePathDataTurnsArcsIntoQuarterCurves(t *testing.T) {
	// A half circle of radius 10 about (10, 0), drawn as two quarter turns.
	got := parsePathData("M0 0 A10 10 0 0 1 20 0")
	if len(got) != 3 || got[1].op != 'C' || got[2].op != 'C' {
		t.Fatalf("half circle = %v, want a move and two curves", got)
	}
	middle := got[1].points
	if radius := math.Hypot(middle[4]-10, middle[5]); math.Abs(radius-10) > 1e-9 {
		t.Errorf("the quarter point %v is %v from the center, want 10", middle[4:6], radius)
	}
	if end := got[2].points; end[4] != 20 || end[5] != 0 {
		t.Errorf("the arc ends at %v, want exactly (20, 0)", end[4:6])
	}
	// Flags that touch the next number, and a radius too small for the distance, which
	// SVG scales up until the arc reaches its end.
	touching := parsePathData("M0 0a5 5 0 1120 0")
	if len(touching) < 2 {
		t.Fatalf("arc with touching flags = %v", touching)
	}
	if end := touching[len(touching)-1].points; end[4] != 20 || end[5] != 0 {
		t.Errorf("the scaled arc ends at %v, want (20, 0)", end[4:6])
	}
	// The other sweep runs through the other side of the center.
	other := parsePathData("M0 0 A10 10 0 0 0 20 0")
	if len(other) != 3 || math.Signbit(other[1].points[5]) == math.Signbit(middle[5]) {
		t.Errorf("sweep 0 = %v, want the half circle on the other side", other)
	}
}

func TestGeometryOfBoundsThePathAndKeepsIt(t *testing.T) {
	line := &Shape{Type: "path", D: "M10 20 H30"}
	geometry := line.geometryOf()
	if geometry.empty || geometry.x != 9 || geometry.y != 19 || geometry.w != 22 || geometry.h != 2 {
		t.Fatalf("horizontal line geometry = %+v, want one unit around the points", geometry)
	}
	if line.geometryOf() != geometry {
		t.Fatal("the parsed path was not kept with the shape")
	}
	curve := &Shape{Type: "path", D: "M0 0 C-5 10 25 10 20 0"}
	if g := curve.geometryOf(); g.x != -6 || g.y != -1 || g.w != 32 || g.h != 12 {
		t.Fatalf("curve geometry = %+v, want its control points inside", g)
	}
	if empty := (&Shape{Type: "path", D: "L1 1"}).geometryOf(); !empty.empty {
		t.Fatal("a path with no segment is drawn")
	}
}
