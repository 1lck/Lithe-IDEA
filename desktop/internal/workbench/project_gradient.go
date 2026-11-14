package workbench

import (
	"runtime"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// The project color gradient follows IntelliJ Islands (IslandsGradientPainter): the
// window's chrome color ramps to the project's color at the project widget, back to the
// chrome color over 600 points, and fades out over 300 points downwards. Only the chrome
// receives it: the title bar, the button stripes and the gaps between the panels; the
// panels themselves stay solid. The color is the project's identity color, so the badge
// and the gradient always match.

const (
	projectGradientWidth  = 600
	projectGradientHeight = 300
	// projectGradientAnchor is where the color peaks when there is no project widget to
	// measure, after the system's window buttons; IntelliJ falls back to 150.
	projectGradientAnchor = 150
	// projectGradientStrength is how much of the project color the peak takes.
	projectGradientStrength = 0.85
	// projectGradientBands are the horizontal bands the downward fade is drawn in.
	projectGradientBands = 15
)

// projectGradientLight and projectGradientDark are the nine
// RecentProject.ColorN.MainToolbarGradientStart colors of ManyIslandsLight and
// ManyIslandsDark, in the order of identityGradients.
var (
	projectGradientLight = [...]uint32{0xf7d7cb, 0xf5e6b8, 0xe2f2c9, 0xcbe4f7, 0xd4d2fc, 0xecd3f5, 0xe4d3f5, 0xcef0e9, 0xceedd4}
	projectGradientDark  = [...]uint32{0x664832, 0x5e4724, 0x45522f, 0x335661, 0x394773, 0x613861, 0x503d70, 0x325959, 0x365439}
)

// projectGradientOn reports whether the window paints the open project's color.
func (a *App) projectGradientOn() bool {
	return a.project != nil && !a.settings.HideProjectColors
}

// chromeFill is the background of the chrome's own surfaces: none while the gradient or a
// workbench background image shows, so what is painted under them shows through; the chrome
// color otherwise.
func (a *App) chromeFill() gfx.Color {
	if a.projectGradientOn() || a.backdropShown() {
		return gfx.Color{}
	}
	return a.colors.Chrome
}

// paintProjectGradient paints the gradient over the chrome color at the top of bounds.
func (a *App) paintProjectGradient(canvas *gfx.Canvas, bounds gfx.Rect) {
	if !a.projectGradientOn() {
		return
	}
	index := identityColorIndex(a.project.root)
	rgb := projectGradientLight[index]
	if a.colors.Dark {
		rgb = projectGradientDark[index]
	}
	peak := gfx.RGB24(rgb)
	leading, _ := app.TitlebarInsets()
	if a.fullscreen && runtime.GOOS == "darwin" {
		leading = 0
	}
	anchor := leading + projectGradientAnchor
	width := min(anchor+projectGradientWidth, bounds.Width)
	if width <= 0 {
		return
	}
	at := anchor / width
	band := float32(projectGradientHeight) / projectGradientBands
	for i := range projectGradientBands {
		top := float32(i) * band
		if top >= bounds.Height {
			break
		}
		// Each band takes the fade at its middle.
		alpha := projectGradientStrength * (1 - (float32(i)+0.5)/projectGradientBands)
		color := peak.WithAlpha(alpha)
		clear := peak.WithAlpha(0)
		canvas.FillGradient(gfx.Rect{X: bounds.X, Y: bounds.Y + top, Width: width, Height: min(band, bounds.Height-top)}, 0, 90,
			[]gfx.GradientStop{gfx.Stop(0, clear), gfx.Stop(at, color), gfx.Stop(1, clear)})
	}
}
