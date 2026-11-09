// Package settingswindow is the desktop client's settings window: an operating system
// window of its own, laid out like the settings dialog of an IDE and like the macOS
// client's, with a sidebar of pages that can be searched and the page itself beside it.
//
// Appearance and language apply when selected; closing the window does not undo them.
// The package knows nothing of the workbench: the workbench gives it the settings in force
// and callbacks for individual changes.
package settingswindow

import (
	"context"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/vivaui/viva/app"
)

// Values are the settings the window edits. A field is the value that is stored, so the
// empty string is the one that follows the system.
type Values struct {
	// Language is a stored i18n language code ("en", "zh-Hans"); empty follows the system.
	Language string
	// Theme is "light" or "dark"; empty follows the system's look.
	Theme string
	// MarketplaceWidth is a layout preference, applied on completed resize, not a draft setting.
	MarketplaceWidth float32
}

// Options configure the settings window.
type Options struct {
	// Marketplace fetches the enabled source only while the plugin page is open.
	Marketplace func(context.Context) (marketplace.Snapshot, error)
	// MarketplaceOfficial fetches the separately validated official source.
	MarketplaceOfficial func(context.Context) (marketplace.Snapshot, error)
	MarketplaceRank     func(context.Context, string, []core.RankCandidate) ([]int, error)
	// MarketplaceError must be safe from a worker: a cancelled request may fail
	// after the window has discarded its result.
	MarketplaceError    func(error)
	MarketplaceRejected func(int)
	// MarketplaceResized persists a completed splitter gesture or keyboard step.
	MarketplaceResized func(float32)
	Language           func() i18n.Language
	// Text is the interface language the window paints; nil is English. It is read at
	// every paint, so the window changes language when the language does.
	Text func() *i18n.Messages
	// Dark says whether the client is painted dark now; nil is light. The window uses it
	// for the look "follow the system" resolves to when SystemDark is nil.
	Dark func() bool
	// SystemDark says whether the system is set to a dark look, which is what the choice
	// "follow the system" shows and how the window following the system is painted.
	// Dark cannot stand in for it once the user has picked a look of their own, because
	// then Dark reports that pick and not the system. Nil falls back to Dark.
	SystemDark func() bool
	// SystemLanguage is the language the system asks for, which the choice "follow the
	// system" resolves to and names.
	SystemLanguage i18n.Language
	// Version is the application's version, shown on the About card.
	Version string
	// SetLanguage and SetTheme run on the settings window's thread and must hand their
	// individual changes to the settings owner without waiting for its window thread.
	SetLanguage func(string)
	SetTheme    func(string)
	// ResetLayout puts the workbench's buttons back where the catalog puts them. It runs
	// at once, on the settings window's thread, when the user presses the button, because
	// pressing it is its own confirmation.
	ResetLayout func()
}

// Controller opens the settings window and keeps at most one open: opening it again brings
// the open one to the front and keeps its current page and values.
type Controller struct {
	opts Options

	// mu guards current: Open runs on the window thread of the window that asks, and
	// OnClosed on the settings window's.
	mu      sync.Mutex
	current *window
}

// NewController returns a controller with no window open.
func NewController(opts Options) *Controller {
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

// dark says whether the client is painted dark now.
func (c *Controller) dark() bool {
	return c.opts.Dark != nil && c.opts.Dark()
}

// systemDark says whether the system is set to a dark look.
func (c *Controller) systemDark() bool {
	if c.opts.SystemDark != nil {
		return c.opts.SystemDark()
	}
	return c.dark()
}

// Open shows the settings window, opening it when none is open. A new window starts its
// values from current, the settings in force; one that is already open is raised with its
// values and page untouched, and current is ignored. It must run on a window thread of
// application, as app.Application.OpenWindow requires.
func (c *Controller) Open(application *app.Application, current Values) error {
	return c.open(application, current, false)
}

// OpenPlugins opens the plugin page, including when a settings window is already open.
func (c *Controller) OpenPlugins(application *app.Application, current Values) error {
	return c.open(application, current, true)
}

func (c *Controller) open(application *app.Application, current Values, plugins bool) error {
	c.mu.Lock()
	if open := c.current; open != nil && open.win != nil && !open.win.Closed() && !open.sess.finished.Load() {
		win := open.win
		if plugins {
			open.requestPlugins.Store(true)
			open.inv.Invalidate()
		}
		c.mu.Unlock()
		win.Show()
		return nil
	}
	c.mu.Unlock()

	w := newWindow(c, current)
	if plugins {
		w.sess.page = pagePlugins
	}
	win, err := application.OpenWindow(w.config(), nil)
	if err != nil {
		return err
	}
	c.mu.Lock()
	w.win = win
	c.current = w
	c.mu.Unlock()
	// A window that follows the system is painted in the system's look, so it
	// repaints when the system switches.
	w.watchSystem()
	return nil
}

// Close closes the open window, if any, without undoing settings. It is safe from any
// goroutine.
func (c *Controller) Close() {
	c.mu.Lock()
	current := c.current
	c.mu.Unlock()
	if current != nil && current.win != nil {
		current.win.Close()
	}
}

// Invalidate repaints the open settings window after shared application state changes.
func (c *Controller) Invalidate() {
	c.mu.Lock()
	current := c.current
	c.mu.Unlock()
	if current != nil {
		current.inv.Invalidate()
	}
}
