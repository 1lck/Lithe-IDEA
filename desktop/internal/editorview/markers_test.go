package editorview

import "testing"

func TestSetMarkersGroupsByLine(t *testing.T) {
	var v View
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
	var v View
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
	var v View
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
