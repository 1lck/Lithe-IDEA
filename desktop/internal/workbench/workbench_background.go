package workbench

// The workbench background is an image of the user's own painted behind the whole window of an
// open project. There is no built-in image: until the user chooses one the workbench paints its
// usual colors.
//
// The chosen file is copied into the client's data folder (store.WriteFile), so moving or
// deleting the original leaves the background as it was, and the installed client is never
// written to. The settings keep only the copied file's original name and the strength; the copy
// is decoded off the window thread and scaled down to backgroundMaxEdge once, so a large photo
// costs one bitmap of at most 2560 pixels a side.
//
// While an image shows, the window's ground is painted over it with the strength's opacity (the
// veil), and the surfaces that would hide it (the page fill, the chrome, the editor and the
// terminal) leave their fill clear; popups, menus and dialogs stay opaque. The state is shared by
// every project tab of the window, as the settings window and the stripe popover set the same one.

import (
	"bytes"
	"context"
	"errors"
	"image"
	_ "image/jpeg" // the decoders the picker's filter lets through
	_ "image/png"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

const (
	// backgroundFile is the copy of the chosen image in the client's data folder.
	backgroundFile = "workbench-background.img"
	// backgroundMaxBytes is the largest file accepted, checked before it is read.
	backgroundMaxBytes = 30 << 20
	// backgroundMaxPixels is the most pixels an image may have, checked from its header
	// before it is decoded, so a small file that claims a huge image is never expanded.
	backgroundMaxPixels = 64 << 20
	// backgroundMaxEdge is the longest side of the bitmap kept: no window is wider.
	backgroundMaxEdge = 2560
)

var (
	errBackgroundBytes  = errors.New("background: file too large")
	errBackgroundPixels = errors.New("background: too many pixels")
)

// backgroundImages numbers the decoded bitmaps, so the renderer uploads each one once and
// never confuses a new image with the texture of the last.
var backgroundImages atomic.Uint64

// backgroundStrength is how much of the image shows through the veil. The zero value is the
// default, so a saved state without a strength is the medium one.
type backgroundStrength int

const (
	bgMedium backgroundStrength = iota
	bgSubtle
	bgStrong
)

// backgroundStrengths is the order the choices are offered in.
var backgroundStrengths = []backgroundStrength{bgSubtle, bgMedium, bgStrong}

// opacity is the veil's alpha: the more of the ground over the image, the less of it shows.
func (s backgroundStrength) opacity() float32 {
	switch s {
	case bgSubtle:
		return 0.92
	case bgStrong:
		return 0.62
	}
	return 0.80
}

// saved is the strength's name in the settings file; the default is left out.
func (s backgroundStrength) saved() string {
	switch s {
	case bgSubtle:
		return "subtle"
	case bgStrong:
		return "strong"
	}
	return ""
}

// backgroundStrengthFromString reads a saved strength; anything else is the default.
func backgroundStrengthFromString(value string) backgroundStrength {
	switch value {
	case "subtle":
		return bgSubtle
	case "strong":
		return bgStrong
	}
	return bgMedium
}

// label is the strength's name in the interface.
func (s backgroundStrength) label(language i18n.Language) string {
	switch s {
	case bgSubtle:
		return i18n.Shared(language, "desktop.workbenchBackground.subtle")
	case bgStrong:
		return i18n.Shared(language, "desktop.workbenchBackground.strong")
	}
	return i18n.Shared(language, "desktop.workbenchBackground.medium")
}

// savedBackground is the background in the settings file: the name the chosen file had and
// the strength. The image itself is backgroundFile.
type savedBackground struct {
	Name     string `json:"name,omitempty"`
	Strength string `json:"strength,omitempty"`
}

// workbenchBackground is the window's background image, shared by its project tabs. The mutex
// guards it against the settings window, which reads it from its own thread; the window thread
// is the only writer.
type workbenchBackground struct {
	mu sync.Mutex
	// set is whether an image is chosen; pix stays nil until its copy is decoded.
	set      bool
	name     string
	strength backgroundStrength
	pix      []byte
	width    int
	height   int
	id       uint64
	// failure is why the last image chosen or restored cannot be shown, until the next choice.
	failure error
	// serial numbers the choices, so a decode that finishes after the image was replaced or
	// removed is dropped.
	serial uint64
}

// backdropShown reports whether this paint shows the image: only behind an open project's
// workbench, and once its copy is decoded.
func (a *App) backdropShown() bool {
	if a.backdrop == nil || a.project == nil {
		return false
	}
	b := a.backdrop
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.set && b.pix != nil
}

// backdropOpacity is the veil's alpha for the chosen strength.
func (a *App) backdropOpacity() float32 {
	b := a.backdrop
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.strength.opacity()
}

// restoreBackground shows the image the settings name, from the copy kept in the data folder.
// A copy that is missing leaves no image; one that cannot be decoded is removed and the
// background switched off, with the reason told once.
func (a *App) restoreBackground() {
	saved := a.settings.WorkbenchBackground
	b := a.backdrop
	b.mu.Lock()
	b.serial++
	serial := b.serial
	b.set, b.name, b.strength, b.pix, b.width, b.height, b.failure = false, "", bgMedium, nil, 0, 0, nil
	b.mu.Unlock()
	if saved.Name == "" || a.store == nil {
		return
	}
	if _, err := os.Stat(a.store.Path(backgroundFile)); err != nil {
		return
	}
	b.mu.Lock()
	b.set, b.name, b.strength = true, saved.Name, backgroundStrengthFromString(saved.Strength)
	b.mu.Unlock()
	a.decodeBackground(serial)
}

// decodeBackground decodes the copy in the data folder off the window thread and shows it, unless
// another choice came first.
func (a *App) decodeBackground(serial uint64) {
	path := a.store.Path(backgroundFile)
	a.background(nil, 0, func(context.Context) func(*App) {
		pix, width, height, err := loadBackgroundImage(path)
		return func(a *App) {
			b := a.backdrop
			b.mu.Lock()
			if b.serial != serial {
				b.mu.Unlock()
				return
			}
			if err != nil {
				b.set, b.pix, b.failure = false, nil, err
				b.mu.Unlock()
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workbench_background", documentLogError(err)))
				if removeErr := a.store.Remove(backgroundFile); removeErr != nil {
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workbench_background_remove", documentLogError(removeErr)))
				}
				a.saveSettings()
				a.notifyError(backgroundFailureText(a.language(), err))
				a.invalidateBackdrop()
				return
			}
			b.pix, b.width, b.height = pix, width, height
			b.id = 1<<62 | backgroundImages.Add(1)
			b.mu.Unlock()
			a.invalidateBackdrop()
		}
	})
}

// backgroundFailureText says, in language, why an image cannot be used.
func backgroundFailureText(language i18n.Language, err error) string {
	reason := err.Error()
	switch {
	case errors.Is(err, errBackgroundBytes):
		reason = i18n.Shared(language, "desktop.workbenchBackground.tooLarge")
	case errors.Is(err, errBackgroundPixels):
		reason = i18n.Shared(language, "desktop.workbenchBackground.tooManyPixels")
	case errors.Is(err, image.ErrFormat):
		reason = i18n.Shared(language, "desktop.workbenchBackground.unsupported")
	}
	return i18n.SharedFormat(language, "desktop.workbenchBackground.failed", map[string]string{"reason": reason})
}

// chooseBackground asks for an image and makes it the background. The picker and the checks
// run off the window thread; a file that cannot be used is told and leaves the background as
// it was.
func (a *App) chooseBackground() {
	a.performed("workspace.background.choose", surfaceButton)
	language := a.language()
	options := app.OpenFileOptions{
		Title: i18n.Shared(language, "native.chooseWorkbenchBackground"),
		Filters: []app.FileFilter{{
			Name:    i18n.Shared(language, "desktop.workbenchBackground.imageFilter"),
			Pattern: "*.png;*.jpg;*.jpeg",
		}},
	}
	choose := a.chooseBackgroundImage
	if choose == nil {
		choose = app.OpenFiles
	}
	a.background(nil, 0, func(context.Context) func(*App) {
		paths, err := choose(options)
		if errors.Is(err, app.ErrCanceled) || err == nil && len(paths) == 0 {
			// log-exempt: 用户取消了选择，背景保持不变。
			return nil
		}
		if err != nil {
			return func(a *App) { a.backgroundChoiceFailed(err) }
		}
		path := paths[0]
		data, err := readBackgroundFile(path)
		if err != nil {
			return func(a *App) { a.backgroundChoiceFailed(err) }
		}
		return func(a *App) { a.useBackground(filepath.Base(path), data) }
	})
}

// readBackgroundFile reads the file at path if it can be a background: not too large, a PNG or
// JPEG by its header, and not too many pixels. It is checked whole before anything is replaced.
func readBackgroundFile(path string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.Size() > backgroundMaxBytes {
		return nil, errBackgroundBytes
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if err := checkBackgroundHeader(data); err != nil {
		return nil, err
	}
	return data, nil
}

// checkBackgroundHeader reads the image's size from its header and refuses one that is empty
// or has more than backgroundMaxPixels.
func checkBackgroundHeader(data []byte) error {
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return err
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width*config.Height > backgroundMaxPixels {
		return errBackgroundPixels
	}
	return nil
}

// backgroundChoiceFailed tells why the chosen file cannot be used; the background is left as
// it was.
func (a *App) backgroundChoiceFailed(err error) {
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workbench_background", documentLogError(err)))
	a.notifyError(backgroundFailureText(a.language(), err))
}

// useBackground keeps data, the checked bytes of the file named name, as the background: its
// copy replaces the last one, and it shows once decoded. The strength is kept.
func (a *App) useBackground(name string, data []byte) {
	if err := a.store.WriteFile(backgroundFile, data); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workbench_background_save", documentLogError(err)))
		a.notifyError(a.text.Errors.SaveFailed(err.Error()))
		return
	}
	b := a.backdrop
	b.mu.Lock()
	b.serial++
	serial := b.serial
	b.set, b.name, b.pix, b.width, b.height, b.failure = true, name, nil, 0, 0, nil
	b.mu.Unlock()
	a.decodeBackground(serial)
	a.saveSettings()
	a.invalidateBackdrop()
}

// removeBackground takes the image away and deletes its copy. The strength stays for the next.
func (a *App) removeBackground() {
	a.performed("workspace.background.remove", surfaceButton)
	b := a.backdrop
	b.mu.Lock()
	b.serial++
	b.set, b.name, b.pix, b.width, b.height, b.failure = false, "", nil, 0, 0, nil
	b.mu.Unlock()
	if err := a.store.Remove(backgroundFile); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workbench_background_remove", documentLogError(err)))
	}
	a.saveSettings()
	a.invalidateBackdrop()
}

