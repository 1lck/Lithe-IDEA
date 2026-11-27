package workbench

import (
	"math"
	"net/url"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/markdown"
	"github.com/vivaui/viva/ui"
)

// The update arrow and the update dialog, as Motty shows them (github.com/t8y2/motty, Apache
// License 2.0, whose arrow icon and green are drawn here as they are there).
//
// A version a check found puts a small green arrow at the trailing end of the title bar, and
// on the welcome screen at its top right; nothing is downloaded yet. The arrow opens the
// dialog, which shows what the version changed first, its release notes in Markdown, with the
// running version and the size of the download, and offers Skip This Version, Later and
// Download and Install. While the update downloads the arrow draws its progress around the
// ring, and the dialog the step under way with Cancel; once it is downloaded the arrow turns
// solid and the dialog offers Restart and Update. An installation that cannot replace itself
// offers the downloads page instead. Later, Escape and the close button only close the dialog:
// the arrow stays, and a download under way goes on.

// updateGreen is the deep green of the update arrow, the same on both themes, as Motty's.
var updateGreen = gfx.RGB(22, 163, 74)

// updateIcon is a ring with a solid down arrow inside it and the space between left empty. The
// ring is the icon's stroke, painted in the tint; the arrow is a filled layer, which carries
// its own color, so both are updateGreen.
var updateIcon = gfx.Icon{
	ViewBox: 24,
	Stroke:  2,
	Cap:     gfx.CapRound,
	Join:    gfx.JoinRound,
	Commands: []gfx.PathCommand{
		gfx.MoveTo(22, 12),
		gfx.CubicTo(22, 17.523, 17.523, 22, 12, 22),
		gfx.CubicTo(6.477, 22, 2, 17.523, 2, 12),
		gfx.CubicTo(2, 6.477, 6.477, 2, 12, 2),
		gfx.CubicTo(17.523, 2, 22, 6.477, 22, 12),
		gfx.ClosePath(),
	},
	Layers: []gfx.IconLayer{{
		Fill: updateGreen,
		Commands: []gfx.PathCommand{
			gfx.MoveTo(10.4, 6.5), gfx.LineTo(13.6, 6.5), gfx.LineTo(13.6, 11.5), gfx.LineTo(16.5, 11.5),
			gfx.LineTo(12, 16.5), gfx.LineTo(7.5, 11.5), gfx.LineTo(10.4, 11.5), gfx.ClosePath(),
		},
	}},
}

const (
	// updateDialogWidth is the dialog's width in a window wide enough for it.
	updateDialogWidth = float32(600)
	// updateNotesMaxHeight is the most room the notes take, and updateNotesMinHeight the least
	// a short window leaves them; longer notes scroll inside it.
	updateNotesMaxHeight = float32(300)
	updateNotesMinHeight = float32(80)
	// updateDialogChrome is the room the dialog takes around the notes: the title, the
	// description, the lines under the notes and the buttons, which a short window keeps.
	updateDialogChrome = float32(280)
	// The notes sit in a bordered box, with this room between its edge and the text.
	updateNotesPadX = float32(12)
	updateNotesPadY = float32(10)
	// updateArcSegments is how many straight pieces draw a whole turn of the progress arc.
	updateArcSegments = 48
)

// updateNotesPage is the release notes as the dialog shows them: the Markdown laid out for the
// width the dialog has, and where it is scrolled to. It is made on the window thread when the
// notes arrive and kept until other notes replace them.
type updateNotesPage struct {
	source string
	doc    markdown.Document
	view   components.MarkdownView
	style  components.MarkdownStyle
	input  ui.Handlers
	draw   func(*ui.DrawContext)
	// laid says what the view was laid out for, and height is the text's height there.
	laid   updateNotesLayout
	height float32
	// scroll is how far down the text is; area is where the box's control was painted last.
	scroll float32
	area   gfx.Rect
	// label is the rendered text, the control's accessible name.
	label string
}

// updateNotesLayout is what a layout of the notes depends on.
type updateNotesLayout struct {
	width, size float32
	face        gfx.MonoFace
}

// updateArrowPaint is the progress arc of the arrow while the update downloads: the path for
// progress, in hundredths, kept until the progress moves on, and the painter kept so the
// declaration makes no method value.
type updateArrowPaint struct {
	progress int
	path     gfx.Path
	draw     func(*ui.DrawContext)
}

