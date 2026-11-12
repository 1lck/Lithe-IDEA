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
	"github.com/1lck/Lithe-IDEA/desktop/internal/uistyle"
	"github.com/1lck/Lithe-IDEA/desktop/internal/windowcontrols"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
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

	w := newWindow(c, nil)
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

const (
	// titleHeight is the height of the window's title bar.
	titleHeight = 28
	// sidebarWidth is the width of the channel list.
	sidebarWidth = 212
	// The details pane takes detailsShare of the body at first and the user can drag the
	// splitter above it. The table keeps at least tableMin of the body, the details
	// detailsMin.
	detailsShare = 0.36
	detailsMin   = 130
	tableMin     = 100
	// statusHeight is the height of the status bar.
	statusHeight = 24
	// pulsePeriod is a full cycle of the following pulse, which dims and brightens again.
	pulsePeriod = 1400 * time.Millisecond
)

// window is one open log window. Everything in it runs on its window thread.
type window struct {
	ctrl  *Controller
	model *Model
	win   *app.Window
	inv   app.Invalidator
	page  *ui.Page
	pal   palette
	theme ui.Theme
	// background is the color the page fills the window with, which follows the palette.
	background ui.Color
	text       *i18n.Messages

	// started says the model was started, in the window's first paint.
	started bool

	// filterText is what the filter field shows and filterRevision the model's
	// expressionRevision it was set from: an expression the model changed (a composed term,
	// an applied bookmark) replaces the text, and typing becomes the expression.
	filterText     string
	filterRevision int
	// focusFilter asks the filter field, declared later in the paint, to take the focus (⌘F).
	focusFilter bool

	// The toolbar's menus and the time range editor, whether each is open, and the texts
	// of the editor's fields. rangeSeeded says the fields were filled for the editor that is
	// open, so typing in them is not overwritten; usedLoaded says the size of the log
	// directory was measured for the maintenance menu that is open.
	menus                   toolbarMenus
	rangeStart, rangeEnd    string
	rangeSeeded, usedLoaded bool
	clearOpen, bookmarkOpen bool
	bookmarkName            string

	// split is the divider between the table and the details.
	split ui.SplitterState

	table     tableState
	sidebar   sidebarState
	histogram histogramState
	details   detailsState
}

// toolbarMenus say which of the toolbar's menus is open.
type toolbarMenus struct {
	session, timeRange, saved, columns, maintenance bool
}

// newWindow returns a window of c over model, which Open sets once the options are complete.
func newWindow(c *Controller, model *Model) *window {
	w := &window{ctrl: c, model: model, filterRevision: -1}
	w.split = ui.SplitterState{Pos: 400, Ratio: 1 - detailsShare}
	w.table.init(w)
	w.histogram.init(w)
	w.sidebar.init()
	return w
}

// config is the native window's configuration: the page paints it and takes its input.
func (w *window) config() app.Config {
	w.look()
	w.page = ui.NewPage(ui.PageConfig{
		View:        w.view,
		Theme:       &w.theme,
		Background:  &w.background,
		Invalidator: &w.inv,
		BarStyle:    uistyle.Bars,
	})
	config := w.page.Config(app.Config{
		Title:          w.ctrl.text().Logs.Logs,
		Icon:           appicon.Window(),
		Width:          1100,
		Height:         720,
		MinWidth:       900,
		MinHeight:      500,
		WindowMode:     app.WindowCustomTitlebar,
		TitlebarHeight: titleHeight,
		WindowControls: func() app.WindowControlsStyle { return windowcontrols.Style(w.pal.tx, w.ctrl.text()) },
		Invalidator:    &w.inv,
		OnWake:         w.model.drain,
		OnClosed:       w.closed,
	})
	// The language and the appearance can change between two paints: the palette and the
	// theme that follows it are chosen again before the page reads them.
	paint := config.Paint
	config.Paint = func(canvas *gfx.Canvas, size gfx.Size) {
		w.look()
		paint(canvas, size)
	}
	return config
}

