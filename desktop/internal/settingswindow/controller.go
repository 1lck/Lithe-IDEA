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
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/app"
)

// PluginState is what the plugin page shows about one plugin.
type PluginState struct {
	// Installed says a version of the plugin is on disk.
	Installed bool
	// Version is the installed version, empty when nothing is installed.
	Version string
	// Enabled says the user turned the plugin on.
	Enabled bool
}

// PluginRuntimeState is a memory-only view of the current native session.
type PluginRuntimeState struct {
	Running         bool
	RestartRequired bool
	Restarting      bool
	Version         string
	Workspace       string
}

// Values are the settings the window edits. A field is the value that is stored, so the
// empty string is the one that follows the system.
type Values struct {
	// MarketplaceQuery is the text the marketplace search starts with when the window opens on
	// the plugin page; empty leaves it as it is.
	MarketplaceQuery string
	// Language is a stored i18n language code ("en", "zh-Hans"); empty follows the system.
	Language string
	// Theme is "light" or "dark"; empty follows the system's look.
	Theme string
	// MarketplaceWidth is a layout preference, applied on completed resize, not a draft setting.
	MarketplaceWidth float32
	// EditorTabRows is TabRowsMultiple when an editor group's tabs wrap onto more rows; empty
	// keeps them in one row. EditorTabOverflow says what one row does with tabs that do not
	// fit: TabOverflowSqueeze makes them narrower, and empty scrolls them sideways.
	EditorTabRows     string
	EditorTabOverflow string
	// EditorTabLimit is the most file tabs open at once, 0 for no limit; EditorTabPolicy
	// is "" to close the least recently used tab past it, TabPolicyOldest the oldest.
	EditorTabLimit  int
	EditorTabPolicy string
	// TerminalShell is the executable path of the shell a new terminal runs; empty is
	// automatic, the system's default shell. A path no installed shell has is kept as stored
	// and shown as not found, not replaced by one that exists.
	TerminalShell string
	// TerminalScrollback is the history lines a new terminal keeps, within
	// MinScrollback and MaxScrollback.
	TerminalScrollback int
	// Fonts are the fonts of the editor, the terminal and the run output, as
	// fontprefs.Normalize returns them. Nil is fontprefs.Default, the system's fixed-pitch
	// font for every place.
	Fonts []fontprefs.Font
	// HideGitGutter hides the Git change markers of the editor gutter, which show by default.
	// InlineGitBlame shows the blame of the caret line after its text, and is off by default.
	HideGitGutter  bool
	InlineGitBlame bool
	// HideChangeLists and HideParentReferences hide the local ChangeLists and the option that
	// updates the parent repositories' references in the Commit window; both show by default.
	HideChangeLists      bool
	HideParentReferences bool
	// HideProjectColors leaves the open project's color out of the workbench's chrome,
	// which shows it by default.
	HideProjectColors bool
	// ProjectOpenDestination is where a project opened while another is open goes:
	// ProjectOpenThisWindow, ProjectOpenNewWindow, or empty to ask each time.
	ProjectOpenDestination string
	// DisableSemanticHighlight keeps the syntax colors alone; semantic coloring is on by default.
	DisableSemanticHighlight bool
	// VimMode turns on the Vim keys of the editor (Normal, Insert and Visual modes); off by default.
	VimMode bool
	// DisableAutoSave stops saving changed files a moment after typing stops; auto-save is
	// on by default.
	DisableAutoSave bool
	// ProcessTermination is the Process Termination page's part of Core's termination
	// settings; the zero value keeps Core's defaults.
	ProcessTermination ProcessTermination
	// SteppingFilters are the user's stepping policies by debug adapter ID. An adapter
	// without an entry uses the defaults its plugin declares.
	SteppingFilters map[string]core.DebugSteppingFilters
	// Keymap is the user's changes to the keys of the shortcut catalog; nil keeps every
	// default.
	Keymap shortcuts.Overrides
	// AutoCheckUpdates has Lithe check for a newer version when it starts, at most daily.
	AutoCheckUpdates bool
	// Network is the proxy settings of the application's own HTTP traffic.
	Network NetworkSettings
}

// SteppingAdapter is an installed debug adapter that takes stepping filters: its ID, the
// name the page shows and the defaults its plugin declares.
type SteppingAdapter struct {
	ID       string
	Name     string
	Defaults core.DebugSteppingFilters
}

