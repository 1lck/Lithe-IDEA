package logwindow

import (
	"errors"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/appicon"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
	"github.com/1lck/Lithe-IDEA/desktop/internal/windowcontrols"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	vivatext "github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// WindowOptions configure the log window.
type WindowOptions struct {
	Options
	// Text is the interface language the window paints; nil is English.
	Text func() *i18n.Messages
	// Dark says whether the window uses the dark palette; nil is light.
	Dark func() bool
	// Shortcut is the key that opens the window, shown in its title bar; empty shows none.
	Shortcut string
	// OnClosed runs on the window thread after the window has closed.
	OnClosed func()
}

// Controller opens the log window and keeps at most one open: opening it again brings the
// open one to the front.
type Controller struct {
	opts WindowOptions

	// mu guards current and models: Open runs on the window thread of the window that asks,
	// and OnClosed on the log window's.
	mu      sync.Mutex
	current *window
	models  []*Model
}

// NewController returns a controller with no window open.
func NewController(opts WindowOptions) *Controller {
	return &Controller{opts: opts}
}

// text is the language the window paints now.
func (c *Controller) text() *i18n.Messages {
	if c.opts.Text != nil {
		if text := c.opts.Text(); text != nil {
			return text
		}
	}
	return i18n.For(i18n.English)
}

// Open shows the log window, opening it when none is open. It must run on a window thread
// of application, as app.Application.OpenWindow requires.
func (c *Controller) Open(application *app.Application) error {
	c.mu.Lock()
	if c.current != nil && c.current.win != nil && !c.current.win.Closed() {
		win := c.current.win
		c.mu.Unlock()
		win.Show()
		return nil
	}
	c.mu.Unlock()

	w := &window{ctrl: c, filterRevision: -1, anchors: map[menuKind]ui.Box{}}
	opts := c.opts.Options
	opts.Wake = w.inv.Invalidate
	if opts.Clipboard == nil {
		opts.Clipboard = app.SetClipboardText
	}
	if opts.Reveal == nil {
		opts.Reveal = app.RevealPath
	}
	if opts.ChooseDirectory == nil {
		opts.ChooseDirectory = func(string) (string, error) {
			dir, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: c.text().Logs.ChooseDirectory})
			if errors.Is(err, app.ErrCanceled) {
				return "", nil
			}
			return dir, err
		}
	}
	if opts.SaveFile == nil {
		opts.SaveFile = func(suggested string) (string, error) {
			path, err := app.SaveFile(app.SaveFileOptions{
				Title:            c.text().Logs.ExportLabel,
				SuggestedName:    suggested,
				DefaultExtension: "zip",
				Filters:          []app.FileFilter{{Name: "ZIP", Pattern: "*.zip"}},
			})
			if errors.Is(err, app.ErrCanceled) {
				return "", nil
			}
			return path, err
		}
	}
	if opts.CacheDirectory == nil {
		opts.CacheDirectory = os.UserCacheDir
	}
	if opts.System == nil {
		opts.System = sysinfo.Current
	}
	w.model = NewModel(opts)
	win, err := application.OpenWindow(w.config(), nil)
	if err != nil {
		w.model.close()
		return err
	}
	c.mu.Lock()
	w.win = win
	c.current = w
	c.models = append(c.models, w.model)
	c.mu.Unlock()
	return nil
}

// Close closes the open window, if any. It is safe from any goroutine.
func (c *Controller) Close() {
	c.mu.Lock()
	current := c.current
	c.mu.Unlock()
	if current != nil && current.win != nil {
		current.win.Close()
	}
}

// Invalidate repaints an open log window after shared application state changes.
func (c *Controller) Invalidate() {
	c.mu.Lock()
	current := c.current
	c.mu.Unlock()
	if current != nil {
		current.inv.Invalidate()
	}
}

// Wait waits for the background work of every window the controller opened. Call it after
// the windows have closed.
func (c *Controller) Wait() {
	c.mu.Lock()
	models := c.models
	c.mu.Unlock()
	for _, model := range models {
		model.wait()
	}
}

