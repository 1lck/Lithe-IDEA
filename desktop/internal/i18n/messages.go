package i18n

// Messages is everything the client shows, grouped by the screen or surface that shows it.
// Every field must be filled in every catalog; the tests check it.
type Messages struct {
	App       AppMessages
	Welcome   WelcomeMessages
	Title     TitleMessages
	Window    WindowMessages
	Tools     ToolMessages
	Dock      DockMessages
	Panel     PanelMessages
	Editor    EditorMessages
	Project   ProjectMessages
	Git       GitMessages
	Commit    CommitMessages
	Branch    BranchMessages
	Terminal  TerminalMessages
	Status    StatusMessages
	Settings  SettingsMessages
	Logs      LogMessages
	Errors    ErrorMessages
	Build     BuildMessages
	Tests     TestMessages
	Debug     DebugMessages
	Run       RunMessages
	AI        AIMessages
	IDEAPI    IDEAPIMessages
	Sync      SyncMessages
	Worktrees WorktreeMessages
	Console   ConsoleMessages
	Search    SearchMessages
	History   HistoryMessages
	Keymap    KeymapMessages
	Updates   UpdatesMessages
	Commands  CommandMessages
}

// AppMessages names the application.
type AppMessages struct {
	Name string
	// Version is the version line under the name, for example "Version 0.1.0".
	Version func(version string) string
	// Core is the core library line in the settings, for example "Core 0.1.0".
	Core func(version string) string
	// DevBadge is the mark a development build puts on the application's Dock icon.
	DevBadge string
}

// WelcomeMessages are the start screen's words.
type WelcomeMessages struct {
	Projects          string
	Settings          string
	SearchLabel       string
	SearchPlaceholder string
	NewProject        string
	Open              string
	OpenDialogTitle   string
	Clone             string
	Remote            string
	// Unavailable explains a button the new desktop client does not offer yet.
	Unavailable string
	EmptyTitle  string
	EmptyHint   string
	NoMatches   string
	MoreActions string
	MenuOpen    string
	// MenuReveal shows the folder in the system file manager.
	MenuReveal string
	MenuPin    string
	MenuUnpin  string
	MenuRemove string
	Pinned     string
	// Missing marks a recent project whose folder no longer exists.
	Missing string
	// DropFolderOnly says that a dropped item was not a folder, so nothing opened.
	DropFolderOnly string
}

// WindowMessages names the minimize, maximize, restore and close buttons that Viva draws
// in the title bar on Windows and Linux. Assistive technology reads them.
type WindowMessages struct {
	Minimize string
	Maximize string
	Restore  string
	Close    string
}

// TitleMessages are the workbench title bar's words.
type TitleMessages struct {
	ProjectMenu      string
	OpenProject      string
	CloseProject     string
	RecentProjects   string
	BranchMenu       string
	RunConfiguration string
	CurrentFile      string
	Run              string
	Debug            string
	Search           string
	Settings         string
	// RunLater explains that running needs a build provider that is not connected yet.
	RunLater string
	// The settings button's menu.
	Preferences        string
	Plugins            string
	LogsAndDiagnostics string
	ThemeMenu          string
	Keymap             string
	// PluginsLater and KeymapLater explain menu items whose pages are not built yet.
	PluginsLater string
	KeymapLater  string
	// LogsUnavailable says the client started without its log, so there is nothing to show.
	LogsUnavailable string
	// The project menu: its actions, its two lists and their empty state.
	NewProjectItem   string
	OpenItem         string
	CloneItem        string
	OpenProjects     string
	NoRecentProjects string
}

// ToolMessages name the tool windows on the stripes.
type ToolMessages struct {
	Project         string
	Commit          string
	Structure       string
	Find            string
	Git             string
	Terminal        string
	Problems        string
	References      string
	MarkdownPreview string
	Run             string
	Build           string
	Tests           string
	Security        string
	Debug           string
	Notifications   string
	Updates         string
	Background      string
	// DragHint tells assistive technology that a toolbar item can be dragged elsewhere.
	DragHint string
}

// DockMessages are the titles shown in a tool window's detached drop preview.
type DockMessages struct {
	MoveLeftTop     string
	MoveLeftBottom  string
	MoveBottomLeft  string
	MoveRightTop    string
	MoveRightBottom string
	MoveBottomRight string
}