// ProcessTermination is the part of Core's process termination settings this client
// applies. Its JSON is a subset of Core's TerminationSettings, so the owner passes it to
// processLifecycle.resolve as it is; an empty or nil field is left out and Core's default
// applies. Agent tasks, background services, the startup sweep and the stop time are not
// here because this client does not act on them yet.
type ProcessTermination struct {
	// RunServicesOnExit is RunServicesTerminate to stop Run sessions without asking when
	// their project closes or Lithe quits; empty asks.
	RunServicesOnExit string `json:"runServicesOnExit,omitempty"`
	// TerminalOnQuit is TerminalsTerminate to end busy terminals without asking when Lithe
	// quits; empty asks.
	TerminalOnQuit string `json:"terminalOnQuit,omitempty"`
	// ConfirmTerminalTabClose false closes a busy terminal tab, and the terminals of a
	// closing project, without asking; nil asks.
	ConfirmTerminalTabClose *bool `json:"confirmTerminalTabClose,omitempty"`
}

// The stored values of ProcessTermination besides the empty ones, which ask. They are
// Core's own names.
const (
	RunServicesTerminate = "terminate"
	TerminalsTerminate   = "terminate"
)

// The stored values of Values.EditorTabRows and Values.EditorTabOverflow besides the empty
// ones, which are the defaults: one row that scrolls.
const (
	TabRowsMultiple    = "multiple"
	TabOverflowSqueeze = "squeeze"
)

// ToolchainLoader reads and writes the toolchain facts the Build settings page
// shows. Both calls run off the window thread.
type ToolchainLoader interface {
	Load(context.Context) (toolchain.Snapshot, error)
	Save(context.Context, toolchain.Snapshot, []toolchain.Edit) (toolchain.Snapshot, error)
}

// PluginSettingsLoader reads and publishes captured native sources off the UI thread.
type PluginSettingsLoader interface {
	Load(context.Context, string) (pluginservice.SettingsEditor, error)
	Save(context.Context, pluginservice.SettingsEditor, string, []core.PluginSettingEdit) (pluginsettings.SaveResult, error)
}

// PluginSettingsActionLoader executes explicit declared actions without saving drafts.
type PluginSettingsActionLoader interface {
	Action(context.Context, pluginservice.SettingsEditor, string, bool) (pluginservice.SettingsActionResult, error)
}