// The identities of the window's frame. The toolbar, the table, the channel list, the
// histogram and the details declare their own under page, next to their code.
var (
	tree = gfx.Tree{}
	page = tree.Feature("logs")

	// The text fields of the window. A field the window paints must also be listed in
	// config's TextInput.
	filterID       = tree.ID(page, "filter")
	bookmarkNameID = tree.ID(page, "bookmark-name")
	rangeStartID   = tree.ID(page, "range-start")
	rangeEndID     = tree.ID(page, "range-end")

	retryID        = tree.ID(page, "retry")
	newLogsID      = tree.ID(page, "new-logs")
	detailsDivider = tree.ID(page, "details-divider")
	// menuDismiss is the backdrop of an open menu: a press anywhere outside the menu closes
	// it.
	menuDismiss = tree.ID(page, "menu-dismiss")

	clearScope   = tree.ID(page, "clear-dialog")
	clearCancel  = tree.ID(page, "clear-cancel")
	clearConfirm = tree.ID(page, "clear-confirm")
	clearClose   = tree.ID(page, "clear-close")

	bookmarkScope  = tree.ID(page, "bookmark-dialog")
	bookmarkCancel = tree.ID(page, "bookmark-cancel")
	bookmarkSave   = tree.ID(page, "bookmark-save")
	bookmarkClose  = tree.ID(page, "bookmark-close")
)

const (
	// titleHeight is the height of the window's title bar.
	titleHeight = 28
	// sidebarWidth is the width of the channel list.
	sidebarWidth = 212
	// The details pane is detailsDefault tall, or detailsShare of the body when that is
	// more, and the user can drag it between detailsMin and detailsMax. The table keeps at
	// least tableMin of the body.
	detailsDefault = 196
	detailsShare   = 0.28
	detailsMin     = 130
	detailsMax     = 420
	tableMin       = 100
	// statusHeight is the height of the status bar.
	statusHeight = 24
	// pulsePeriod is a full cycle of the following pulse, which dims and brightens again.
	pulsePeriod = 1400 * time.Millisecond
	// tooltipDelay is how long the pointer rests on a control before its hint shows.
	tooltipDelay = 500 * time.Millisecond
	// tooltipLayer is over the menus and the dialogs.
	tooltipLayer = 6
)

// dialogKind is the dialog the window shows.
type dialogKind int

const (
	dialogNone dialogKind = iota
	// dialogClear confirms deleting the collected logs.
	dialogClear
	// dialogBookmark asks for the name of the filter to save.
	dialogBookmark
)

// window is one open log window. Everything in it runs on its window thread.
type window struct {
	ctrl  *Controller
	model *Model
	win   *app.Window
	inv   app.Invalidator
	view  ui.View
	pal   palette
	theme gfx.Theme
	text  *i18n.Messages
	tip   components.HoverTooltip

	// started says the model was started, in the window's first paint.
	started bool

	filter, bookmarkName, rangeStart, rangeEnd ui.Field
	// filterRevision is the model's expressionRevision the filter field shows, and
	// lastFilter the text it had after the last paint: a change the user typed is told
	// apart from one the model made.
	filterRevision int
	lastFilter     string
	// focusFilter asks the next paint to focus the filter field (⌘F).
	focusFilter bool
	// editing says a text field had the focus in the last paint, so ⌘C copies its text
	// and not the selected records.
	editing bool

	menu menuState
	// anchors are the controls the toolbar's menus open under, for the frame being drawn.
	anchors map[menuKind]ui.Box
	dialog  dialogKind

	// bodyBox is the column of the table and the details; bodyHeight is its height in the
	// last frame, which bounds the details' height.
	bodyBox    ui.Box
	bodyHeight float32
	// detailsHeight is the height the user dragged the details to; zero is the default.
	detailsHeight float32
	dragging      bool
	dragStartY    float32
	dragStartH    float32

	toolbar   toolbarState
	table     tableState
	sidebar   sidebarState
	histogram histogramState
	details   detailsState
}