// updateArrow declares the green arrow at the trailing end of the title bar while a version is
// available that the user did not skip. Its tooltip says what it leads to, and a click opens
// the update dialog.
func (a *App) updateArrow(c ui.C) {
	u := a.updates
	if u == nil {
		return
	}
	s := a.updateStatus()
	if !updateArrowShown(s) {
		return
	}
	lang := a.language()
	tint := updateGreen
	label := i18n.SharedFormat(lang, "desktop.updates.arrow.available", map[string]string{"version": s.Available})
	switch {
	case s.Ready || s.Installing:
		label = i18n.SharedFormat(lang, "desktop.updates.arrow.ready", map[string]string{"version": s.Available})
	case s.Downloading:
		label = i18n.SharedFormat(lang, "desktop.updates.arrow.downloading", map[string]string{
			"version": s.Available, "percent": strconv.Itoa(int(s.Progress * 100)),
		})
		// The ring fades, and the arc drawn over it fills as the download goes.
		tint.Alpha = 0.3
	}
	k := c.Part("update-arrow")
	box := a.chromeHover(ui.Row(k).Size(chromeIconButton, chromeIconButton).Shrink(0).Center().Radius(chromeIconButton/2).
		HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
		Tooltip(label).TooltipOn(ui.TooltipBottom))
	if s.Ready || s.Installing {
		// Downloaded: the button itself turns green, so it shows from across the window.
		box = box.Background(gfx.RGBA(22, 163, 74, 0.16))
	}
	if s.Downloading && !s.Applying {
		a.updateArc(s.Progress)
		box = box.DrawOver(u.arrow.draw)
	}
	box.Children(func() {
		ui.Icon(c, updateIcon).Size(chromeIconSize, chromeIconSize).Color(tint)
	})
	if box.Clicked() {
		c.After(func() { a.showUpdateDialog(surfaceToolbar) })
	}
}

// updateArc readies the arc for progress: a turn clockwise from the top, as far as the share
// downloaded, laid over the arrow's ring.
func (a *App) updateArc(progress float32) {
	p := &a.updates.arrow
	if p.draw == nil {
		p.draw = a.paintUpdateArc
	}
	hundredths := int(math.Round(float64(min(max(progress, 0), 1)) * 100))
	if hundredths == p.progress && p.progress > 0 {
		return
	}
	p.progress = hundredths
	if hundredths == 0 {
		p.path = gfx.Path{}
		return
	}
	turn := 2 * math.Pi * float64(hundredths) / 100
	n := max(2, int(math.Ceil(updateArcSegments*float64(hundredths)/100)))
	commands := make([]gfx.PathCommand, 0, n+1)
	for i := 0; i <= n; i++ {
		angle := -math.Pi/2 + turn*float64(i)/float64(n)
		x, y := float32(12+10*math.Cos(angle)), float32(12+10*math.Sin(angle))
		if i == 0 {
			commands = append(commands, gfx.MoveTo(x, y))
		} else {
			commands = append(commands, gfx.LineTo(x, y))
		}
	}
	p.path = gfx.NewPath(24, 24, commands...)
}

// paintUpdateArc draws the progress arc over the arrow's icon, in the middle of the button.
func (a *App) paintUpdateArc(dc *ui.DrawContext) {
	p := &a.updates.arrow
	if p.progress == 0 {
		return
	}
	size := float32(chromeIconSize)
	icon := gfx.Rect{X: dc.Rect.X + (dc.Rect.Width-size)/2, Y: dc.Rect.Y + (dc.Rect.Height-size)/2, Width: size, Height: size}
	dc.Canvas.DrawPath(p.path, icon, gfx.PathStyle{Stroke: updateGreen, StrokeWidth: 1.5, Cap: gfx.CapRound, Join: gfx.JoinRound})
}

