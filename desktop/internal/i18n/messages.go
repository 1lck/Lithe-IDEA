package i18n

// Messages is everything the client shows, grouped by the screen or surface that shows it.
// Every field must be filled in every catalog; the tests check it.
type Messages struct {
	App      AppMessages
	Welcome  WelcomeMessages
	Title    TitleMessages
	Tools    ToolMessages
	Panel    PanelMessages
	Editor   EditorMessages
	Project  ProjectMessages
	Git      GitMessages
	Status   StatusMessages
	Settings SettingsMessages
	Logs     LogMessages
	Errors   ErrorMessages
}

// AppMessages names the application.
type AppMessages struct {
	Name string
	// Version is the version line under the name, for example "Version 0.1.0".
	Version func(version string) string
	// Core is the core library line in the settings, for example "Core 0.1.0".
	Core func(version string) string
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
}

// TitleMessages are the workbench title bar's words.
type TitleMessages struct {
	ProjectMenu    string
	OpenProject    string
	CloseProject   string
	RecentProjects string
	BranchMenu     string
	// NoRepository is the branch button of a project outside Git.
	NoRepository   string
	LocalBranches  string
	RemoteBranches string
	// CheckoutLater explains that the branch list does not switch branches yet.
	CheckoutLater    string
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
}

// ToolMessages name the tool windows on the stripes.
type ToolMessages struct {
	Project       string
	Commit        string
	Structure     string
	Find          string
	Git           string
	Terminal      string
	Problems      string
	Run           string
	Security      string
	Debug         string
	Notifications string
	Assistant     string
	Updates       string
	Background    string
	// DragHint tells assistive technology that a toolbar item can be dragged elsewhere.
	DragHint string
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

// StatusMessages are the status bar's words. Numbers and the caret position are shown
// as they are; these are their labels.
type StatusMessages struct {
	Path          string
	Caret         string
	Writable      string
	ReadOnly      string
	LSPNotStarted string
	Memory        string
	// MemoryValue is the memory readout, for example "312 MB".
	MemoryValue func(megabytes int) string
	FPS         string
	// FPSValue is the frame rate readout, for example "60 FPS".
	FPSValue  func(fps int) string
	NoChanges string
	Changes   func(count int) string
	Healthy   string
}

// SettingsMessages are the settings dialog's words.
type SettingsMessages struct {
	Title       string
	Description string
	Language    string
	Theme       string
	// FollowSystem names the choice that follows the system, with what it currently
	// resolves to (a language's own name, or the Light or Dark word).
	FollowSystem func(effective string) string
	Light        string
	Dark         string
	Layout       string
	LayoutHint   string
	ResetLayout  string
	About        string
	Done         string
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
}