// config is the native window's configuration.
func (w *window) config() app.Config {
	return app.Config{
		Title:          w.ctrl.text().Logs.Logs,
		Icon:           appicon.Window(),
		Width:          1100,
		Height:         720,
		MinWidth:       900,
		MinHeight:      500,
		WindowMode:     app.WindowCustomTitlebar,
		TitlebarHeight: titleHeight,
		WindowControls: func() app.WindowControlsStyle { return windowcontrols.Style(w.pal.tx, w.ctrl.text()) },
		Tree:           &tree,
		Paint:          w.paint,
		OnKey:          w.onKey,
		OnShortcut:     w.onShortcut,
		OnScroll:       w.onScroll,
		TextInput:      ui.Fields(&w.filter, &w.bookmarkName, &w.rangeStart, &w.rangeEnd),
		Invalidator:    &w.inv,
		OnWake:         w.model.drain,
		OnClosed:       w.closed,
	}
}

// closed stops the model once the native window is gone. The export sheet goes first, so
// what it staged is removed.
func (w *window) closed() {
	w.model.dismissExport()
	w.model.close()
	c := w.ctrl
	c.mu.Lock()
	if c.current == w {
		c.current = nil
	}
	c.mu.Unlock()
	if c.opts.OnClosed != nil {
		c.opts.OnClosed()
	}
}

// windowTheme maps the palette onto the theme the Viva controls paint with, so a field, a
// button or a dialog in the window takes the log window's colors.
func windowTheme(p palette) gfx.Theme {
	theme := gfx.LightTheme()
	if p.dark {
		theme = gfx.DarkTheme()
	}
	theme.Metrics = theme.Metrics.WithDensity(gfx.DensityCompact)
	theme.Background, theme.Foreground = p.bg, p.tx
	theme.Card, theme.CardForeground, theme.CardElevated = p.bg2, p.tx, p.menu
	theme.Popover, theme.PopoverForeground = p.menu, p.tx
	theme.Muted, theme.MutedForeground = p.bg3, p.tx2
	theme.Border, theme.Input, theme.Hover = p.line, p.bd, p.bg3
	theme.Primary, theme.PrimaryForeground = p.blu, p.white
	theme.Selection, theme.Ring, theme.Danger = p.hl, p.blu, p.red
	return theme
}

func (w *window) paint(canvas *gfx.Canvas, size gfx.Size) {
	w.text = w.ctrl.text()
	w.pal = lightPalette()
	if w.ctrl.opts.Dark != nil && w.ctrl.opts.Dark() {
		w.pal = darkPalette()
	}
	w.theme = windowTheme(w.pal)
	bounds := gfx.Rect{Width: size.Width, Height: size.Height}
	canvas.Fill(bounds, w.pal.bg)
	if !w.started {
		w.started = true
		w.model.start()
		w.model.loadUsedBytes()
	}
	if w.focusFilter {
		w.focusFilter = false
		canvas.RequestFocus(filterID)
	}
	switch canvas.Focused() {
	case filterID, bookmarkNameID, rangeStartID, rangeEndID:
		w.editing = true
	default:
		w.editing = false
	}
	w.syncFilter()
	clear(w.anchors)

	w.view.Draw(canvas, w.theme, bounds, func(f *ui.Frame) {
		f.PopupLayer(1)
		f.Column().Fill().Children(func() {
			w.drawTitle(f)
			w.drawToolbar(f)
			w.drawFilterError(f)
			w.drawLoadError(f)
			w.drawHistogram(f)
			w.drawBody(f)
			w.drawStatus(f)
		})
		w.drawMenus(f)
		w.drawDialogs(f)
		w.drawExportSheet(f, bounds)
	})
	w.bodyHeight = w.bodyBox.Rect().Height
	w.lastFilter = w.filter.Text()

	w.tip.Paint(canvas, w.theme, bounds, components.TooltipOptions{Layer: tooltipLayer, MaxWidth: 320}, tooltipDelay)
	if w.model.follows {
		// The pulse in the status bar breathes while the window follows the log.
		canvas.RequestFrameIn(50 * time.Millisecond)
	} else if w.model.diagnosticsLeft() > 0 {
		// The diagnostics card counts down.
		canvas.RequestFrameIn(time.Second)
	}
}

