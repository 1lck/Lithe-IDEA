package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// WorkbenchBackground is the workbench's background image as the Appearance card shows it.
// The workbench owns the image; the settings window only reads this snapshot and hands the
// user's choices back through Options.
type WorkbenchBackground struct {
	// Set is whether an image is chosen, decoded or not yet.
	Set bool
	// Name is the chosen file's name; Width and Height are the decoded image's size.
	Name          string
	Width, Height int
	// Loading is whether the chosen image is still being decoded.
	Loading bool
	// Strength is how much of the image shows: "subtle", "" for medium, or "strong".
	Strength string
	// Status says which image is in use, that it is loading, or that there is none; Failure is
	// why the last image could not be used, empty when it could. Both are in the window's
	// language.
	Status, Failure string
	// Image is the decoded image, empty while there is none. Its pixels are never changed
	// once decoded, so the window may draw them from its own thread.
	Image gfx.Bitmap
}

// workbenchBackgroundStrengths are the strengths the card offers, weakest first, as the
// values WorkbenchBackground.Strength and SetWorkbenchBackgroundStrength use.
var workbenchBackgroundStrengths = []string{"subtle", "", "strong"}

// workbenchBackgroundStrengthLabel names a strength in language.
func workbenchBackgroundStrengthLabel(language i18n.Language, strength string) string {
	switch strength {
	case "subtle":
		return i18n.Shared(language, "desktop.workbenchBackground.subtle")
	case "strong":
		return i18n.Shared(language, "desktop.workbenchBackground.strong")
	}
	return i18n.Shared(language, "desktop.workbenchBackground.medium")
}

// CoverRegion is the part of a width × height image that fills area without stretching: the
// middle of the image, cut on the sides or at the top and bottom. The workbench crops its
// background and the card its thumbnail with it, so both show the same part.
func CoverRegion(width, height int, area gfx.Rect) gfx.Rect {
	source := gfx.Rect{Width: float32(width), Height: float32(height)}
	if width <= 0 || height <= 0 || area.Width <= 0 || area.Height <= 0 {
		return source
	}
	areaAspect, imageAspect := area.Width/area.Height, float32(width)/float32(height)
	if imageAspect > areaAspect {
		source.Width = float32(height) * areaAspect
		source.X = (float32(width) - source.Width) / 2
	} else {
		source.Height = float32(width) / areaAspect
		source.Y = (float32(height) - source.Height) / 2
	}
	return source
}

const (
	// backgroundThumbWidth and backgroundThumbHeight are the card's thumbnail, in the
	// proportions of a wide window.
	backgroundThumbWidth  = 80
	backgroundThumbHeight = 50
)

// workbenchBackgroundRows are the Appearance card's background rows: the thumbnail, what is in
// use and the buttons that change it, then how much of the image shows. Without the workbench
// options the rows are left out.
func (w *window) workbenchBackgroundRows(c ui.C, narrow bool) {
	opts := &w.ctrl.opts
	if opts.WorkbenchBackground == nil {
		return
	}
	p := &w.pal
	language := w.marketLanguage()
	background := opts.WorkbenchBackground(language)
	title := i18n.Shared(language, "native.workbenchBackground")
	label := func() {
		ui.Text(c, title).FontSize(12).Color(p.text).Ellipsis().Shrink(1)
		w.infoButton(c.Part("background-help"), i18n.Shared(language, "desktop.workbenchBackground.help"))
	}
	body := func() {
		ui.Row(c).Size(backgroundThumbWidth, backgroundThumbHeight).Shrink(0).Radius(6).Clip().
			Background(p.hover).Stroke(0.5, p.line).Draw(func(d *ui.DrawContext) {
			image := background.Image
			if image.Width <= 0 {
				return
			}
			d.Canvas.DrawBitmapRegion(image, CoverRegion(image.Width, image.Height, d.Rect), d.Rect)
		})
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(6).Children(func() {
			ui.Text(c, background.Status).FontSize(12).Color(p.muted).MaxLines(0)
			if background.Failure != "" {
				ui.Text(c, background.Failure).FontSize(12).Color(p.warning).MaxLines(0)
			}
			ui.Row(c).Gap(8).Items(ui.Center).Children(func() {
				if ui.Button(c.Part("background-choose"), i18n.Shared(language, "native.chooseImage")).Outline().Clicked() && opts.ChooseWorkbenchBackground != nil {
					opts.ChooseWorkbenchBackground()
				}
				if background.Set && ui.Button(c.Part("background-remove"), i18n.Shared(language, "desktop.workbenchBackground.remove")).Outline().Clicked() && opts.RemoveWorkbenchBackground != nil {
					opts.RemoveWorkbenchBackground()
				}
			})
		})
	}
	visibility := i18n.Shared(language, "desktop.workbenchBackground.visibility")
	// The control writes into the window's own copy, like the theme choice; a change is handed
	// to the workbench, whose answer the next snapshot shows. Without an image there is nothing
	// to show more or less of, so the row is left out.
	w.backgroundStrengthPick = background.Strength
	strength := func() {
		ui.Choice(c.Part("background-strength"), &w.backgroundStrengthPick, workbenchBackgroundStrengths, func(value string) string {
			return workbenchBackgroundStrengthLabel(language, value)
		}).Width(420).Shrink(1).MinWidth(0).Label(visibility)
	}
	if narrow {
		ui.Column(c).FillWidth().Gap(8).PadY(6).Children(func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(label)
			ui.Row(c).FillWidth().Items(ui.Start).Gap(12).Children(body)
			if background.Set {
				ui.Text(c, visibility).FontSize(12).Color(p.text)
				strength()
			}
		})
	} else {
		ui.Row(c).FillWidth().Items(ui.Start).Gap(12).PadY(6).Children(func() {
			ui.Row(c).WidthPercent(34).Shrink(1).MinWidth(0).Height(28).Items(ui.Center).Gap(6).Children(label)
			ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Items(ui.Start).Gap(12).Children(body)
		})
		if background.Set {
			ui.Row(c).FillWidth().Height(28).Gap(12).Items(ui.Center).Children(func() {
				ui.Row(c).WidthPercent(34).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
					ui.Text(c, visibility).FontSize(12).Color(p.text).Ellipsis()
				})
				strength()
			})
		}
	}
	if pick := w.backgroundStrengthPick; background.Set && pick != background.Strength && opts.SetWorkbenchBackgroundStrength != nil {
		opts.SetWorkbenchBackgroundStrength(pick)
	}
}