// setBackgroundStrength changes how much of the chosen image shows.
func (a *App) setBackgroundStrength(strength backgroundStrength) {
	b := a.backdrop
	b.mu.Lock()
	changed := b.set && b.strength != strength
	if changed {
		b.strength = strength
	}
	b.mu.Unlock()
	if !changed {
		return
	}
	a.performed("workspace.background.strength", surfaceButton)
	a.saveSettings()
	a.invalidateBackdrop()
}

// savedBackgroundState is the background as the settings file keeps it: nothing without an image.
func (a *App) savedBackgroundState() savedBackground {
	if a.backdrop == nil {
		return a.settings.WorkbenchBackground
	}
	b := a.backdrop
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.set {
		return savedBackground{}
	}
	return savedBackground{Name: b.name, Strength: b.strength.saved()}
}

// invalidateBackdrop repaints every workbench of the window and the settings window, which all
// show the same background.
func (a *App) invalidateBackdrop() {
	a.invalidator.Invalidate()
	for _, session := range a.sessions.everyOne() {
		session.invalidator.Invalidate()
		if session.settingsWindow != nil {
			session.settingsWindow.Invalidate()
		}
	}
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
}

// paintBackdrop draws the image under everything the window paints, cropped to cover it: the
// image keeps its proportions and its middle stays in view.
func (a *App) paintBackdrop(canvas *gfx.Canvas, size gfx.Size) {
	b := a.backdrop
	b.mu.Lock()
	pix, width, height, id := b.pix, b.width, b.height, b.id
	b.mu.Unlock()
	if pix == nil || size.Width <= 0 || size.Height <= 0 {
		return
	}
	area := gfx.Rect{Width: size.Width, Height: size.Height}
	canvas.DrawBackdrop(gfx.Bitmap{Pix: pix, Width: width, Height: height, Stride: width * 4, ID: id}, settingswindow.CoverRegion(width, height, area), area)
}