// syncFilter keeps the filter field and the model's expression in step. An expression the
// model changed (a composed term, an applied bookmark) replaces the field's text; text the
// user typed becomes the expression.
func (w *window) syncFilter() {
	if w.filterRevision != w.model.expressionRevision {
		w.filterRevision = w.model.expressionRevision
		w.filter.SetText(w.model.prefs.Query.Expression)
		w.lastFilter = w.filter.Text()
		return
	}
	if text := w.filter.Text(); text != w.lastFilter {
		w.lastFilter = text
		w.model.setExpression(text)
	}
}

// drawTitle is the title bar: the directory of the session the window shows, and the
// shortcut that opens the window at the trailing end. The whole bar moves the window.
func (w *window) drawTitle(f *ui.Frame) {
	title := w.text.Logs.Logs
	if w.model.directory != "" {
		title = abbreviateHome(filepath.Join(w.model.directory, w.model.currentSessionPath))
	}
	leading, trailing := app.TitlebarInsets()
	f.Stack().FillWidth().Height(titleHeight).Shrink(0).Background(w.pal.bg3).MovesWindow().Children(func() {
		// The system's window buttons sit at the leading end, so the title keeps clear of
		// them on that side and is centered in what is left.
		f.Row().Fill().PadSides(0, max(60, trailing+60), 0, max(80, leading+10)).Center().Children(func() {
			f.Text(title).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.tx).Ellipsis()
		})
		if w.ctrl.opts.Shortcut != "" {
			f.Row().Absolute().Top(0).Bottom(0).Right(12).Items(ui.Center).Children(func() {
				f.Row().PadX(5).PadY(1).Radius(4).Border(1, w.pal.bd).Children(func() {
					w.mono(f, w.ctrl.opts.Shortcut, 11, w.pal.tx2)
				})
			})
		}
	})
}

// drawFilterError shows the first syntax error of the filter with a caret under the part of
// the expression it is about.
func (w *window) drawFilterError(f *ui.Frame) {
	if len(w.model.diagnostics) == 0 {
		return
	}
	d := w.model.diagnostics[0]
	caret := strings.Repeat(" ", min(128, max(0, d.Start))) + strings.Repeat("^", max(1, min(128, d.End-d.Start)))
	f.Column().FillWidth().Shrink(0).PadX(10).Gap(2).Children(func() {
		w.mono(f, w.text.Logs.FilterError(d.Start, d.End, w.filterReason(d.Code, d.Message)), 12.5, w.pal.red)
		w.mono(f, caret, 11, w.pal.red)
	})
}

// filterReason is the sentence for a filter error code, or the kernel's message for a code
// the client does not know.
func (w *window) filterReason(code, message string) string {
	m := w.text.Logs.Filter
	switch code {
	case "emptyValue":
		return m.EmptyValue
	case "expressionTooLong":
		return m.ExpressionTooLong
	case "invalidEscape":
		return m.InvalidEscape
	case "invalidLevel":
		return m.InvalidLevel
	case "invalidOperator":
		return m.InvalidOperator
	case "invalidQuote":
		return m.InvalidQuote
	case "invalidRegex":
		return m.InvalidRegex
	case "regexTooLong":
		return m.RegexTooLong
	case "unterminatedQuote":
		return m.UnterminatedQuote
	case "unterminatedRegex":
		return m.UnterminatedRegex
	}
	return message
}