// PanelMessages are the words every tool window shares.
type PanelMessages struct {
	Hide string
	// Placeholder is the body of a tool window that is not connected yet.
	Placeholder string
	// Resize names the splitters that resize the tool windows and panes.
	Resize string
}

// EditorMessages are the empty editor's hints.
type EditorMessages struct {
	SearchEverywhere string
	GoToFile         string
	FindInFiles      string
	RecentFiles      string
	DropFiles        string
	// CloseTab names the close button of a file's tab.
	CloseTab string
	// SoftWrap names the button at the end of the tab bar that wraps long lines at the
	// editor's width instead of scrolling them sideways.
	SoftWrap string
	// VimNormal, VimInsert, VimReplace, VimVisual and VimVisualLine name the Vim modes in the
	// status bar and the editor's status text.
	VimNormal, VimInsert, VimReplace, VimVisual, VimVisualLine string
	// VimUnknown and VimNotFound say a Vim command line is unknown and a pattern has no match.
	VimUnknown, VimNotFound func(string) string
	// HiddenTabs names the button at the end of a tab strip that lists the tabs scrolled or
	// squeezed out of view.
	HiddenTabs string
	// Minimap names the small picture of the file down the editor's right side, and
	// HideMinimap and ShowMinimap the button beside it that hides it, and shows it again, in
	// every editor.
	Minimap     string
	HideMinimap string
	ShowMinimap string
	// VerticalScrollbar and HorizontalScrollbar name the editor's scrollbars.
	VerticalScrollbar   string
	HorizontalScrollbar string
	// OpenFailed and SaveFailed say a file could not be read or written, and why.
	OpenFailed func(name, reason string) string
	SaveFailed func(name, reason string) string
	// NotText says a file is not text the editor can show: it holds binary data.
	NotText string
	// TooLarge says a file is larger than the editor opens.
	TooLarge string
}

// ProjectMessages are the project tree's words.
type ProjectMessages struct {
	Loading string
	Empty   string
	Failed  func(reason string) string
}

// GitMessages are the Git tool window's words: its tabs, the log tab's reference pane,
// commit list and details, and the failures it reports.
type GitMessages struct {
	Log       string
	Worktrees string
	Console   string
	// Repositories name the repository the log walks, and the way back to the project's own.
	Repositories GitRepositoryMessages
	// LogTab is the log tab while the log shows one reference, for example "Log: main".
	LogTab        func(reference string) string
	AllReferences string
	ShowAll       string
	Actions       string
	FetchAll      string
	FetchOptions  string
	UpdateBranch  string
	RefreshLog    string
	ShowChanges   string

	// The reference pane: its action stripe, search field, sections and empty state.
	Branches             string
	HideBranches         string
	ShowBranches         string
	NewBranch            string
	DeleteBranch         string
	CompareWorkingTree   string
	CompareWithCurrent   string
	FindBranch           string
	Fetch                string
	LocateBranch         string
	BranchSettings       string
	ExpandAll            string
	CollapseAll          string
	BranchSearch         string
	HeadRow              string
	LocalGroup           string
	RemoteGroup          string
	TagGroup             string
	NoMatchingReferences string

	// The commit list's toolbar, filters and their popovers.
	TextOrHash      string
	FilterBranch    string
	FilterUser      string
	FilterDate      string
	FilterPaths     string
	ClearFilter     string
	CompareBranch   string
	ShowDetails     string
	Decorations     string
	FindInLog       string
	LongEdges       string
	PathTitle       string
	PathPlaceholder string
	Clear           string
	Cancel          string
	Apply           string
	SearchUsers     string
	NoMatchingUsers string
	AnyTime         string
	Today           string
	Yesterday       string
	Last7Days       string
	Last30Days      string
	// OlderOutside says a date filter only looks at the history loaded so far.
	OlderOutside string
	// FilterValue is a filter chip that applies a value, for example "User: Ann".
	FilterValue func(filter, value string) string

	// The commit list's states and footer.
	Loading        string
	NotRepository  string
	NoCommits      string
	NoMatches      string
	LoadMore       string
	LoadingCommits string
	LoadMoreFailed string

	// The changed files and the commit details.
	SelectCommit   string
	LoadingFiles   string
	FilesFailed    string
	Retry          string
	NoChangedFiles string
	CommitDetails  string
	CompareChanges string
	FileHistory    string
	// On joins the author to the date in the commit details, for example "on 2026/11/07 10:00".
	On func(date string) string

	Failed func(reason string) string
}