// updateDialog declares the update dialog while it is open: what the version changed, then
// what to do with it. Every action is taken after the paint, and dismissing the dialog is
// Later.
func (a *App) updateDialog(c ui.C) {
	u := a.updates
	if u == nil || !u.dialog {
		return
	}
	s := a.updateStatus()
	if s.Available == "" {
		return
	}
	lang := a.language()
	// Once the version is downloaded the title says so, and the size it would download is gone.
	downloaded := s.Ready || s.Installing
	title := i18n.SharedFormat(lang, "desktop.updates.dialog.title", map[string]string{"version": s.Available})
	if downloaded {
		title = i18n.SharedFormat(lang, "desktop.updates.dialog.titleReady", map[string]string{"version": s.Available})
	}
	description := i18n.SharedFormat(lang, "desktop.updates.dialog.current", map[string]string{
		"version": a.version, "channel": settingswindow.ChannelName(lang, s.Installed),
	})
	if size := updateSizeText(lang, s); size != "" && !downloaded {
		description += " · " + size
	}
	bounds := c.Bounds()
	width := min(updateDialogWidth, bounds.Width-32)
	bodyWidth := width - 2*(a.theme.Metrics.PadSurface+a.theme.Metrics.GapItem)
	maxNotes := max(min(updateNotesMaxHeight, bounds.Height-updateDialogChrome), updateNotesMinHeight)
	body := func() {
		ui.Column(c).FillWidth().Gap(10).Children(func() {
			if s.Cross {
				ui.Column(c).FillWidth().PadX(10).PadY(8).Radius(a.theme.Metrics.RadiusItem()).Background(a.theme.Muted).Children(func() {
					ui.Wrap(c, i18n.SharedFormat(lang, "desktop.updates.dialog.cross", map[string]string{
						"channel": settingswindow.ChannelName(lang, s.Channel),
					})).FontSize(12).Color(a.theme.MutedForeground)
				})
			}
			a.updateNotesBox(c, lang, s, bodyWidth, maxNotes)
			if s.NotesURL != "" {
				ui.Row(c).FillWidth().Children(func() {
					if ui.Button(c.Part("update-full-notes"), i18n.Shared(lang, "desktop.updates.dialog.fullNotes")).Link().Small().Clicked() {
						c.After(func() { a.openUpdateNotes(s.NotesURL) })
					}
				})
			}
			if s.Downloading || s.Installing {
				ui.Column(c).FillWidth().Gap(6).Children(func() {
					ui.Wrap(c, settingswindow.UpdateLine(lang, s, a.version)).FontSize(12).Color(a.colors.Subtle)
					if s.Downloading && !s.Applying {
						ui.Progress(c, s.Progress).FillWidth()
					}
				})
			}
			if s.Failure != "" {
				ui.Wrap(c, i18n.SharedFormat(lang, "desktop.settings.updates.failed", map[string]string{"reason": s.Failure})).
					FontSize(12).Color(a.theme.Danger)
			}
			if s.Manual != "" {
				ui.Wrap(c, s.Manual).FontSize(12).Color(a.colors.Warning)
			}
		})
	}
	action := ""
	footer := func() {
		later := i18n.Shared(lang, "desktop.updates.dialog.later")
		switch {
		case s.Manual != "":
			if ui.Button(c.Part("update-later"), later).Outline().Clicked() {
				action = "later"
			}
			if ui.Button(c.Part("update-downloads"), i18n.Shared(lang, "desktop.updates.dialog.downloads")).AutoFocus().Clicked() {
				action = "downloads"
			}
		case s.Installing:
			if ui.Button(c.Part("update-later"), later).Secondary().Clicked() {
				action = "later"
			}
		case s.Downloading:
			// Applying a patch cannot be stopped, so it offers no Cancel.
			if !s.Applying && ui.Button(c.Part("update-cancel"), i18n.Shared(lang, "ui.cancel")).Outline().Clicked() {
				action = "cancel"
			}
			if ui.Button(c.Part("update-later"), later).Secondary().AutoFocus().Clicked() {
				action = "later"
			}
		case s.Ready:
			if ui.Button(c.Part("update-later"), later).Secondary().Clicked() {
				action = "later"
			}
			if ui.Button(c.Part("update-restart"), i18n.Shared(lang, "desktop.updates.dialog.restart")).AutoFocus().Clicked() {
				action = "update"
			}
		default:
			// A version the user skipped and opened again from the settings can only be taken
			// or left: skipping it again would change nothing.
			if !s.Skipped && ui.Button(c.Part("update-skip"), i18n.Shared(lang, "desktop.updates.dialog.skip")).Outline().Clicked() {
				action = "skip"
			}
			if ui.Button(c.Part("update-later"), later).Secondary().Clicked() {
				action = "later"
			}
			if ui.Button(c.Part("update-download"), i18n.Shared(lang, "desktop.updates.dialog.download")).
				Disabled(s.Checking).AutoFocus().Clicked() {
				action = "update"
			}
		}
	}
	open := true
	if ui.Modal(c, &open, title, ui.ModalSpec{Description: description, Width: width}, body, footer) {
		action = "later"
	}
	switch action {
	case "later":
		c.After(a.closeUpdateDialog)
	case "skip":
		c.After(a.skipUpdate)
	case "update":
		c.After(a.updateNow)
	case "cancel":
		c.After(a.cancelUpdate)
	case "downloads":
		c.After(a.openUpdateDownloads)
	}
}