// drawLoadError says the logs could not be read and offers to read them again.
func (w *window) drawLoadError(f *ui.Frame) {
	if !w.model.failed {
		return
	}
	f.Row().FillWidth().Shrink(0).PadX(10).PadY(4).Gap(8).Items(ui.Center).Children(func() {
		w.mono(f, w.text.Logs.LoadFailed, 12.5, w.pal.red)
		if f.Button(retryID, w.text.Logs.Retry).XSmall().Outline().Clicked() {
			w.model.retry()
		}
	})
}

// drawBody is the channel list beside the table, with the details under the table.
func (w *window) drawBody(f *ui.Frame) {
	f.Row().FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
		f.Column().Width(sidebarWidth).FillHeight().Shrink(0).Background(w.pal.bg2).Clip().PadSides(8, 0, 0, 0).Children(func() {
			w.drawSidebar(f)
		})
		f.Row().Width(1).FillHeight().Shrink(0).Background(w.pal.line)
		w.bodyBox = f.Column().Grow(1).Shrink(1).FillHeight().MinWidth(0).Children(func() {
			f.Stack().FillWidth().Grow(1).Shrink(1).MinHeight(0).Clip().Children(func() {
				w.drawTable(f)
				if len(w.model.records) == 0 {
					empty := w.text.Logs.NoMatches
					if w.model.cleared {
						empty = w.text.Logs.ViewCleared
					}
					f.Row().Fill().Center().Children(func() {
						w.mono(f, empty, 12.5, w.pal.tx3)
					})
				}
				if !w.model.follows && w.model.newCount > 0 {
					w.drawNewLogs(f)
				}
			})
			height := w.detailsPaneHeight(f.Canvas())
			f.Row().FillWidth().Height(1).Shrink(0).Background(w.pal.line).
				HitWith(detailsDivider, "", gfx.HitOptions{Role: gfx.RoleSeparator, Cursor: gfx.PointerCursorResizeVertical, SkipFocus: true}).
				HitOutset(3, 0, 3, 0)
			f.Column().FillWidth().Height(height).Shrink(0).Background(w.pal.bg2).Clip().Children(func() {
				w.drawDetails(f)
			})
		})
	})
}

