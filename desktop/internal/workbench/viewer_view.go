package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// viewerView is a viewer tab's body: a bar with what the file is and what can be done
// with it, over the image, the hex lines or the offer to open it elsewhere.
func (a *App) viewerView(c ui.C, t *viewerTab) {
	language := a.language()
	ui.Column(c.Key("viewer-" + strconv.Itoa(t.id))).Fill().Background(a.colors.Panel).Children(func() {
		ui.Row(c).FillWidth().Height(32).Shrink(0).PadX(10).Gap(8).Items(ui.Center).Children(func() {
			info := agentFormatBytes(uint64(max(t.size, 0)))
			if t.bitmap.Width > 0 {
				info = strconv.Itoa(t.bitmap.Width) + " × " + strconv.Itoa(t.bitmap.Height) + " · " + info
			}
			ui.Text(c, info).FontSize(12).Color(a.colors.Subtle).Grow(1).MinWidth(0).Ellipsis()
			if t.kind == viewerImage && t.bitmap.Width > 0 {
				label := i18n.Shared(language, "desktop.viewer.actualSize")
				if t.actual {
					label = i18n.Shared(language, "desktop.viewer.fit")
				}
				if ui.Button(c.Part("zoom"), label).Ghost().Small().Clicked() {
					t.actual = !t.actual
				}
			}
			if ui.Button(c.Part("open"), i18n.Shared(language, "desktop.viewer.openExternally")).Icon(icons.FolderOpen).Ghost().Small().Clicked() {
				path := t.path
				c.After(func() {
					if err := app.OpenPath(path); err != nil {
						a.notifyError(i18n.SharedFormat(language, "desktop.viewer.openFailed", map[string]string{"reason": err.Error()}))
					}
				})
			}
		})
		ui.Row(c).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		switch {
		case t.loading:
			ui.Row(c).Fill().Center().Children(func() { ui.Spinner(c) })
		case t.failure != "":
			ui.Row(c).Fill().Center().Pad(20).Children(func() {
				ui.Paragraph(c, i18n.SharedFormat(language, "desktop.viewer.failed", map[string]string{"reason": t.failure}), 4).Color(a.theme.Danger)
			})
		case t.kind == viewerExternal:
			ui.Column(c).Fill().Center().Gap(10).Children(func() {
				ui.Text(c, t.name).FontSize(14).Color(a.colors.Text)
				ui.Text(c, i18n.Shared(language, "desktop.viewer.externalHint")).FontSize(12).Color(a.colors.Subtle)
			})
		case t.kind == viewerImage:
			a.viewerImage(c, t)
		default:
			a.viewerHex(c, t)
		}
	})
}

// viewerImage draws the image fitted to the tab, never enlarged past its own size, or at
// its own size in a scroll area.
func (a *App) viewerImage(c ui.C, t *viewerTab) {
	bitmap := t.bitmap
	if t.actual {
		ui.Scroll(c.Part("image")).Fill().Children(func() {
			ui.Row(c).Size(float32(bitmap.Width), float32(bitmap.Height)).Shrink(0).Draw(func(d *ui.DrawContext) {
				d.Canvas.DrawBitmap(bitmap, d.Rect)
			})
		})
		return
	}
	ui.Row(c.Part("image")).Fill().Pad(12).Draw(func(d *ui.DrawContext) {
		r := d.Rect
		scale := min(r.Width/float32(bitmap.Width), r.Height/float32(bitmap.Height), 1)
		w, h := float32(bitmap.Width)*scale, float32(bitmap.Height)*scale
		d.Canvas.DrawBitmap(bitmap, gfx.Rect{X: r.X + (r.Width-w)/2, Y: r.Y + (r.Height-h)/2, Width: w, Height: h})
	})
}

// viewerHex lists the hex lines, and says when the file goes on past them.
func (a *App) viewerHex(c ui.C, t *viewerTab) {
	language := a.language()
	ui.Scroll(c.Part("hex")).Fill().PadX(12).PadY(8).Children(func() {
		ui.Text(c, i18n.Shared(language, "desktop.viewer.binaryHint")).FontSize(12).Color(a.colors.Subtle)
		for i, line := range t.hex {
			ui.Text(c.KeyInt(i), line).Mono().FontSize(12).Color(a.colors.Text)
		}
		if t.truncated {
			ui.Text(c, i18n.Shared(language, "desktop.viewer.truncated")).FontSize(12).Color(a.colors.Subtle)
		}
	})
}
