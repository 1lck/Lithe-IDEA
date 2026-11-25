package icons

import "github.com/vivaui/viva/gfx"

// Prebuilt IDEA-style gutter navigation icons: green I badges for interface/contract
// implementations and blue O badges for inheritance overrides, plus directional fallbacks.
// Keeping them as package-level values preserves zero-allocation icon cache keys per frame.
var (
	gutterImplementedLight  = makeGutterNavBadge(gfx.RGB24(0x369650), gutterGlyphI(), gutterArrowDown())
	gutterImplementedDark   = makeGutterNavBadge(gfx.RGB24(0x57965C), gutterGlyphI(), gutterArrowDown())
	gutterImplementingLight = makeGutterNavBadge(gfx.RGB24(0x369650), gutterGlyphI(), gutterArrowUp())
	gutterImplementingDark  = makeGutterNavBadge(gfx.RGB24(0x57965C), gutterGlyphI(), gutterArrowUp())

	gutterOverriddenLight = makeGutterNavBadge(gfx.RGB24(0x3574F0), gutterGlyphO(), gutterArrowDown())
	gutterOverriddenDark  = makeGutterNavBadge(gfx.RGB24(0x548AF7), gutterGlyphO(), gutterArrowDown())
	gutterOverridingLight = makeGutterNavBadge(gfx.RGB24(0x3574F0), gutterGlyphO(), gutterArrowUp())
	gutterOverridingDark  = makeGutterNavBadge(gfx.RGB24(0x548AF7), gutterGlyphO(), gutterArrowUp())

	gutterNavigateDownLight = makeGutterNavArrowBadge(gfx.RGB24(0x369650), gutterArrowCenteredDown())
	gutterNavigateDownDark  = makeGutterNavArrowBadge(gfx.RGB24(0x57965C), gutterArrowCenteredDown())
	gutterNavigateUpLight   = makeGutterNavArrowBadge(gfx.RGB24(0x3574F0), gutterArrowCenteredUp())
	gutterNavigateUpDark    = makeGutterNavArrowBadge(gfx.RGB24(0x548AF7), gutterArrowCenteredUp())
)

// GutterImplemented returns the green "I" + down-arrow icon for implemented interfaces/contracts.
func GutterImplemented(dark bool) gfx.Icon {
	if dark {
		return gutterImplementedDark
	}
	return gutterImplementedLight
}

// GutterImplementing returns the green "I" + up-arrow icon for implementing declarations.
func GutterImplementing(dark bool) gfx.Icon {
	if dark {
		return gutterImplementingDark
	}
	return gutterImplementingLight
}

// GutterOverridden returns the blue "O" + down-arrow icon for overridden base declarations.
func GutterOverridden(dark bool) gfx.Icon {
	if dark {
		return gutterOverriddenDark
	}
	return gutterOverriddenLight
}

// GutterOverriding returns the blue "O" + up-arrow icon for overriding declarations.
func GutterOverriding(dark bool) gfx.Icon {
	if dark {
		return gutterOverridingDark
	}
	return gutterOverridingLight
}

// GutterNavigateDown returns the fallback downward navigation icon for navigate-implementations.
func GutterNavigateDown(dark bool) gfx.Icon {
	if dark {
		return gutterNavigateDownDark
	}
	return gutterNavigateDownLight
}

// GutterNavigateUp returns the fallback upward navigation icon for navigate-super.
func GutterNavigateUp(dark bool) gfx.Icon {
	if dark {
		return gutterNavigateUpDark
	}
	return gutterNavigateUpLight
}

func makeGutterNavBadge(badgeColor gfx.Color, letter, arrow gfx.IconLayer) gfx.Icon {
	return gfx.Icon{
		ViewBox: 16,
		Layers: []gfx.IconLayer{
			{Fill: badgeColor, Commands: gutterRoundedBadge()},
			letter,
			arrow,
		},
	}
}

func makeGutterNavArrowBadge(badgeColor gfx.Color, arrow gfx.IconLayer) gfx.Icon {
	return gfx.Icon{
		ViewBox: 16,
		Layers: []gfx.IconLayer{
			{Fill: badgeColor, Commands: gutterRoundedBadge()},
			arrow,
		},
	}
}

func gutterRoundedBadge() []gfx.PathCommand {
	// 15x14 rounded badge centered vertically inside 16x16 (x: 0.5..15.5, y: 1..15, r: 3.5).
	return []gfx.PathCommand{
		gfx.MoveTo(4.0, 1.0),
		gfx.LineTo(12.0, 1.0),
		gfx.CubicTo(13.933, 1.0, 15.5, 2.567, 15.5, 4.5),
		gfx.LineTo(15.5, 11.5),
		gfx.CubicTo(15.5, 13.433, 13.933, 15.0, 12.0, 15.0),
		gfx.LineTo(4.0, 15.0),
		gfx.CubicTo(2.067, 15.0, 0.5, 13.433, 0.5, 11.5),
		gfx.LineTo(0.5, 4.5),
		gfx.CubicTo(0.5, 2.567, 2.067, 1.0, 4.0, 1.0),
		gfx.ClosePath(),
	}
}