// updateSizeText says how much Download and Install downloads: the patch next to the full
// archive when there is one, else the archive; empty when the feed says neither.
func updateSizeText(lang i18n.Language, s settingswindow.UpdateStatus) string {
	switch {
	case s.Delta && s.DeltaSize > 0 && s.FullSize > 0:
		return i18n.SharedFormat(lang, "desktop.updates.dialog.sizeDelta", map[string]string{
			"size": formatByteSize(uint64(s.DeltaSize)), "full": formatByteSize(uint64(s.FullSize)),
		})
	case s.FullSize > 0:
		return i18n.SharedFormat(lang, "desktop.updates.dialog.sizeFull", map[string]string{"size": formatByteSize(uint64(s.FullSize))})
	}
	return ""
}

// updateNotesBox declares the bordered box with the release notes: a line while they are on
// the way, another when the version has none, and else the Markdown, as tall as it is up to
// maxHeight and scrolling past it.
func (a *App) updateNotesBox(c ui.C, lang i18n.Language, s settingswindow.UpdateStatus, width, maxHeight float32) {
	box := ui.Column(c).FillWidth().Shrink(0).Border(1, a.theme.Border).Radius(a.theme.Metrics.RadiusItem())
	switch {
	case s.NotesLoading:
		box.PadX(updateNotesPadX).PadY(updateNotesPadY).Children(func() {
			ui.Row(c).Gap(8).Items(ui.Center).Children(func() {
				ui.Spinner(c)
				ui.Text(c, i18n.Shared(lang, "desktop.updates.dialog.notesLoading")).FontSize(12).Color(a.colors.Subtle)
			})
		})
		return
	case s.Notes == "":
		box.PadX(updateNotesPadX).PadY(updateNotesPadY).Children(func() {
			ui.Wrap(c, i18n.Shared(lang, "desktop.updates.dialog.noNotes")).FontSize(12).Color(a.colors.Subtle)
		})
		return
	}
	u := a.updates
	if u.notes == nil || u.notes.source != s.Notes {
		u.notes = a.newUpdateNotesPage(s.Notes)
	}
	page := u.notes
	if canvas := c.Canvas(); canvas != nil {
		// The box's border takes a pixel on each side.
		a.layoutUpdateNotes(canvas, page, width-2-2*updateNotesPadX)
	}
	height := min(page.height+2*updateNotesPadY, maxHeight)
	box.Height(height + 2).Children(func() {
		const name = "update-notes"
		ui.Control(c.Part(name), page.label, &page.input).Fill().Draw(page.draw).
			HitWith(ui.ID(c.Part(name)), page.label, gfx.HitOptions{Role: gfx.RoleGroup})
	})
}

// newUpdateNotesPage parses source into a page with its handlers: the wheel and the keys
// scroll it, and a press on a web link opens it in the browser.
func (a *App) newUpdateNotesPage(source string) *updateNotesPage {
	page := &updateNotesPage{source: source}
	page.doc.Parse(source)
	page.input = ui.Handlers{
		Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
			dy := event.DeltaY
			if !event.Precise {
				dy *= 3
			}
			before := page.scroll
			page.scroll = page.clamp(page.scroll + dy)
			return gfx.EventResult{Handled: true, Repaint: page.scroll != before}
		},
		Pointer: func(event gfx.PointerEvent) gfx.EventResult {
			if event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonPrimary {
				return gfx.EventResult{}
			}
			index, ok := event.Target.In(page.input.Parts())
			if !ok {
				return gfx.EventResult{}
			}
			a.openUpdateNotes(page.view.Link(index))
			return gfx.EventResult{Handled: true, Repaint: true}
		},
		Key: func(event gfx.KeyEvent) gfx.EventResult {
			if event.Release {
				return gfx.EventResult{}
			}
			offset, ok := page.offsetForKey(event.Key)
			if !ok {
				return gfx.EventResult{}
			}
			before := page.scroll
			page.scroll = offset
			return gfx.EventResult{Handled: true, Repaint: page.scroll != before}
		},
	}
	page.draw = func(dc *ui.DrawContext) { a.paintUpdateNotes(dc, page) }
	return page
}