// drawNewLogs is the capsule at the bottom of the table that says how many records arrived
// while the user looked elsewhere, and jumps to them.
func (w *window) drawNewLogs(f *ui.Frame) {
	f.Row().Fill().Justify(ui.Center).Items(ui.End).PadSides(0, 0, 8, 0).Children(func() {
		capsule := f.Row().PadX(14).PadY(4).Radius(999).Background(w.pal.blu).
			HitWith(newLogsID, w.text.Logs.NewLogs(w.model.newCount), gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
			Children(func() {
				w.mono(f, w.text.Logs.NewLogs(w.model.newCount), 12.5, w.pal.white)
			})
		if capsule.Clicked() {
			w.model.resume()
		}
	})
}

// detailsPaneHeight follows a drag of the divider over the details and returns the height
// the details take in this frame.
func (w *window) detailsPaneHeight(canvas *gfx.Canvas) float32 {
	if event, ok := canvas.PointerOn(detailsDivider); ok {
		switch event.Kind {
		case gfx.PointerDown:
			if event.Button == gfx.PointerButtonPrimary {
				w.dragging = true
				w.dragStartY = event.Y
				w.dragStartH = w.currentDetailsHeight()
				canvas.Consume()
			}
		case gfx.PointerMove:
			if w.dragging {
				w.detailsHeight = w.clampDetails(w.dragStartH - (event.Y - w.dragStartY))
				canvas.Consume()
			}
		case gfx.PointerUp, gfx.PointerExit:
			if w.dragging {
				w.dragging = false
				canvas.Consume()
			}
		}
	}
	return w.currentDetailsHeight()
}

// currentDetailsHeight is the height of the details: the one the user dragged to, or the
// default share of the body, kept inside the bounds the body allows.
func (w *window) currentDetailsHeight() float32 {
	if w.bodyHeight <= 0 {
		// The first frame does not know the body's height yet.
		return detailsDefault
	}
	height := w.detailsHeight
	if height == 0 {
		height = max(detailsDefault, w.bodyHeight*detailsShare)
	}
	return w.clampDetails(height)
}

func (w *window) clampDetails(height float32) float32 {
	limit := float32(detailsMax)
	if w.bodyHeight > 0 {
		limit = max(detailsMin, min(detailsMax, w.bodyHeight-tableMin-1))
	}
	return min(limit, max(detailsMin, height))
}

// drawStatus is the bar along the bottom: whether the window follows the log, how many rows
// it shows, and the writer's counters.
func (w *window) drawStatus(f *ui.Frame) {
	m := w.model
	f.Row().FillWidth().Height(statusHeight).Shrink(0).PadX(10).Gap(16).Items(ui.Center).Background(w.pal.foot).Children(func() {
		f.Row().Gap(5).Items(ui.Center).Children(func() {
			label := w.text.Logs.Paused
			if m.follows {
				f.Row().Size(7, 7).Radius(3.5).Background(w.pal.pulse).Opacity(pulseOpacity(f.Canvas().Now()))
				label = w.text.Logs.Tailing
			} else {
				w.mono(f, "❚❚", 11.5, w.pal.white)
				if m.scrolledUp {
					label = w.text.Logs.PausedScrolledUp
				}
			}
			w.mono(f, label, 11.5, w.pal.white)
		})
		w.mono(f, w.text.Logs.VisibleCount(groupNumber(len(m.displayRows())), groupNumber(m.totalRecords()), strconv.Itoa(m.selectedLine())), 11.5, w.pal.white)
		f.Spacer()
		w.mono(f, w.text.Logs.Dropped(m.discarded+m.dropped), 11.5, w.pal.white)
		w.mono(f, w.text.Logs.WriteFailures(m.writeFailures), 11.5, w.pal.white)
		w.mono(f, "v2 · UTF-8 · NDJSON", 11.5, w.pal.white)
	})
}

// pulseOpacity is the opacity of the following pulse at time now: it eases from 1 down to
// 0.25 and back over pulsePeriod.
func pulseOpacity(now time.Duration) float32 {
	half := pulsePeriod / 2
	t := float64(now%pulsePeriod) / float64(half)
	if t > 1 {
		t = 2 - t
	}
	eased := (1 - math.Cos(math.Pi*t)) / 2
	return float32(1 - 0.75*eased)
}

// drawDialogs declares the dialog that is open.
func (w *window) drawDialogs(f *ui.Frame) {
	switch w.dialog {
	case dialogClear:
		dialog := f.Dialog(ui.DialogSpec{
			Title:       w.text.Logs.ClearTitle,
			Description: w.text.Logs.ClearMessage,
			Width:       420,
			Scope:       clearScope,
			DismissID:   clearCancel,
			CloseID:     clearClose,
		})
		dialog.Footer(func() {
			f.Button(clearCancel, w.text.Logs.Cancel).Outline()
			if f.Button(clearConfirm, w.text.Logs.ClearAction).Destructive().Clicked() {
				w.model.clearLogs()
				w.dialog = dialogNone
			}
		})
		if dialog.Dismissed() {
			w.dialog = dialogNone
		}
	case dialogBookmark:
		dialog := f.Dialog(ui.DialogSpec{
			Title:          w.text.Logs.NameForFilter,
			Width:          360,
			Scope:          bookmarkScope,
			DismissID:      bookmarkCancel,
			CloseID:        bookmarkClose,
			InitialFocusID: bookmarkNameID,
		})
		submitted := false
		dialog.Body(func() {
			submitted = f.Field(&w.bookmarkName, bookmarkNameID, w.text.Logs.NameForFilter, w.text.Logs.NameForFilter).FillWidth().Submitted()
		})
		dialog.Footer(func() {
			f.Button(bookmarkCancel, w.text.Logs.Cancel).Outline()
			if f.Button(bookmarkSave, w.text.Logs.Save).Clicked() {
				submitted = true
			}
		})
		if submitted {
			w.model.saveBookmark(w.bookmarkName.Text())
			w.bookmarkName.SetText("")
			w.dialog = dialogNone
		} else if dialog.Dismissed() {
			w.bookmarkName.SetText("")
			w.dialog = dialogNone
		}
	}
}

func (w *window) onScroll(event gfx.ScrollEvent) gfx.EventResult {
	result := w.view.Wheel(event)
	w.tableScrolled()
	return result
}

func (w *window) onKey(event gfx.KeyEvent) gfx.EventResult {
	if event.Release {
		return gfx.EventResult{}
	}
	if event.Key == gfx.KeyEscape && w.menu.kind != menuNone {
		w.closeMenu()
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	if w.model.export.presented {
		return w.exportKey(event)
	}
	if w.dialog != dialogNone || w.editing {
		return gfx.EventResult{}
	}
	return w.tableKey(event)
}

// onShortcut handles the window's command shortcuts: ⌘F focuses the filter, ⌘C copies the
// selected records and ⌘W closes the window. While a dialog or the export sheet is open, only
// ⌘W works.
func (w *window) onShortcut(event gfx.KeyEvent) gfx.EventResult {
	if event.Release || event.Modifiers != gfx.ModifierMeta {
		return gfx.EventResult{}
	}
	if (w.dialog != dialogNone || w.model.export.presented) && event.Text != "w" {
		return gfx.EventResult{}
	}
	switch event.Text {
	case "f":
		w.focusFilter = true
	case "c":
		if w.editing {
			// The field copies its own selection.
			return gfx.EventResult{}
		}
		w.model.copyFormatted(w.model.selectedRecords(), "json")
	case "w":
		w.win.Close()
	default:
		return gfx.EventResult{}
	}
	return gfx.EventResult{Handled: true, Repaint: true}
}

// revealRecord shows the file of the selected record in the file manager.
func (w *window) revealRecord() {
	record, ok := w.model.selectedRecord()
	if !ok || w.model.directory == "" || w.model.opts.Reveal == nil {
		return
	}
	relative := record.RelativePath
	if !strings.HasPrefix(relative, "sessions/") {
		relative = w.model.currentSessionPath + "/" + relative
	}
	if err := w.model.opts.Reveal(filepath.Join(w.model.directory, filepath.FromSlash(relative))); err != nil {
		w.model.report(err)
	}
}

// buttonOptions are the variations of a toolbar button.
type buttonOptions struct {
	// active draws the button in the accent color; recording draws its text green.
	active, recording bool
	// fullWidth stretches the button across its container, its label at the start.
	fullWidth bool
	// proportional draws the title in the system font rather than the monospaced one, as the
	// macOS client's LogButtonStyle(monospaced: false) does.
	proportional bool
	disabled     bool
	// height is the button's height; zero is 28.
	height float32
	// hint is the tooltip; label is what assistive technology reads, the title when empty.
	hint, label string
}

// button declares one of the window's own buttons, in the look of the macOS client's: a
// symbol and a title on the window's background with a thin border. It returns the button,
// for Clicked and as the anchor of a menu it opens.
func (w *window) button(f *ui.Frame, id gfx.ID, symbol, title string, o buttonOptions) ui.Box {
	height := o.height
	if height == 0 {
		height = 28
	}
	label := o.label
	if label == "" {
		label = strings.TrimSpace(symbol + " " + title)
	}
	border := w.pal.bd
	color := w.pal.tx
	switch {
	case o.recording:
		color = w.pal.grn
	case o.active:
		color = w.pal.blu
	}
	if o.active {
		border = w.pal.blu
	}
	box := f.Row().Height(height).Shrink(0).PadX(9).Gap(5).Items(ui.Center).
		Background(w.pal.bg).Radius(6).Border(1, border).
		HitWith(id, label, gfx.HitOptions{Role: gfx.RoleButton, Hint: o.hint, Disabled: o.disabled})
	if o.fullWidth {
		box = box.FillWidth().Justify(ui.Start)
	}
	if o.disabled {
		box = box.Opacity(0.45)
	} else {
		box = box.Pressed(ui.Look{}.Background(w.pal.bg3))
	}
	box.Children(func() {
		if symbol != "" {
			w.mono(f, symbol, 12, color)
		}
		switch {
		case title == "":
		case o.proportional:
			f.Text(title).FontSize(12).Color(color).Ellipsis()
		default:
			w.mono(f, title, 12, color).Ellipsis()
		}
	})
	return box
}

// mono declares a line of monospaced text. A ui Text measures a monospaced text as one cell
// for every character, too few for a wide one such as a Chinese one, which is drawn on two,
// so a text that is not all printable ASCII is given the width it is drawn at.
func (w *window) mono(f *ui.Frame, s string, size float32, color gfx.Color) ui.Box {
	b := f.Text(s).Mono().FontSize(size).Color(color)
	if !printableASCII(s) {
		b = b.Width(monoWidth(f.Canvas(), s, size))
	}
	return b
}

// monoWidth is how wide a line of monospaced text at size is drawn.
func monoWidth(canvas *gfx.Canvas, s string, size float32) float32 {
	return canvas.TextWidthStyle(s, gfx.TextStyle{Size: size, Weight: gfx.WeightRegular, Mono: true})
}

// printableASCII says s holds nothing but printable ASCII, each character one cell of a
// monospaced line.
func printableASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] >= 0x7F {
			return false
		}
	}
	return true
}