func gutterGlyphI() gfx.IconLayer {
	white := gfx.RGB24(0xFFFFFF)
	return gfx.IconLayer{
		Fill: white,
		Commands: []gfx.PathCommand{
			// Serif-barred I on the left half of the badge (x: 2.6..7.4, y: 4.0..12.0).
			gfx.MoveTo(2.6, 4.0),
			gfx.LineTo(7.4, 4.0),
			gfx.LineTo(7.4, 5.4),
			gfx.LineTo(5.8, 5.4),
			gfx.LineTo(5.8, 10.6),
			gfx.LineTo(7.4, 10.6),
			gfx.LineTo(7.4, 12.0),
			gfx.LineTo(2.6, 12.0),
			gfx.LineTo(2.6, 10.6),
			gfx.LineTo(4.2, 10.6),
			gfx.LineTo(4.2, 5.4),
			gfx.LineTo(2.6, 5.4),
			gfx.ClosePath(),
		},
	}
}

func gutterGlyphO() gfx.IconLayer {
	white := gfx.RGB24(0xFFFFFF)
	// Outer rounded O and inner cut-out using even-odd fill rule (x: 2.0..8.0, y: 4.0..12.0).
	return gfx.IconLayer{
		Fill:     white,
		FillRule: gfx.PathFillEvenOdd,
		Commands: []gfx.PathCommand{
			// Outer contour (clockwise).
			gfx.MoveTo(5.0, 4.0),
			gfx.CubicTo(6.65685, 4.0, 8.0, 5.34315, 8.0, 7.0),
			gfx.LineTo(8.0, 9.0),
			gfx.CubicTo(8.0, 10.6569, 6.65685, 12.0, 5.0, 12.0),
			gfx.CubicTo(3.34315, 12.0, 2.0, 10.6569, 2.0, 9.0),
			gfx.LineTo(2.0, 7.0),
			gfx.CubicTo(2.0, 5.34315, 3.34315, 4.0, 5.0, 4.0),
			gfx.ClosePath(),
			// Inner hole (counter-clockwise).
			gfx.MoveTo(5.0, 5.4),
			gfx.CubicTo(4.11634, 5.4, 3.4, 6.11634, 3.4, 7.0),
			gfx.LineTo(3.4, 9.0),
			gfx.CubicTo(3.4, 9.88366, 4.11634, 10.6, 5.0, 10.6),
			gfx.CubicTo(5.88366, 10.6, 6.6, 9.88366, 6.6, 9.0),
			gfx.LineTo(6.6, 7.0),
			gfx.CubicTo(6.6, 6.11634, 5.88366, 5.4, 5.0, 5.4),
			gfx.ClosePath(),
		},
	}
}

func gutterArrowDown() gfx.IconLayer {
	white := gfx.RGB24(0xFFFFFF)
	return gfx.IconLayer{
		Fill: white,
		Commands: []gfx.PathCommand{
			gfx.MoveTo(10.8, 4.0),
			gfx.LineTo(12.2, 4.0),
			gfx.LineTo(12.2, 9.1),
			gfx.LineTo(13.5, 7.8),
			gfx.LineTo(14.5, 8.8),
			gfx.LineTo(11.5, 12.0),
			gfx.LineTo(8.5, 8.8),
			gfx.LineTo(9.5, 7.8),
			gfx.LineTo(10.8, 9.1),
			gfx.ClosePath(),
		},
	}
}

func gutterArrowUp() gfx.IconLayer {
	white := gfx.RGB24(0xFFFFFF)
	return gfx.IconLayer{
		Fill: white,
		Commands: []gfx.PathCommand{
			gfx.MoveTo(10.8, 12.0),
			gfx.LineTo(12.2, 12.0),
			gfx.LineTo(12.2, 6.9),
			gfx.LineTo(13.5, 8.2),
			gfx.LineTo(14.5, 7.2),
			gfx.LineTo(11.5, 4.0),
			gfx.LineTo(8.5, 7.2),
			gfx.LineTo(9.5, 8.2),
			gfx.LineTo(10.8, 6.9),
			gfx.ClosePath(),
		},
	}
}

func gutterArrowCenteredDown() gfx.IconLayer {
	white := gfx.RGB24(0xFFFFFF)
	return gfx.IconLayer{
		Fill: white,
		Commands: []gfx.PathCommand{
			gfx.MoveTo(7.2, 3.5),
			gfx.LineTo(8.8, 3.5),
			gfx.LineTo(8.8, 9.2),
			gfx.LineTo(11.2, 6.9),
			gfx.LineTo(12.3, 8.0),
			gfx.LineTo(8.0, 12.5),
			gfx.LineTo(3.7, 8.0),
			gfx.LineTo(4.8, 6.9),
			gfx.LineTo(7.2, 9.2),
			gfx.ClosePath(),
		},
	}
}

func gutterArrowCenteredUp() gfx.IconLayer {
	white := gfx.RGB24(0xFFFFFF)
	return gfx.IconLayer{
		Fill: white,
		Commands: []gfx.PathCommand{
			gfx.MoveTo(7.2, 12.5),
			gfx.LineTo(8.8, 12.5),
			gfx.LineTo(8.8, 6.8),
			gfx.LineTo(11.2, 9.1),
			gfx.LineTo(12.3, 8.0),
			gfx.LineTo(8.0, 3.5),
			gfx.LineTo(3.7, 8.0),
			gfx.LineTo(4.8, 9.1),
			gfx.LineTo(7.2, 6.8),
			gfx.ClosePath(),
		},
	}
}
