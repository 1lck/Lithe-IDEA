package icons

import "github.com/vivaui/viva/ui"

// These paths reproduce the 16-point IntelliJ Community New UI VCS icons used
// by the previous welcome page. Source: platform/icons/src/expui/general/vcs.svg
// and vcs_dark.svg, Community revision c7f91397daa3a961b4e78bc634fe467a0a7d9ade;
// copyright JetBrains s.r.o. and contributors, Apache-2.0. The license is kept
// in ../fileicons/LICENSE-APACHE-2.0.txt. The SVG circles use cubic approximations.
var (
	ideaVCSLight = makeIDEAVCS(11.5, 10.6046, 9.5, 8)
	ideaVCSDark  = makeIDEAVCS(11, 10.1046, 9, 7.5)
)

func makeIDEAVCS(horizontalY, controlY, curveEndY, endY float32) ui.Icon {
	return ui.Icon{
		ViewBox: 16,
		Stroke:  1,
		Cap:     ui.CapRound,
		Join:    ui.JoinRound,
		Commands: []ui.PathCommand{
			ui.MoveTo(6.5, 4),
			ui.CubicTo(6.5, 5.10457, 5.60457, 6, 4.5, 6),
			ui.CubicTo(3.39543, 6, 2.5, 5.10457, 2.5, 4),
			ui.CubicTo(2.5, 2.89543, 3.39543, 2, 4.5, 2),
			ui.CubicTo(5.60457, 2, 6.5, 2.89543, 6.5, 4),
			ui.ClosePath(),
			ui.MoveTo(4.5, horizontalY),
			ui.LineTo(8.5, horizontalY),
			ui.CubicTo(9.60457, horizontalY, 10.5, controlY, 10.5, curveEndY),
			ui.LineTo(10.5, endY),
			ui.MoveTo(4.5, 6.5),
			ui.LineTo(4.5, 14.5),
			ui.MoveTo(12.5, 6),
			ui.CubicTo(12.5, 7.10457, 11.60457, 8, 10.5, 8),
			ui.CubicTo(9.39543, 8, 8.5, 7.10457, 8.5, 6),
			ui.CubicTo(8.5, 4.89543, 9.39543, 4, 10.5, 4),
			ui.CubicTo(11.60457, 4, 12.5, 4.89543, 12.5, 6),
			ui.ClosePath(),
		},
	}
}

// RecentProjectVCS returns the theme-specific original VCS glyph, tinted by its caller.
func RecentProjectVCS(dark bool) ui.Icon {
	if dark {
		return ideaVCSDark
	}
	return ideaVCSLight
}