// Options configure the settings window.
type Options struct {
	// GitHub is the account the Version Control page shows and drives; nil hides the card.
	GitHub             *GitHubAccount
	SettingsError      func(error)
	SettingsPages      func(context.Context) ([]core.SettingsPage, error)
	SettingsNavigation func(context.Context, []core.SettingsNavigationItem, string) ([]core.SettingsNavigationRow, error)
	// Marketplace fetches the enabled source only while the plugin page is open.
	Marketplace func(context.Context) (marketplace.Snapshot, error)
	// MarketplaceOfficial fetches the separately validated official source.
	MarketplaceOfficial func(context.Context) (marketplace.Snapshot, error)
	// MarketplaceInstalled reads only local installed metadata, without a network request.
	MarketplaceInstalled func(context.Context) (marketplace.Snapshot, error)
	// MarketplaceSources are the custom index URLs read when the page opens; FetchMarketplaceSource reads one
	// of them, and SetMarketplaceSources stores the list after the user adds or removes one.
	MarketplaceSources     []string
	FetchMarketplaceSource func(context.Context, string) (marketplace.Snapshot, error)
	SetMarketplaceSources  func([]string)
	MarketplaceRank        func(context.Context, string, []core.RankCandidate) ([]int, error)
	// MarketplaceError must be safe from a worker: a cancelled request may fail
	// after the window has discarded its result.
	MarketplaceError    func(error)
	MarketplaceRejected func(int)
	// MarketplaceResized persists a completed splitter gesture or keyboard step.
	MarketplaceResized func(float32)
	// PluginState reports what the plugin page shows about one plugin. It is read
	// while painting, so it must answer from memory rather than from disk. Nil
	// treats every plugin as not installed and hides the plugin actions.
	PluginState func(id string) PluginState
	// InstallPlugin starts an installation for the selected plugin. It runs on the
	// settings window's thread and must hand the work to its owner.
	InstallPlugin func(plugin core.MarketplacePlugin)
	// SetPluginEnabled turns an installed plugin on or off.
	SetPluginEnabled func(id string, enabled bool)
	// PluginFacts reports what an installed plugin's manifest declares: the permissions it asks for
	// and the contributions it makes. It is read while painting, so it answers from memory.
	PluginFacts func(id string) PluginFacts
	// LanguageServerState reports the state of a plugin's running language server: its state
	// name, or "" when none runs. It is read while painting on the window's thread.
	LanguageServerState func(pluginID string) string
	// UninstallPlugin removes the installed version of a plugin.
	UninstallPlugin func(id string)
	// InstallPluginFromFile installs a plugin package the user picked on disk. The
	// package is reviewed like a marketplace one before anything is written.
	InstallPluginFromFile func(path string)
	Language              func() i18n.Language
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
	// SetTabRows and SetTabOverflow hand a change of Values.EditorTabRows and
	// Values.EditorTabOverflow to the settings owner in the same way.
	SetTabRows     func(string)
	SetTabOverflow func(string)
	// SetTabLimit hands a change of Values.EditorTabLimit or EditorTabPolicy to the
	// settings owner.
	SetTabLimit func(limit int, policy string)
	// TerminalShells lists the installed shells for the Terminal page and names the
	// program automatic runs (localshell.InstalledShells and localshell.DefaultShell).
	// It runs off the window thread. Nil leaves the page unavailable.
	TerminalShells func() (shells []localshell.Choice, automatic string)
	// SetTerminalShell hands a change of Values.TerminalShell to the settings owner,
	// like SetTabRows.
	SetTerminalShell func(string)
	// SetTerminalScrollback hands a change of Values.TerminalScrollback to the settings
	// owner, like SetTabRows.
	SetTerminalScrollback func(int)
	// SetFonts hands a change of Values.Fonts to the settings owner, like SetTabRows. The
	// list it receives is normalized.
	SetFonts func([]fontprefs.Font)
	// MonospaceFamilies lists the installed fixed-pitch font families for the Fonts page,
	// sorted as the page should show them. It runs off the window thread. Nil shows only
	// the system's default font and the families already stored.
	MonospaceFamilies func() []string
	// SetHideGitGutter and SetInlineGitBlame hand a change of Values.HideGitGutter and
	// Values.InlineGitBlame to the settings owner, like SetTabRows.
	SetHideGitGutter  func(bool)
	SetInlineGitBlame func(bool)
	// SetHideChangeLists and SetHideParentReferences hand a change of Values.HideChangeLists and
	// Values.HideParentReferences to the settings owner, like SetHideGitGutter.
	SetHideChangeLists      func(bool)
	SetHideParentReferences func(bool)
	// SetProcessTermination hands a change of Values.ProcessTermination to the settings
	// owner, like SetTabRows.
	SetProcessTermination func(ProcessTermination)
	// SetKeymap hands a change of Values.Keymap to the settings owner, like SetTabRows.
	SetKeymap func(shortcuts.Overrides)
	// SetNetwork hands the Network page's applied settings to the settings owner, with the
	// password to store: nil keeps the stored one and an empty string removes it. Nil
	// leaves the page unavailable.
	SetNetwork func(NetworkSettings, *string)
	// CheckNetwork sends one request through the Network page's unsaved draft, with the
	// password as SetNetwork takes it, the way the application's requests would go under it.
	// It runs off the window thread and returns once ctx ends. Nil hides the check.
	CheckNetwork func(ctx context.Context, draft NetworkSettings, password *string) NetworkCheck
	// UpdateStatus reads what the updater is doing; it is safe from the window thread.
	// CheckForUpdates, DownloadUpdate and InstallUpdate start the steps the Updates page
	// offers, without waiting; SetAutoCheckUpdates hands a change of
	// Values.AutoCheckUpdates to the owner. A nil UpdateStatus leaves the page unavailable.
	UpdateStatus        func() UpdateStatus
	CheckForUpdates     func()
	DownloadUpdate      func()
	InstallUpdate       func()
	SetAutoCheckUpdates func(bool)
	// OpenURL opens an HTTPS page in the system browser.
	OpenURL func(string)
	// SetHideProjectColors hands a change of Values.HideProjectColors to the settings
	// owner, like SetHideGitGutter.
	SetHideProjectColors func(bool)
	// SetProjectOpenDestination hands a change of Values.ProjectOpenDestination to the
	// settings owner.
	SetProjectOpenDestination func(string)
	// SteppingAdapters lists the installed debug adapters that take stepping filters, for
	// the Build page; NormalizeSteppingFilters has Core check and tidy a policy before it
	// is stored. Both run off the window thread. SetSteppingFilters hands a change to the
	// settings owner: nil removes the adapter's entry, so its declared defaults apply.
	SteppingAdapters         func(context.Context) ([]SteppingAdapter, error)
	NormalizeSteppingFilters func(context.Context, string, core.DebugSteppingFilters) (core.DebugSteppingFilters, error)
	SetSteppingFilters       func(string, *core.DebugSteppingFilters)
	// SetDisableSemanticHighlight hands a change of Values.DisableSemanticHighlight to the
	// settings owner, like SetHideGitGutter.
	SetDisableSemanticHighlight func(bool)
	// SetVimMode hands a change of Values.VimMode to the settings owner, like
	// SetDisableSemanticHighlight.
	SetVimMode func(bool)
	// SetDisableAutoSave hands a change of Values.DisableAutoSave to the settings owner.
	SetDisableAutoSave func(bool)
	// ResetLayout puts the workbench's buttons back where the catalog puts them. It runs
	// at once, on the settings window's thread, when the user presses the button, because
	// pressing it is its own confirmation.
	ResetLayout func()
	// Toolchains is the Build settings page's loader. Nil leaves the page unavailable.
	Toolchains     ToolchainLoader
	PluginSettings PluginSettingsLoader
	// AIGeneration reads the commit and inline-edit generation choices and SetAIGeneration
	// saves them; they are Lithe's own preferences (ai_generation.go).
	AIGeneration    func() AIGenerationSettings
	SetAIGeneration func(AIGenerationSettings)
	// AIProviders reads the Codex and Claude providers generation would use, off the window
	// thread; nil leaves the source lines out.
	AIProviders func(context.Context) []AIProviderStatus
	// IDEAPI is the IDE Connection page's loader. Nil leaves the page unavailable.
	IDEAPI        IDEAPILoader
	PluginRuntime func(string) PluginRuntimeState
	RestartPlugin func(id, version, scope, workspace string)
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
	return c.open(application, current, noPage)
}