// CommitMessages are the Commit tool window's words: its change list, its commit area, the
// review that confirms a commit before it runs, and the notices they report.
type CommitMessages struct {
	// The toolbar and the change list.
	Refresh    string
	StageAll   string
	UnstageAll string
	ChangeList string
	// Files counts the changes of the change list, for example "3 files".
	Files func(count int) string
	// StageFile and UnstageFile name the checkbox of a change by what a click does, for
	// example "Stage src/main.go".
	StageFile   func(path string) string
	UnstageFile func(path string) string
	// StagedState, PartlyStagedState and UnstagedState follow each change in the list. A
	// change is partly staged when it has changes both in the index and in the worktree.
	StagedState       string
	PartlyStagedState string
	UnstagedState     string
	Clean             string

	// The commit area.
	Amend string
	// The commit options: the sign-off and the author the next commit records.
	Options           string
	SignOff           string
	SignOffHelp       string
	Author            string
	AuthorPlaceholder string
	AuthorHelp        string
	AuthorInvalid     string
	// Staged counts the staged changes, for example "2 staged".
	Staged             func(count int) string
	MessageLabel       string
	MessagePlaceholder string
	Commit             string
	CommitAndPush      string
	Committing         string
	// Result is one repository's line in the results, for example "lithe: Push failed".
	Result  func(repository, status string) string
	Dismiss string
	Retry   string

	// The review: its titles, notes, steps and buttons.
	ReviewTitle     string
	ReviewPushTitle string
	ReviewRetry     string
	Order           string
	// MessageLine repeats the commit message, for example "Commit message: Fix the build".
	MessageLine func(message string) string
	AmendNote   string
	// AuthorLine names the author the commits record, for example "Author: Ada <ada@example.org>".
	AuthorLine  func(author string) string
	SignOffNote string
	// Step is one repository of the plan, for example "1. Commit and push: lithe".
	Step         func(n int, action, repository string) string
	StepCommit   string
	StepPush     string
	StepPushOnly string
	// Where joins a repository's branch and commit, for example "main · 1a2b3c4d5e".
	Where        func(branch, head string) string
	DetachedHead string
	NoCommits    string
	// TracksDifferent asks where to push a branch whose upstream has another name.
	TracksDifferent func(local, upstream string) string
	PublishTo       func(remote, branch string) string
	PushTo          func(upstream string) string
	Continue        string
	Cancel          string

	// Where each repository stands, by the kernel's status keys.
	Pending              string
	NotIncluded          string
	Committed            string
	CommittedPushPending string
	CommittedAndPushed   string
	CommitFailed         string
	HeadAdvanced         string
	OutcomeUnknown       string
	PushFailed           string
	ReviewRequired       string
	WaitingForSubmodule  string

	// The notices.
	EnterMessage   string
	ChooseTarget   string
	PlanChanged    string
	Done           string
	Pushed         string
	NeedsAttention string
	StageFailed    func(reason string) string
	UnstageFailed  func(reason string) string
	Failed         func(reason string) string
}