// monoCells is how many cells of a monospaced font s takes: two for a wide character, none
// for a combining mark and one for any other.
func monoCells(s string) int {
	cells := 0
	for _, r := range s {
		cells += vivatext.CellWidth(r)
	}
	return cells
}

// badge declares a small framed key, such as the ⌘F beside the filter.
func (w *window) badge(f *ui.Frame, s string) {
	f.Row().PadX(5).Radius(4).Border(1, w.pal.bd).Shrink(0).Children(func() {
		w.mono(f, s, 11, w.pal.tx2)
	})
}

// info declares the ⓘ that explains a control when the pointer rests on it.
func (w *window) info(f *ui.Frame, id gfx.ID, hint string) {
	f.Row().Size(18, 18).Shrink(0).Center().
		HitWith(id, hint, gfx.HitOptions{Hint: hint, SkipFocus: true}).
		Children(func() {
			f.Icon(icons.Info).Size(12, 12).Color(w.pal.tx3)
		})
}

// formatBytes is a size in the decimal units the macOS client shows: whole bytes and
// kilobytes, megabytes and gigabytes with one decimal.
func formatBytes(n int64) string {
	switch {
	case n < 1000:
		return strconv.FormatInt(max(0, n), 10) + " B"
	case n < 1000*1000:
		return strconv.FormatInt(n/1000, 10) + " KB"
	case n < 1000*1000*1000:
		return strconv.FormatFloat(float64(n)/1e6, 'f', 1, 64) + " MB"
	}
	return strconv.FormatFloat(float64(n)/1e9, 'f', 1, 64) + " GB"
}

// groupNumber writes n with commas between groups of three digits, as the macOS client's
// status bar does in every language.
func groupNumber(n int) string {
	s := strconv.Itoa(n)
	sign := ""
	if strings.HasPrefix(s, "-") {
		sign, s = "-", s[1:]
	}
	var b strings.Builder
	for i, digit := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(digit)
	}
	return sign + b.String()
}

// abbreviateHome writes a path in the home directory with a leading ~.
func abbreviateHome(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if path == home {
		return "~"
	}
	if rest, ok := strings.CutPrefix(path, home+string(filepath.Separator)); ok {
		return "~" + string(filepath.Separator) + rest
	}
	return path
}