// loadBackgroundImage decodes the image file at path into premultiplied BGRA, scaled down so
// its longer side is at most backgroundMaxEdge. The limits are checked before the pixels are.
func loadBackgroundImage(path string) (pix []byte, width, height int, err error) {
	data, err := readBackgroundFile(path)
	if err != nil {
		return nil, 0, 0, err
	}
	source, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, err
	}
	return scaleToBGRA(source, backgroundMaxEdge)
}

// scaleToBGRA turns source into premultiplied BGRA pixels, averaging boxes of source pixels so
// that its longer side is at most edge. An image already that small keeps its size.
func scaleToBGRA(source image.Image, edge int) (pix []byte, width, height int, err error) {
	bounds := source.Bounds()
	sw, sh := bounds.Dx(), bounds.Dy()
	if sw <= 0 || sh <= 0 {
		return nil, 0, 0, image.ErrFormat
	}
	width, height = sw, sh
	if long := max(sw, sh); long > edge {
		width, height = max(sw*edge/long, 1), max(sh*edge/long, 1)
	}
	pix = make([]byte, width*height*4)
	for y := 0; y < height; y++ {
		y0, y1 := y*sh/height, max((y+1)*sh/height, y*sh/height+1)
		for x := 0; x < width; x++ {
			x0, x1 := x*sw/width, max((x+1)*sw/width, x*sw/width+1)
			var r, g, b, a, count uint64
			for sy := y0; sy < y1; sy++ {
				for sx := x0; sx < x1; sx++ {
					// RGBA is premultiplied, which the backdrop takes.
					pr, pg, pb, pa := source.At(bounds.Min.X+sx, bounds.Min.Y+sy).RGBA()
					r, g, b, a, count = r+uint64(pr), g+uint64(pg), b+uint64(pb), a+uint64(pa), count+1
				}
			}
			offset := (y*width + x) * 4
			pix[offset], pix[offset+1], pix[offset+2], pix[offset+3] = byte(b/count>>8), byte(g/count>>8), byte(r/count>>8), byte(a/count>>8)
		}
	}
	return pix, width, height, nil
}