// BranchMessages are the words of the branch popup the title bar's branch opens: its search,
// its actions and lists, the menu of one branch, the dialogs that create, rename, check out
// and delete, and the notices they report.
type BranchMessages struct {
	// Popup is the accessible name of the popup, and Search the placeholder of its field.
	Popup  string
	Search string
	// The actions at the top of the popup.
	NewBranch        string
	CheckoutRevision string
	// The sections of the list, and what it shows instead of branches.
	Recent    string
	Local     string
	Remote    string
	Tags      string
	Loading   string
	NoMatches string
	// LoadFailed replaces the list when the references could not be read.
	LoadFailed func(reason string) string
	// Current marks the checked-out branch for assistive technology.
	Current string
	// RowMenu is the accessible name of one branch's menu, for example "main actions".
	RowMenu func(name string) string

	// The menu of one branch.
	NewBranchFrom func(name string) string
	Checkout      string
	Rename        string
	Delete        string

	// The dialogs that create and rename a branch.
	NewBranchTitle string
	CreateFrom     func(name string) string
	BranchName     string
	CheckoutAfter  string
	Create         string
	RenameTitle    string
	RenameFrom     func(name string) string
	RenameButton   string
	Cancel         string
	// Why a typed name cannot be used, by the kernel's error codes. NameDirectory's name is
	// the folder of branches it clashes with, and NamePrefix's branch the existing branch
	// the name would be stored below.
	NameEmpty     string
	NameHead      string
	NameRemote    func(name string) string
	NameDirectory func(name string) string
	NameExists    func(name string) string
	NamePrefix    func(name, branch string) string

	// The dialog that checks out a tag or a revision.
	RevisionTitle  string
	RevisionPrompt string
	Revision       string
	DetachedNote   string

	// The dialog that asks what to do with the local changes a checkout would overwrite.
	ConflictTitle  string
	ConflictPrompt func(name string) string
	ConflictHint   string
	SmartCheckout  string
	ForceCheckout  string

	// The dialog that confirms deleting a branch. The kernel deletes a branch whether or not
	// it is merged, so the prompt says what is lost.
	DeleteTitle  string
	DeletePrompt func(name string) string
	DeleteButton string

	// The notices. Deleted names the commit the branch pointed at, so it can be created again.
	AlreadyOn      func(name string) string
	CheckedOut     func(name string) string
	Detached       func(revision string) string
	Created        func(name string) string
	Renamed        func(name string) string
	Deleted        func(name, target string) string
	CheckoutFailed func(reason string) string
	CreateFailed   func(reason string) string
	RenameFailed   func(reason string) string
	DeleteFailed   func(reason string) string
}

// TerminalMessages are the words of the terminal in the Terminal tool window.
type TerminalMessages struct {
	// Label is the accessible name of the grid, and ScrollbarLabel that of its scrollbar.
	Label          string
	ScrollbarLabel string
	// SessionEnded is written into the grid when the shell exits cleanly.
	SessionEnded string
	// SessionEndedStatus is written when the shell exits with a status other than 0.
	SessionEndedStatus func(status int) string
	// RestartHint follows the end of a session: Enter starts a new shell.
	RestartHint string
	// StartFailed is written when the shell cannot be started.
	StartFailed func(reason string) string
	// Tab is the title of the n-th terminal of a project, counted from 1: "Local",
	// "Local (2)" and so on.
	Tab      func(n int) string
	NewTab   string
	CloseTab string
	// NoTerminals is the Terminal tool window when every terminal was moved to the editor.
	NoTerminals string
	// Find and the rest name the terminal's Find bar; FindCount is "3 of 12".
	Find, FindNone, FindPrevious, FindNext, FindClose string
	FindCount                                         func(current, total string) string
	// OpenLinkFailed tells that a clicked link could not be opened.
	OpenLinkFailed func(reason string) string
	// ShellMenu is the accessible name of the button beside NewTab that lists the
	// installed shells. DetectingShells and NoShells stand in that list while it is being
	// made and when it found none. ShellWithPath names an installation whose name another
	// one shares, for example "bash (/opt/homebrew/bin/bash)". Settings is the list's last
	// entry, which opens the terminal's settings.
	ShellMenu       string
	DetectingShells string
	NoShells        string
	ShellWithPath   func(name, path string) string
	Settings        string
}

// StatusMessages are the status bar's words. Numbers and the caret position are shown
// as they are; these are their labels.
type StatusMessages struct {
	Path          string
	Caret         string
	Writable      string
	ReadOnly      string
	LSPNotStarted string
	// Vim is the status item of the Vim mode's name, shown while the Vim keys are on and no
	// document shows its own mode.
	Vim string
	// Encoding names the status bar item that shows the file's text encoding.
	Encoding string
	// Problems is how many problems the language servers reported, for example
	// "3 problems". One problem has its own wording.
	Problems func(count int) string
	Memory   string
	// MemoryValue is the memory readout, for example "312 MB".
	MemoryValue func(megabytes int) string
	FPS         string
	// FPSValue is the frame rate readout, for example "60 FPS".
	FPSValue  func(fps int) string
	NoChanges string
	Changes   func(count int) string
	Healthy   string
	// Indent is the status item of the editor's indentation: spaces per level, or the tab width
	// when Tab inserts a tab. Clicking it switches between the two.
	Indent       string
	IndentSpaces func(count int) string
	IndentTab    func(width int) string
	// LineEnding is the status item of the file's line break; LineEndingLF and LineEndingCRLF
	// name its two values.
	LineEnding     string
	LineEndingLF   string
	LineEndingCRLF string
}

