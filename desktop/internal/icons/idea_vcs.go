package icons

import "github.com/vivaui/viva/gfx"

// These paths reproduce the 16-point IntelliJ Community New UI VCS icons used
// by the previous welcome page. Source: platform/icons/src/expui/general/vcs.svg
// and vcs_dark.svg, Community revision c7f91397daa3a961b4e78bc634fe467a0a7d9ade;
// copyright JetBrains s.r.o. and contributors, Apache-2.0. The license is kept
// in ../fileicons/LICENSE-APACHE-2.0.txt. The SVG circles use cubic approximations.
var (
	ideaVCSLight = makeIDEAVCS(11.5, 10.6046, 9.5, 8)
	ideaVCSDark  = makeIDEAVCS(11, 10.1046, 9, 7.5)
)

func makeIDEAVCS(horizontalY, controlY, curveEndY, endY float32) gfx.Icon {
	return gfx.Icon{
		ViewBox: 16,
		Stroke:  1,
		Cap:     gfx.CapRound,
		Join:    gfx.JoinRound,
		Commands: []gfx.PathCommand{
			gfx.MoveTo(6.5, 4),
			gfx.CubicTo(6.5, 5.10457, 5.60457, 6, 4.5, 6),
			gfx.CubicTo(3.39543, 6, 2.5, 5.10457, 2.5, 4),
			gfx.CubicTo(2.5, 2.89543, 3.39543, 2, 4.5, 2),
			gfx.CubicTo(5.60457, 2, 6.5, 2.89543, 6.5, 4),
			gfx.ClosePath(),
			gfx.MoveTo(4.5, horizontalY),
			gfx.LineTo(8.5, horizontalY),
			gfx.CubicTo(9.60457, horizontalY, 10.5, controlY, 10.5, curveEndY),
			gfx.LineTo(10.5, endY),
			gfx.MoveTo(4.5, 6.5),
			gfx.LineTo(4.5, 14.5),
			gfx.MoveTo(12.5, 6),
			gfx.CubicTo(12.5, 7.10457, 11.60457, 8, 10.5, 8),
			gfx.CubicTo(9.39543, 8, 8.5, 7.10457, 8.5, 6),
			gfx.CubicTo(8.5, 4.89543, 9.39543, 4, 10.5, 4),
			gfx.CubicTo(11.60457, 4, 12.5, 4.89543, 12.5, 6),
			gfx.ClosePath(),
		},
	}
}

// RecentProjectVCS returns the theme-specific original VCS glyph, tinted by its caller.
func RecentProjectVCS(dark bool) gfx.Icon {
	if dark {
		return ideaVCSDark
	}
	return ideaVCSLight
}