// OpenPlugins opens the plugin page, including when a settings window is already open.
func (c *Controller) OpenPlugins(application *app.Application, current Values) error {
	return c.open(application, current, pagePlugins)
}

// OpenPluginsWithQuery shows the plugin page with the marketplace search set to query, which
// is what "Find in Marketplace" asks for; an open window takes the query too.
func (c *Controller) OpenPluginsWithQuery(application *app.Application, current Values, query string) error {
	current.MarketplaceQuery = query
	return c.openWithQuery(application, current, pagePlugins, query)
}

// OpenTerminal opens the Terminal page under Tools, including when a settings window is
// already open: that window switches to the page and is raised, keeping its other values.
func (c *Controller) OpenTerminal(application *app.Application, current Values) error {
	return c.open(application, current, pageTerminal)
}

// OpenKeymap shows the window on the Keymap page, where the gear menu's Keymap item leads.
func (c *Controller) OpenKeymap(application *app.Application, current Values) error {
	return c.open(application, current, pageKeymap)
}

// OpenAI shows the window on the Generation page, where the commit area's settings button leads.
func (c *Controller) OpenAI(application *app.Application, current Values) error {
	return c.open(application, current, pageAIGeneration)
}

// open shows the window on page, or, with noPage, on the page it already has or starts on.
func (c *Controller) open(application *app.Application, current Values, page pageID) error {
	return c.openWithQuery(application, current, page, "")
}

// openWithQuery is open that also sets the marketplace search to query when it is not empty.
func (c *Controller) openWithQuery(application *app.Application, current Values, page pageID, query string) error {
	c.mu.Lock()
	if open := c.current; open != nil && open.win != nil && !open.win.Closed() && !open.sess.finished.Load() {
		win := open.win
		if query != "" {
			open.requestQuery(query)
		}
		if page != noPage {
			open.requestPage(page)
		}
		c.mu.Unlock()
		win.Show()
		return nil
	}
	c.mu.Unlock()

	w := newWindow(c, current)
	if page != noPage {
		w.sess.show(page)
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

// PluginRegistryChanged wakes the page after an atomic installed-state update.
// Native discovery remains on the page's bounded worker, never this caller.
func (c *Controller) PluginRegistryChanged() {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != nil {
		c.current.pluginRegistryChanged.Store(true)
		c.current.inv.Invalidate()
	}
}

// PluginSettingsChanged refreshes only clean forms; dirty drafts retain their
// captured baseline and display a conflict until explicitly reloaded.
func (c *Controller) PluginSettingsChanged(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != nil {
		select {
		case c.current.settingsNotices <- id:
		default:
			c.current.settingsChanged.Store(true)
		}
		c.current.inv.Invalidate()
	}
}

// PluginFacts is what an installed plugin's manifest declares, shown in its detail.
type PluginFacts struct {
	// Permissions are the permission names the manifest lists, as the contract spells them.
	Permissions []string
	// Features are the contribution sections the manifest declares, as the contract names them.
	Features []string
}

// The values of Values.ProjectOpenDestination besides asking.
const (
	ProjectOpenThisWindow = "thisWindow"
	ProjectOpenNewWindow  = "newWindow"
)

// projectOpenDestinations are the choices of the setting, asking first.
var projectOpenDestinations = []string{"", ProjectOpenThisWindow, ProjectOpenNewWindow}