// SettingsMessages are the settings window's words.
type SettingsMessages struct {
	AIGeneration string
	Title        string
	// Search is the sidebar's search field; NoMatches is the sidebar when it finds no page.
	Search    string
	NoMatches string
	// Categories names the sidebar's tree of pages for assistive technology.
	Categories string

	// The sidebar's groups and the pages under them.
	AppearanceBehavior string
	General            string
	Updates            string
	Network            string
	Editor             string
	Fonts              string
	Keymap             string
	ProcessTermination string
	Plugins            string
	VersionControl     string
	Build              string
	Languages          string
	Tools              string
	AI                 string
	IDEAPI             string
	// PageLater is the body of a page the new desktop client does not offer yet.
	PageLater string

	// The General page: its cards and their settings.
	Appearance     string
	AppearanceHelp string
	AppearanceMode string
	// System is the appearance mode that follows the system.
	System string
	// FollowSystem names the language choice that follows the system, with what it
	// currently resolves to (a language's own name).
	FollowSystem func(effective string) string
	Light        string
	Dark         string
	Language     string
	LanguageHelp string
	Workbench    string
	LayoutHint   string
	ResetLayout  string
	About        string

	// The Editor page: the card that lays out the tabs of an editor group. TabsShowIn leads
	// the choice between TabsOneRow, which TabsScroll and TabsSqueeze refine, and
	// TabsMultipleRows.
	EditorTabs     string
	EditorTabsHelp string
	TabsShowIn     string
	TabsOneRow     string
	// The Editor page's semantic highlighting switch, with its card text.
	EditorSemantic     string
	EditorSemanticHelp string
	SemanticHighlight  string
	TabsScroll         string
	TabsSqueeze        string
	TabsMultipleRows   string

	// The Terminal page under Tools: the choice of the shell a new terminal runs.
	// TerminalShellAuto is the choice that follows the system, with the shell it
	// currently runs; TerminalShellMissing is a stored shell no installation has.
	Terminal             string
	TerminalShell        string
	TerminalShellHelp    string
	DetectingShells      string
	NoShells             string
	TerminalShellAuto    func(effective string) string
	ShellWithPath        func(name, path string) string
	TerminalShellMissing func(path string) string

	// The bottom bar.
	RestoreDefaults string
	Cancel          string
	OK              string
}

