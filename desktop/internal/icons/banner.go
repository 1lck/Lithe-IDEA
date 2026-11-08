package icons

import "github.com/vivaui/viva/ui"

// BannerWarning is the original 16-point JetBrains warning glyph from
// expui/status/warning.svg, copyright 2000–2023 JetBrains s.r.o. and contributors,
// used under the Apache 2.0 license. Its two fills retain the native colors.
var BannerWarning = ui.Icon{
	ViewBox: 16,
	Layers: []ui.IconLayer{
		{Fill: ui.RGB24(0xFFAF0F), Commands: []ui.PathCommand{
			ui.MoveTo(1.27603, 10.8634), ui.LineTo(6.3028, 1.98903),
			ui.CubicTo(7.04977, 0.670323, 8.94893, 0.670326, 9.69589, 1.98903),
			ui.LineTo(14.7227, 10.8634),
			ui.CubicTo(15.516, 12.2639, 14.5047, 14, 12.8956, 14),
			ui.LineTo(3.10308, 14),
			ui.CubicTo(1.494, 14, 0.482737, 12.2639, 1.27603, 10.8634), ui.ClosePath(),
		}},
		{Fill: ui.RGB24(0xFFFFFF), Commands: []ui.PathCommand{
			ui.MoveTo(9, 5), ui.CubicTo(9, 4.44772, 8.55228, 4, 8, 4),
			ui.CubicTo(7.44772, 4, 7, 4.44772, 7, 5), ui.LineTo(7, 7.5),
			ui.CubicTo(7, 8.05228, 7.44772, 8.5, 8, 8.5),
			ui.CubicTo(8.55229, 8.5, 9, 8.05228, 9, 7.5), ui.LineTo(9, 5), ui.ClosePath(),
		}},
		{Fill: ui.RGB24(0xFFFFFF), Commands: []ui.PathCommand{
			ui.MoveTo(8, 12), ui.CubicTo(8.55228, 12, 9, 11.5523, 9, 11),
			ui.CubicTo(9, 10.4477, 8.55228, 10, 8, 10),
			ui.CubicTo(7.44772, 10, 7, 10.4477, 7, 11),
			ui.CubicTo(7, 11.5523, 7.44772, 12, 8, 12), ui.ClosePath(),
		}},
	},
}
