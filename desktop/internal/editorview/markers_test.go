package editorview

import (
	"context"
	"errors"
	"math"
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

// The language server counts UTF-16 units; tabs and wide glyphs occupy a
// different number of screen cells. Measure the actual painted geometry.
func TestDiagnosticUnderlineFollowsTextCells(t *testing.T) {
	for _, test := range []struct {
		name, text       string
		start, end, cell int
		cellWidth        float32
	}{
		{"tab", "\tMissing", 1, 8, tabSize, 10},
		{"wide", "中Missing", 1, 8, 2, 10},
		{"supplementary", "😀Missing", 2, 9, 2, 10},
		{"combined", "\t中😀Missing", 4, 11, tabSize + 4, 10},
		{"fractional-phase", "\t中😀Missing", 4, 11, tabSize + 4, 7.3},
	} {
		t.Run(test.name, func(t *testing.T) {
			v := newTestView(t, test.text)
			v.cellW, v.cellH, v.lineH, v.textLeft = test.cellWidth, 16, 24, 70
			v.SetMarkers([]Marker{{Line: 0, Start: test.start, End: test.end, Severity: MarkerError}})
			var canvas gfx.Canvas
			v.paintMarkers(&canvas, 0, 0, 100, 0, 0)
			left, right := float32(math.Inf(1)), float32(math.Inf(-1))
			for _, rectangle := range canvas.Rectangles() {
				left = min(left, rectangle.Bounds.X)
				right = max(right, rectangle.Bounds.X+rectangle.Bounds.Width)
			}
			for _, triangle := range canvas.Triangles() {
				for _, point := range triangle.Points {
					left, right = min(left, point.X), max(right, point.X)
				}
			}
			want := v.textLeft + float32(test.cell)*v.cellW
			if math.Abs(float64(left-want)) > 0.6 || math.Abs(float64(right-(want+7*v.cellW))) > 0.6 {
				t.Fatalf("underline spans %v..%v, want %v..%v under Missing", left, right, want, want+7*v.cellW)
			}
		})
	}
}

func TestDiagnosticUnderlineIsAWaveNearTheText(t *testing.T) {
	v := newTestView(t, "Missing")
	v.cellW, v.cellH, v.lineH = 10, 16, 36
	v.SetMarkers([]Marker{{Line: 0, Start: 0, End: 7, Severity: MarkerError}})
	var canvas gfx.Canvas
	v.paintMarkers(&canvas, 0, 0, 100, 0, 0)
	if len(canvas.Triangles()) < 4 || len(canvas.Rectangles()) != 0 {
		t.Fatal("diagnostics must draw a thin wave instead of a filled rectangle")
	}
	for _, triangle := range canvas.Triangles() {
		for _, point := range triangle.Points {
			if point.Y < 24 || point.Y > 29 {
				t.Fatalf("wave at y=%v is detached from the centered 16-point text", point.Y)
			}
		}
	}
}

func TestSetMarkersGroupsByLine(t *testing.T) {
	v := newTestView(t, "abcdef\nsecond\n0123456789")
	v.SetMarkers([]Marker{
		{Line: 2, Start: 4, End: 9, Severity: MarkerError},
		{Line: 0, Start: 0, End: 3, Severity: MarkerWarning},
		{Line: 2, Start: 0, End: 2, Severity: MarkerInfo},
	})
	if len(v.markers) != 2 {
		t.Fatalf("markers = %v", v.markers)
	}
	if len(v.markers[2]) != 2 || len(v.markers[0]) != 1 {
		t.Fatalf("markers = %v", v.markers)
	}
}

func TestSetMarkersDropsInvisibleOnes(t *testing.T) {
	v := newTestView(t, "abcdef")
	v.SetMarkers([]Marker{
		{Line: -1, Start: 0, End: 1},
		{Line: 0, Start: -1, End: 2},
		{Line: 0, Start: 3, End: 3},
		{Line: 0, Start: 4, End: 2},
	})
	// An underline of no width is invisible, and a negative one has no cells at all.
	if v.markers != nil {
		t.Fatalf("markers = %v", v.markers)
	}
}

func TestSetMarkersReplacesThePreviousSet(t *testing.T) {
	v := newTestView(t, "first\nsecond\nthird\nfourth")
	v.SetMarkers([]Marker{{Line: 1, Start: 0, End: 2}})
	v.SetMarkers([]Marker{{Line: 3, Start: 1, End: 4}})
	if len(v.markers) != 1 {
		t.Fatalf("markers = %v", v.markers)
	}
	if _, ok := v.markers[1]; ok {
		t.Fatalf("a stale marker survived: %v", v.markers)
	}
	if len(v.markers[3]) != 1 {
		t.Fatalf("markers = %v", v.markers)
	}
	// A server that fixed everything clears the set.
	v.SetMarkers(nil)
	if v.markers != nil {
		t.Fatalf("markers = %v", v.markers)
	}
}

func TestMarkerColorDistinguishesSeverities(t *testing.T) {
	errorColor := markerColor(MarkerError)
	warningColor := markerColor(MarkerWarning)
	infoColor := markerColor(MarkerInfo)
	if errorColor == warningColor || warningColor == infoColor || errorColor == infoColor {
		t.Fatalf("colours = %v %v %v", errorColor, warningColor, infoColor)
	}
	// An unknown severity still draws something readable rather than nothing.
	if markerColor(MarkerSeverity(99)) != infoColor {
		t.Fatal("an unknown severity did not fall back to info")
	}
}

func TestDiagnosticProjectionCancelsAndRefusesAnEditedRevision(t *testing.T) {
	v := newTestView(t, strings.Repeat("\t中😀", 2048)+"Missing")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := ProjectMarkers(ctx, v.TextSnapshot(), []Marker{{Line: 0, Start: 1, End: 8}}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled projection: %v", err)
	}
	revision := v.Revision()
	projected, err := ProjectMarkers(context.Background(), v.TextSnapshot(), []Marker{{Line: 0, Start: 4 * 2048, End: 4*2048 + 7}})
	if err != nil {
		t.Fatal(err)
	}
	if got := projected.lines[0][0]; got.Start != 8*2048 || got.End != 8*2048+7 {
		t.Fatalf("chunk-spanning cells: %+v", got)
	}
	v.typeText("changed")
	if v.SetProjectedMarkers(projected, revision) {
		t.Fatal("stale worker geometry reached edited text")
	}
}