// layoutUpdateNotes lays the notes out in width, in the body font with code in the editor's.
func (a *App) layoutUpdateNotes(canvas *gfx.Canvas, page *updateNotesPage, width float32) {
	size := a.theme.Metrics.FontSizeM
	key := updateNotesLayout{width: width, size: size, face: a.fonts.editor.face}
	if page.laid == key {
		return
	}
	page.laid = key
	page.style.Size = size
	page.style.LineHeight = float32(math.Round(float64(size) * 1.5))
	page.style.MonoFace = key.face
	page.height = page.view.Layout(canvas, page.style, &page.doc, max(width, 1))
	page.label = page.view.SelectedText(ui.TextRange{Focus: page.view.TextLen()})
}

// clamp keeps a scroll of the notes inside them.
func (page *updateNotesPage) clamp(y float32) float32 {
	return min(max(y, 0), max(page.height+2*updateNotesPadY-page.area.Height, 0))
}

// offsetForKey is where the keyboard moves the notes to, as in Motty: two lines for the arrows,
// most of the box for the page keys, the ends for Home and End.
func (page *updateNotesPage) offsetForKey(key gfx.Key) (float32, bool) {
	step := 2 * max(page.style.LineHeight, 1)
	screen := max(page.area.Height*0.9, step)
	offset := page.scroll
	switch key {
	case gfx.KeyUp:
		offset -= step
	case gfx.KeyDown:
		offset += step
	case gfx.KeyPageUp:
		offset -= screen
	case gfx.KeyPageDown:
		offset += screen
	case gfx.KeyHome:
		offset = 0
	case gfx.KeyEnd:
		offset = page.height
	default:
		return offset, false
	}
	return page.clamp(offset), true
}

// paintUpdateNotes draws the notes inside their box, with a thin bar when they scroll.
func (a *App) paintUpdateNotes(dc *ui.DrawContext, page *updateNotesPage) {
	page.area = dc.Rect
	page.scroll = page.clamp(page.scroll)
	clip := gfx.Rect{X: dc.Rect.X, Y: dc.Rect.Y + 2, Width: dc.Rect.Width, Height: max(dc.Rect.Height-4, 0)}
	page.view.Paint(dc.Canvas, components.MarkdownPaint{
		Look: components.MarkdownLookFor(a.theme),
		X:    dc.Rect.X + updateNotesPadX, Y: dc.Rect.Y + updateNotesPadY - page.scroll,
		Clip:  clip,
		Links: page.input.Parts(),
	})
	total := page.height + 2*updateNotesPadY
	if total <= dc.Rect.Height || dc.Rect.Height <= 8 {
		return
	}
	track := dc.Rect.Height - 8
	thumb := max(track*dc.Rect.Height/total, 16)
	top := dc.Rect.Y + 4 + (track-thumb)*page.scroll/(total-dc.Rect.Height)
	bar := a.colors.Subtle
	bar.Alpha *= 0.45
	dc.Canvas.Rounded(gfx.Rect{X: dc.Rect.X + dc.Rect.Width - 6, Y: top, Width: 3, Height: thumb}, 1.5, bar)
}

// openUpdateNotes opens a link of the notes, or the full notes, in the browser. Only web
// addresses are followed: the notes are not signed, so a link to anything else is ignored.
func (a *App) openUpdateNotes(address string) {
	parsed, err := url.Parse(address)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" {
		return
	}
	a.performed("updates.notes", surfaceButton)
	if err := openURL(parsed.String()); err != nil {
		a.operationFailed("open_url", err)
	}
}