// look chooses the language, the palette and the theme the next paint uses.
func (w *window) look() {
	w.text = w.ctrl.text()
	w.pal = lightPalette()
	if w.ctrl.opts.Dark != nil && w.ctrl.opts.Dark() {
		w.pal = darkPalette()
	}
	w.theme = windowTheme(w.pal)
	w.background = w.pal.bg
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
func windowTheme(p palette) ui.Theme {
	theme := ui.LightTheme()
	if p.dark {
		theme = ui.DarkTheme()
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

// view declares the window: the title bar, the toolbar, the errors, the histogram, the
// channel list with the table and the details, the status bar, and over them the dialogs
// and the export sheet.
func (w *window) view(c ui.C) {
	if !w.started {
		w.started = true
		w.model.start()
		w.model.loadUsedBytes()
	}
	w.model.declareQuery(c)
	if ui.Shortcut(c, ui.Primary, "f") {
		w.focusFilter = true
	}
	if ui.Shortcut(c, ui.Primary, "w") {
		w.win.Close()
	}
	ui.Column(c).Fill().Children(func() {
		w.title(c)
		w.toolbar(c)
		w.filterError(c)
		w.loadError(c)
		w.histogramStrip(c)
		w.body(c)
		w.status(c)
	})
	w.dialogs(c)
	w.exportSheet(c)
	if w.model.follows {
		// The pulse in the status bar breathes while the window follows the log.
		c.Canvas().RequestFrameIn(50 * time.Millisecond)
	} else if w.model.diagnosticsLeft() > 0 {
		// The diagnostics card counts down.
		c.Canvas().RequestFrameIn(time.Second)
	}
}

// title is the title bar: the directory of the session the window shows, and the shortcut
// that opens the window at the trailing end. The whole bar moves the window.
func (w *window) title(c ui.C) {
	title := w.text.Logs.Logs
	if w.model.directory != "" {
		title = abbreviateHome(filepath.Join(w.model.directory, w.model.currentSessionPath))
	}
	leading, trailing := app.TitlebarInsets()
	ui.Stack(c).FillWidth().Height(titleHeight).Shrink(0).Background(w.pal.bg3).MovesWindow().Children(func() {
		// The system's window buttons sit at the leading end, so the title keeps clear of
		// them on that side and is centered in what is left.
		ui.Row(c).Fill().PadSides(0, max(60, trailing+60), 0, max(80, leading+10)).Center().Children(func() {
			ui.Text(c, title).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.tx).Ellipsis()
		})
		if w.ctrl.opts.Shortcut != "" {
			ui.Row(c).Absolute().Top(0).Bottom(0).Right(12).Items(ui.Center).Children(func() {
				ui.Row(c).PadX(5).PadY(1).Radius(4).Border(1, w.pal.bd).Children(func() {
					w.mono(c, w.ctrl.opts.Shortcut, 11, w.pal.tx2)
				})
			})
		}
	})
}

// filterError shows the first syntax error of the filter with a caret under the part of
// the expression it is about.
func (w *window) filterError(c ui.C) {
	if len(w.model.diagnostics) == 0 {
		return
	}
	d := w.model.diagnostics[0]
	caret := strings.Repeat(" ", min(128, max(0, d.Start))) + strings.Repeat("^", max(1, min(128, d.End-d.Start)))
	ui.Column(c).FillWidth().Shrink(0).PadX(10).Gap(2).Children(func() {
		w.mono(c, w.text.Logs.FilterError(d.Start, d.End, w.filterReason(d.Code, d.Message)), 12.5, w.pal.red)
		w.mono(c, caret, 11, w.pal.red)
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

// loadError says the logs could not be read and offers to read them again.
func (w *window) loadError(c ui.C) {
	if !w.model.failed {
		return
	}
	ui.Row(c).FillWidth().Shrink(0).PadX(10).PadY(4).Gap(8).Items(ui.Center).Children(func() {
		w.mono(c, w.text.Logs.LoadFailed, 12.5, w.pal.red)
		if ui.Button(c, w.text.Logs.Retry).XSmall().Outline().Clicked() {
			w.model.retry()
		}
	})
}

// body is the channel list beside the table, with the details under the table. ⌘C copies
// the selected records while the keyboard focus is anywhere in it; in the toolbar it is the
// filter field's.
func (w *window) body(c ui.C) {
	body := ui.Row(c).FillWidth().Grow(1).Shrink(1).MinHeight(0)
	body.Children(func() {
		ui.Column(c).Width(sidebarWidth).FillHeight().Shrink(0).Background(w.pal.bg2).Clip().PadSides(8, 0, 0, 0).Children(func() {
			w.sidebarPanel(c)
		})
		ui.Row(c).Width(1).FillHeight().Shrink(0).Background(w.pal.line)
		ui.Column(c).Grow(1).Shrink(1).FillHeight().MinWidth(0).Children(func() {
			ui.Stack(c).FillWidth().Height(w.split.Pos).Shrink(0).Clip().Children(func() {
				w.tablePanel(c)
				if len(w.model.records) == 0 {
					empty := w.text.Logs.NoMatches
					if w.model.cleared {
						empty = w.text.Logs.ViewCleared
					}
					ui.Row(c).Fill().Center().Children(func() {
						w.mono(c, empty, 12.5, w.pal.tx3)
					})
				}
				if !w.model.follows && w.model.newCount > 0 {
					w.newLogs(c)
				}
			})
			ui.Splitter(c, &w.split).Mins(tableMin, detailsMin)
			ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Background(w.pal.bg2).Clip().Children(func() {
				w.detailsPanel(c)
			})
		})
	})
	if body.Shortcut(ui.Primary, "c") {
		w.model.copyFormatted(w.model.selectedRecords(), "json")
	}
}

// newLogs is the capsule at the bottom of the table that says how many records arrived
// while the user looked elsewhere, and jumps to them.
func (w *window) newLogs(c ui.C) {
	ui.Row(c).Fill().Justify(ui.Center).Items(ui.End).PadSides(0, 0, 8, 0).Children(func() {
		label := w.text.Logs.NewLogs(w.model.newCount)
		capsule := ui.ButtonBase(c.Part("new-logs"), label).PadX(14).PadY(4).Radius(999).Background(w.pal.blu).Children(func() {
			w.mono(c, label, 12.5, w.pal.white)
		})
		if capsule.Clicked() {
			w.model.resume()
		}
	})
}

// status is the bar along the bottom: whether the window follows the log, how many rows it
// shows, and the writer's counters.
func (w *window) status(c ui.C) {
	m := w.model
	ui.Row(c).FillWidth().Height(statusHeight).Shrink(0).PadX(10).Gap(16).Items(ui.Center).Background(w.pal.foot).Children(func() {
		ui.Row(c).Gap(5).Items(ui.Center).Children(func() {
			label := w.text.Logs.Paused
			if m.follows {
				ui.Row(c).Size(7, 7).Radius(3.5).Background(w.pal.pulse).Opacity(pulseOpacity(c.Canvas().Now()))
				label = w.text.Logs.Tailing
			} else {
				w.mono(c, "❚❚", 11.5, w.pal.white)
				if m.scrolledUp {
					label = w.text.Logs.PausedScrolledUp
				}
			}
			w.mono(c, label, 11.5, w.pal.white)
		})
		w.mono(c, w.text.Logs.VisibleCount(groupNumber(len(m.displayRows())), groupNumber(m.totalRecords()), strconv.Itoa(m.selectedLine())), 11.5, w.pal.white)
		ui.Spacer(c)
		w.mono(c, w.text.Logs.Dropped(m.discarded+m.dropped), 11.5, w.pal.white)
		w.mono(c, w.text.Logs.WriteFailures(m.writeFailures), 11.5, w.pal.white)
		w.mono(c, "v2 · UTF-8 · NDJSON", 11.5, w.pal.white)
	})
}

// dialogs declares the dialog that is open: the confirmation of clearing the logs, and the
// name of a filter to save.
func (w *window) dialogs(c ui.C) {
	logs := &w.text.Logs
	ui.ModalWith(c, &w.clearOpen, logs.ClearTitle, ui.ModalSpec{Description: logs.ClearMessage, Width: 420}, nil, func() {
		if ui.Button(c, logs.Cancel).Outline().Clicked() {
			w.clearOpen = false
		}
		if ui.Button(c, logs.ClearAction).Destructive().Clicked() {
			w.model.clearLogs()
			w.clearOpen = false
		}
	})
	closed := ui.ModalWith(c, &w.bookmarkOpen, logs.NameForFilter, ui.ModalSpec{Width: 360}, func() {
		field := ui.TextField(c, &w.bookmarkName, logs.NameForFilter, logs.NameForFilter).FillWidth()
		if field.Submitted() {
			w.saveBookmark()
		}
	}, func() {
		if ui.Button(c, logs.Cancel).Outline().Clicked() {
			w.bookmarkOpen = false
		}
		if ui.Button(c, logs.Save).Clicked() {
			w.saveBookmark()
		}
	})
	if closed {
		w.bookmarkName = ""
	}
}

// saveBookmark saves the current filter under the name typed in the dialog and closes it.
func (w *window) saveBookmark() {
	w.model.saveBookmark(w.bookmarkName)
	w.bookmarkName = ""
	w.bookmarkOpen = false
}

// buttonOptions are the variations of one of the window's buttons.
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
// symbol and a title on the window's background with a thin border. name tells it from the
// buttons beside it. It returns the button, for Clicked and as the anchor of a menu it opens.
func (w *window) button(c ui.C, name, symbol, title string, o buttonOptions) ui.Box {
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
	box := ui.ButtonBase(c.Part(name), label).Height(height).Shrink(0).PadX(9).Gap(5).Items(ui.Center).
		Background(w.pal.bg).Radius(6).Border(1, border)
	if o.hint != "" {
		box = box.Tooltip(o.hint)
	}
	if o.fullWidth {
		box = box.FillWidth().Justify(ui.Start)
	}
	if o.disabled {
		box = box.Disabled(true).Opacity(0.45)
	} else {
		box = box.Pressed(ui.Look{}.Background(w.pal.bg3))
	}
	return box.Children(func() {
		if symbol != "" {
			w.mono(c, symbol, 12, color)
		}
		switch {
		case title == "":
		case o.proportional:
			ui.Text(c, title).FontSize(12).Color(color).Ellipsis()
		default:
			w.mono(c, title, 12, color).Ellipsis()
		}
	})
}

// mono declares a line of monospaced text. Viva lays a Mono text out on the cells of its
// fixed-pitch font, two for a wide character such as a Chinese one and none for a combining
// mark, so the text is as wide as it is drawn, and a Wrap of it breaks where its cells fill the
// line.
func (w *window) mono(c ui.C, s string, size float32, color ui.Color) ui.Box {
	return ui.Text(c, s).Mono().FontSize(size).Color(color)
}

// monoWidth is how wide a line of monospaced text at size is drawn.
func monoWidth(canvas *gfx.Canvas, s string, size float32) float32 {
	return canvas.TextWidthStyle(s, gfx.TextStyle{Size: size, Weight: gfx.WeightRegular, Mono: true})
}

// badge declares a small framed key, such as the ⌘F beside the filter.
func (w *window) badge(c ui.C, s string) {
	ui.Row(c).PadX(5).Radius(4).Border(1, w.pal.bd).Shrink(0).Children(func() {
		w.mono(c, s, 11, w.pal.tx2)
	})
}

// info declares the ⓘ that explains a control when the pointer rests on it.
func (w *window) info(c ui.C, hint string) {
	ui.Row(c).Size(18, 18).Shrink(0).Center().Hit(ui.ID(c), hint).Tooltip(hint).Children(func() {
		ui.Icon(c, icons.Info).Size(12, 12).Color(w.pal.tx3)
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