// LogMessages are the log window's words. Level names (ERROR, WARN, INFO, DEBUG), the
// filter language and the "v2 · UTF-8 · NDJSON" format line are not translated: they are
// what the log files and the filter expressions say.
type LogMessages struct {
	// Logs names the window and its table for assistive technology.
	Logs string

	// The filter field and its syntax errors.
	FilterPlaceholder string
	FilterHelp        string
	// FilterError places a syntax error, for example "Filter error at 3–5: Invalid operator".
	FilterError func(start, end int, reason string) string
	Filter      LogFilterMessages

	// The toolbar and its menus.
	SessionCurrent  string
	SessionPrevious string
	SessionAll      string
	TimeRange       string
	StartTime       string
	EndTime         string
	ClearTimeRange  string
	ReversedTime    string
	// InvalidTime says a time range endpoint is not a time the window reads.
	InvalidTime       string
	TimeHelp          string
	SavedFilters      string
	NoSavedFilters    string
	SaveCurrentFilter string
	NameForFilter     string
	Columns           string
	Export            string
	ExportLabel       string
	CollapseRepeats   string
	AbsoluteTime      string
	RelativePrevious  string
	RelativeSelected  string
	LiveFollow        string
	Paused            string
	FollowHelp        string
	ClearView         string
	ClearViewHelp     string
	Maintenance       string
	RevealDirectory   string
	ChangeDirectory   string
	ChooseDirectory   string
	// LogDirectory stands for the log directory while its path is not known.
	LogDirectory string
	// ClearSearch is the button that empties the filter field.
	ClearSearch      string
	Choose           string
	RestoreDirectory string
	// ClearStorage is the menu item that deletes the collected logs, with the space they use.
	ClearStorage func(size string) string

	// The clear confirmation and the buttons the dialogs share.
	ClearTitle   string
	ClearAction  string
	ClearMessage string
	Cancel       string
	Save         string
	Apply        string
	Delete       string
	Retry        string

	// The table's states and the jump back to live records.
	LoadFailed  string
	ViewCleared string
	NoMatches   string
	NewLogs     func(count int) string

	// The histogram.
	EventsOverTime string
	HistogramHint  string
	// HistogramTooltip describes one bucket: its time and its counts.
	HistogramTooltip func(time string, errors, warnings, other int) string

	// The channel list and the detailed diagnostics card.
	AllChannels       string
	SelectSeveral     string
	ChannelHelp       string
	UnreadErrors      string
	Diagnostics       string
	DiagnosticsHelp   string
	EnableDiagnostics string
	DiagnosticsOn     string
	Category          func(category string) string
	AutoOff           func(remaining string) string
	StopDiagnostics   string

	// The details pane.
	Detail         string
	CallChain      string
	TraceHelp      string
	CopyJSON       string
	CopyMarkdown   string
	FilterChannel  string
	TraceOperation string
	RevealInFinder string
	ExportBundle   string
	RedactedNote   string
	SourceLine     func(line int) string
	NoOperation    string
	// Operation heads the call chain, for example "Op c0ffee · 4 records · 12 ms".
	Operation func(op string, count int, duration string) string

	// The status bar.
	Tailing          string
	PausedScrolledUp string
	// VisibleCount is the row count; the numbers come grouped, for example "1,204".
	VisibleCount  func(visible, total, line string) string
	Dropped       func(count int) string
	WriteFailures func(count int) string

	// The table's column titles, folded runs and context menu.
	Time                  string
	Level                 string
	Channel               string
	Event                 string
	Message               string
	Fields                string
	Repeated              func(count int, last string) string
	CopyLine              string
	CopySelectionMarkdown string
	ShowOnlyEvent         string
	HideEvent             string
	ShowOnlyChannel       string
	TraceThisOperation    string
	CopyFieldValue        string

	// ExportDialog is the sheet that packs logs into a diagnostic bundle. Its title is
	// ExportLabel; its Cancel, Retry and Reveal in Finder buttons and the All channels choice
	// are the window's.
	ExportDialog LogExportMessages
}

// LogExportMessages are the export sheet's words.
type LogExportMessages struct {
	Subtitle string
	// Range, Channels, Privacy and Contents head the sheet's sections.
	Range              string
	CurrentSession     string
	RecentSessions     string
	RecentSessionsHint string
	Last24Hours        string
	Channels           string
	CurrentFilter      string
	Privacy            string
	RedactionNote      string
	Environment        string
	// EnvironmentHint lists what the environment summary holds; osName is the system's
	// name, such as macOS.
	EnvironmentHint func(osName string) string
	Contents        string
	Packing         string
	// SavedTo reports where the bundle was written.
	SavedTo func(path string) string
	// Size is the footer's estimate, for example "≈ 1.2 MB · 4 files".
	Size          func(size string, count int) string
	Export        string
	PrepareFailed string
	ExportFailed  string
}

// LogFilterMessages explain the kernel's filter syntax error codes.
type LogFilterMessages struct {
	EmptyValue        string
	ExpressionTooLong string
	InvalidEscape     string
	InvalidLevel      string
	InvalidOperator   string
	InvalidQuote      string
	InvalidRegex      string
	RegexTooLong      string
	UnterminatedQuote string
	UnterminatedRegex string
}

// ErrorMessages wrap failures the client reports in its notice banner.
type ErrorMessages struct {
	Dismiss       string
	FolderMissing func(path string) string
	OpenFailed    func(reason string) string
	Core          func(reason string) string
	SaveFailed    func(reason string) string
	// LogsFailed is a log window that could not be opened.
	LogsFailed func(reason string) string
	// SettingsFailed is a settings window that could not be opened.
	SettingsFailed func(reason string) string
}