// backgroundSnapshot is the background as the settings window shows it, in language. It is
// read from the settings window's thread.
func (a *App) backgroundSnapshot(language i18n.Language) settingswindow.WorkbenchBackground {
	b := a.backdrop
	b.mu.Lock()
	defer b.mu.Unlock()
	snapshot := settingswindow.WorkbenchBackground{
		Set:      b.set,
		Name:     b.name,
		Width:    b.width,
		Height:   b.height,
		Loading:  b.set && b.pix == nil,
		Strength: b.strength.saved(),
		Status:   backgroundStatusText(language, b.set, b.name, b.pix != nil, b.width, b.height),
	}
	if b.failure != nil {
		snapshot.Failure = backgroundFailureText(language, b.failure)
	}
	if b.pix != nil {
		snapshot.Image = gfx.Bitmap{Pix: b.pix, Width: b.width, Height: b.height, Stride: b.width * 4, ID: b.id}
	}
	return snapshot
}

// backgroundStatusText says which image is in use, that it is being loaded, or that there is none.
func backgroundStatusText(language i18n.Language, set bool, name string, decoded bool, width, height int) string {
	switch {
	case set && decoded:
		return i18n.SharedFormat(language, "desktop.workbenchBackground.status", map[string]string{
			"name": name, "width": strconv.Itoa(width), "height": strconv.Itoa(height),
		})
	case set:
		return i18n.Shared(language, "desktop.workbenchBackground.loading")
	}
	return i18n.Shared(language, "native.noBackgroundImageSelected")
}

// backgroundPopover is the panel the stripe's background button opens: choose or remove the
// image and set how much of it shows. The same setting is in the settings window's Appearance.
func (a *App) backgroundPopover(c ui.C, anchor ui.Box) {
	language := a.language()
	b := a.backdrop
	b.mu.Lock()
	set, strength, failure := b.set, b.strength, b.failure
	status := backgroundStatusText(language, b.set, b.name, b.pix != nil, b.width, b.height)
	b.mu.Unlock()
	var chosen, removed, closed bool
	picked := strength
	spec := ui.PopoverSpec{Side: components.PopoverLeft, Align: ui.End, Width: 320, ConsumeOutsidePress: true}
	open := true
	ui.PopoverWith(c.Key("workbenchBackground"), anchor, spec, &open, func() {
		ui.Column(c).Gap(8).FillWidth().Children(func() {
			ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
				ui.Icon(c, icons.Image).Size(14, 14).Color(a.colors.Subtle)
				ui.Text(c, i18n.Shared(language, "native.workbenchBackground")).FontSize(13).Weight(gfx.WeightSemibold).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
				label := i18n.Shared(language, "desktop.workbenchBackground.close")
				closed = ui.Button(c.Part("close"), label).Icon(icons.X).IconOnly().Ghost().Size(18, 18).Tooltip(label).Clicked()
			})
			ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
				chosen = ui.Button(c.Part("choose"), i18n.Shared(language, "native.chooseImage")).Secondary().Small().Clicked()
				if set {
					removed = ui.Button(c.Part("remove"), i18n.Shared(language, "desktop.workbenchBackground.remove")).Outline().Small().Clicked()
				}
			})
			ui.Text(c, status).FontSize(12).Color(a.colors.Subtle).MaxLines(0)
			if failure != nil {
				ui.Text(c, backgroundFailureText(language, failure)).FontSize(12).Color(a.colors.Warning).MaxLines(0)
			}
			// Without an image there is nothing to show more or less of, so the strength is left out.
			if set {
				ui.Text(c, i18n.Shared(language, "desktop.workbenchBackground.visibility")).FontSize(12).Color(a.colors.Subtle)
				ui.Choice(c.Part("strength"), &picked, backgroundStrengths, func(s backgroundStrength) string { return s.label(language) })
			}
		})
	})
	if !open || closed {
		a.backdropOpen = false
	}
	switch {
	case chosen:
		c.After(a.chooseBackground)
	case removed:
		c.After(a.removeBackground)
	case picked != strength:
		c.After(func() { a.setBackgroundStrength(picked) })
	}
}
