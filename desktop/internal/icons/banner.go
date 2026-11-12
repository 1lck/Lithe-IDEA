package icons

import "github.com/vivaui/viva/gfx"

// BannerWarning is the original 16-point JetBrains warning glyph from
// expui/status/warning.svg, copyright 2000–2023 JetBrains s.r.o. and contributors,
// used under the Apache 2.0 license. Its two fills retain the native colors.
var BannerWarning = gfx.Icon{
	ViewBox: 16,
	Layers: []gfx.IconLayer{
		{Fill: gfx.RGB24(0xFFAF0F), Commands: []gfx.PathCommand{
			gfx.MoveTo(1.27603, 10.8634), gfx.LineTo(6.3028, 1.98903),
			gfx.CubicTo(7.04977, 0.670323, 8.94893, 0.670326, 9.69589, 1.98903),
			gfx.LineTo(14.7227, 10.8634),
			gfx.CubicTo(15.516, 12.2639, 14.5047, 14, 12.8956, 14),
			gfx.LineTo(3.10308, 14),
			gfx.CubicTo(1.494, 14, 0.482737, 12.2639, 1.27603, 10.8634), gfx.ClosePath(),
		}},
		{Fill: gfx.RGB24(0xFFFFFF), Commands: []gfx.PathCommand{
			gfx.MoveTo(9, 5), gfx.CubicTo(9, 4.44772, 8.55228, 4, 8, 4),
			gfx.CubicTo(7.44772, 4, 7, 4.44772, 7, 5), gfx.LineTo(7, 7.5),
			gfx.CubicTo(7, 8.05228, 7.44772, 8.5, 8, 8.5),
			gfx.CubicTo(8.55229, 8.5, 9, 8.05228, 9, 7.5), gfx.LineTo(9, 5), gfx.ClosePath(),
		}},
		{Fill: gfx.RGB24(0xFFFFFF), Commands: []gfx.PathCommand{
			gfx.MoveTo(8, 12), gfx.CubicTo(8.55228, 12, 9, 11.5523, 9, 11),
			gfx.CubicTo(9, 10.4477, 8.55228, 10, 8, 10),
			gfx.CubicTo(7.44772, 10, 7, 10.4477, 7, 11),
			gfx.CubicTo(7, 11.5523, 7.44772, 12, 8, 12), gfx.ClosePath(),
		}},
	},
}
