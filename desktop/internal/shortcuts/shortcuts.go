// Package shortcuts is the workbench's one catalog of bindable actions and the user's
// changes to their keys. The window dispatches, Find Action shows and the Keymap
// settings page edits the same effective bindings, so what a page shows is what a key
// press runs.
//
// An action is named by a stable ID that the settings file stores; its title and
// group change with the language and never reach the file. A binding is a Viva
// keymap.Chord, stored as "meta+shift+o" so the file holds the modifiers the user
// pressed on this machine, not a display string.
package shortcuts

import (
	"runtime"
	"slices"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/keymap"
)

// Group is the area an action belongs to in the Keymap page and Find Action.
type Group int

const (
	GroupApp Group = iota
	GroupView
	GroupProject
	GroupSearch
	GroupEditor
	GroupGit
	GroupRun
	GroupTerminal
	// GroupToolWindows holds the plugin commands that open a tool window.
	GroupToolWindows
)

// Title is the group's name in the language of messages.
func (g Group) Title(messages *i18n.Messages) string {
	t := &messages.Commands
	switch g {
	case GroupApp:
		return t.GroupApp
	case GroupView:
		return t.GroupView
	case GroupProject:
		return t.GroupProject
	case GroupSearch:
		return t.GroupSearch
	case GroupEditor:
		return messages.Keymap.GroupEditor
	case GroupGit:
		return t.GroupGit
	case GroupRun:
		return t.GroupRun
	case GroupTerminal:
		return t.GroupTerminal
	default:
		return t.GroupToolWindows
	}
}

// Action is one entry of the catalog.
type Action struct {
	// ID is what the settings file stores; it never changes once released.
	ID    string
	Group Group
	// Title is the action's name in the language of messages.
	Title func(*i18n.Messages) string
	// Defaults are the chords the action has while the user changed nothing.
	Defaults []keymap.Chord
}

// chord is a catalog default; it panics on a chord that cannot be bound, which is a
// mistake in the catalog itself.
func chord(modifiers gfx.Modifiers, key string) keymap.Chord {
	c, ok := keymap.Parse(modifiers, key)
	if !ok {
		panic("shortcuts: invalid default chord " + key)
	}
	return c
}

func chords(list ...keymap.Chord) []keymap.Chord { return list }

// The occurrence commands follow IntelliJ IDEA: Control-G, Control-Shift-G and Control-Command-G on macOS,
// Alt-J, Alt-Shift-J and Control-Alt-Shift-J elsewhere. Clone Caret has no default chord, as in IDEA.
func addNextOccurrenceDefault() keymap.Chord {
	if runtime.GOOS == "darwin" {
		return chord(gfx.ModifierControl, "g")
	}
	return chord(gfx.ModifierAlt, "j")
}

func unselectOccurrenceDefault() keymap.Chord {
	if runtime.GOOS == "darwin" {
		return chord(gfx.ModifierControl|gfx.ModifierShift, "g")
	}
	return chord(gfx.ModifierAlt|gfx.ModifierShift, "j")
}

func selectAllOccurrencesDefault() keymap.Chord {
	if runtime.GOOS == "darwin" {
		return chord(gfx.ModifierControl|gfx.ModifierMeta, "g")
	}
	return chord(gfx.ModifierControl|gfx.ModifierAlt|gfx.ModifierShift, "j")
}

// navigateDefault is Go to Line: Command-L on macOS, Control-G elsewhere.
func navigateDefault() keymap.Chord {
	if runtime.GOOS == "darwin" {
		return chord(keymap.Primary, "l")
	}
	return chord(gfx.ModifierControl, "g")
}

// fullscreenDefault is Toggle Full Screen: Control-Command-F on macOS, F11 elsewhere.
func fullscreenDefault() keymap.Chord {
	if runtime.GOOS == "darwin" {
		return chord(gfx.ModifierControl|gfx.ModifierMeta, "f")
	}
	return chord(0, "f11")
}

// closeTabDefaults is Close Tab: Command-W on macOS. Other platforms give it no chord; a user
// binds one on the Keymap page.
func closeTabDefaults() []keymap.Chord {
	if runtime.GOOS == "darwin" {
		return chords(chord(keymap.Primary, "w"))
	}
	return nil
}

// IDs of the actions the window treats specially when their keys are pressed.
const (
	FindAction = "search.findAction"
	InlineEdit = "editor.inlineEdit"
	GoToLine   = "navigate.gotoLine"
	// CloseTab closes the selected tab where the keys are: the focused terminal's, else the one
	// the editor group shows.
	CloseTab = "tab.close"
	// OpenSelected opens the selected entry of the project tree or the search results. Those
	// lists bind it on their own elements, so it acts only while the focus is in one of them.
	OpenSelected = "workspace.openSelected"
)

// Catalog is every action a user can bind, in the order the Keymap page lists them.
var Catalog = []Action{
	{ID: "settings.open", Group: GroupApp, Title: func(m *i18n.Messages) string { return m.Commands.Settings }, Defaults: chords(chord(keymap.Primary, ","))},
	{ID: "plugins.open", Group: GroupApp, Title: func(m *i18n.Messages) string { return m.Commands.Plugins }},
	{ID: "logs.open", Group: GroupApp, Title: func(m *i18n.Messages) string { return m.Commands.Logs }, Defaults: chords(chord(keymap.Primary|gfx.ModifierShift, "l"))},
	{ID: "legacy.import", Group: GroupApp, Title: func(m *i18n.Messages) string { return m.Commands.ImportLegacy }},
	{ID: "theme.system", Group: GroupView, Title: func(m *i18n.Messages) string { return m.Commands.ThemeSystem }},
	{ID: "theme.light", Group: GroupView, Title: func(m *i18n.Messages) string { return m.Commands.ThemeLight }},
	{ID: "theme.dark", Group: GroupView, Title: func(m *i18n.Messages) string { return m.Commands.ThemeDark }},
	{ID: "window.fullscreen", Group: GroupView, Title: func(m *i18n.Messages) string { return m.Keymap.ToggleFullscreen }, Defaults: chords(fullscreenDefault())},
	{ID: "language.en", Group: GroupView, Title: func(m *i18n.Messages) string { return m.Commands.LanguageEnglish }},
	{ID: "language.zh", Group: GroupView, Title: func(m *i18n.Messages) string { return m.Commands.LanguageChinese }},
	{ID: "project.open", Group: GroupProject, Title: func(m *i18n.Messages) string { return m.Commands.OpenProject }, Defaults: chords(chord(keymap.Primary, "o"))},
	{ID: "project.new", Group: GroupProject, Title: func(m *i18n.Messages) string { return m.Commands.NewProject }},
	{ID: "project.clone", Group: GroupProject, Title: func(m *i18n.Messages) string { return m.Commands.Clone }},
	{ID: "project.close", Group: GroupProject, Title: func(m *i18n.Messages) string { return m.Commands.CloseProject }},
	{ID: CloseTab, Group: GroupProject, Title: func(m *i18n.Messages) string { return m.Editor.CloseTab }, Defaults: closeTabDefaults()},
	{ID: "documents.saveAll", Group: GroupProject, Title: func(m *i18n.Messages) string { return m.Commands.SaveAll }},
	{ID: OpenSelected, Group: GroupProject, Title: func(m *i18n.Messages) string { return m.Keymap.OpenSelected }, Defaults: chords(chord(0, "f4"))},
	{ID: "localHistory.show", Group: GroupProject, Title: func(m *i18n.Messages) string { return m.History.Show }},
	{ID: "search.everywhere", Group: GroupSearch, Title: func(m *i18n.Messages) string { return m.Commands.SearchEverywhere }, Defaults: chords(chord(keymap.Primary|gfx.ModifierShift, "o"))},
	{ID: FindAction, Group: GroupSearch, Title: func(m *i18n.Messages) string { return m.Commands.FindAction }, Defaults: chords(chord(keymap.Primary|gfx.ModifierShift, "a"))},
	{ID: "search.files", Group: GroupSearch, Title: func(m *i18n.Messages) string { return m.Commands.FindInFiles }, Defaults: chords(chord(keymap.Primary|gfx.ModifierShift, "f"))},
	{ID: "search.replace", Group: GroupSearch, Title: func(m *i18n.Messages) string { return m.Commands.ReplaceInFiles }},
	{ID: "editor.newScratch", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.NewScratch }, Defaults: chords(chord(keymap.Primary, "n"))},
	{ID: "editor.scratchFiles", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.ScratchFiles }},
	{ID: "editor.recentFiles", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.RecentFiles }, Defaults: chords(chord(keymap.Primary, "e"))},
	{ID: "editor.recentEdits", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.RecentEdits }, Defaults: chords(chord(keymap.Primary|gfx.ModifierShift, "e"))},
	{ID: "editor.saveAs", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.SaveAs }, Defaults: chords(chord(keymap.Primary|gfx.ModifierShift, "s"))},
	{ID: "editor.find", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.Find }, Defaults: chords(chord(keymap.Primary, "f"))},
	{ID: "editor.replace", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.Replace }, Defaults: chords(chord(keymap.Primary, "r"))},

	{ID: "editor.fold", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.Fold }, Defaults: chords(chord(keymap.Primary, "-"))},
	{ID: "editor.unfold", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.Unfold }, Defaults: chords(chord(keymap.Primary, "="))},
	{ID: "editor.foldAll", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.FoldAll }, Defaults: chords(chord(keymap.Primary|gfx.ModifierShift, "-"))},
	{ID: "editor.unfoldAll", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.UnfoldAll }, Defaults: chords(chord(keymap.Primary|gfx.ModifierShift, "="))},
	{ID: "editor.vimMode", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.ToggleVim }},
	{ID: "editor.addNextOccurrence", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.AddNextOccurrence }, Defaults: chords(addNextOccurrenceDefault())},
	{ID: "editor.unselectOccurrence", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.UnselectOccurrence }, Defaults: chords(unselectOccurrenceDefault())},
	{ID: "editor.selectAllOccurrences", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.SelectAllOccurrences }, Defaults: chords(selectAllOccurrencesDefault())},
	{ID: "editor.cloneCaretAbove", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.CloneCaretAbove }},
	{ID: "editor.cloneCaretBelow", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.CloneCaretBelow }},
	{ID: "git.gutter.next", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.GitNextChange }, Defaults: chords(chord(gfx.ModifierControl|gfx.ModifierAlt|gfx.ModifierShift, "down"))},
	{ID: "git.gutter.previous", Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Commands.GitPreviousChange }, Defaults: chords(chord(gfx.ModifierControl|gfx.ModifierAlt|gfx.ModifierShift, "up"))},
	{ID: GoToLine, Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Keymap.GoToLine }, Defaults: chords(navigateDefault())},
	{ID: InlineEdit, Group: GroupEditor, Title: func(m *i18n.Messages) string { return m.Keymap.InlineEdit }, Defaults: chords(chord(keymap.Primary, "k"))},
	{ID: "git.commit", Group: GroupGit, Title: func(m *i18n.Messages) string { return m.Commands.Commit }},
	{ID: "git.commitPush", Group: GroupGit, Title: func(m *i18n.Messages) string { return m.Commands.CommitAndPush }},
	{ID: "git.branches", Group: GroupGit, Title: func(m *i18n.Messages) string { return m.Commands.Branches }},
	{ID: "git.console", Group: GroupGit, Title: func(m *i18n.Messages) string { return m.Commands.GitConsole }},
	{ID: "run.selected", Group: GroupRun, Title: func(m *i18n.Messages) string { return m.Commands.Run }},
	{ID: "debug.start", Group: GroupRun, Title: func(m *i18n.Messages) string { return m.Commands.Debug }},
	{ID: "debug.toggleBreakpoint", Group: GroupRun, Title: func(m *i18n.Messages) string { return m.Commands.ToggleBreakpoint }},
	{ID: "terminal.new", Group: GroupTerminal, Title: func(m *i18n.Messages) string { return m.Commands.NewTerminal }},
}

// pluginActions are the plugin commands the window offers now, appended to the catalog. The window
// thread sets them when the plugins change; the settings window reads them.
var (
	pluginMu      sync.RWMutex
	pluginActions []Action
)

// SetPluginActions replaces the plugin commands bindable as shortcuts. Their IDs must be unique and
// never collide with a catalog ID.
func SetPluginActions(actions []Action) {
	pluginMu.Lock()
	defer pluginMu.Unlock()
	pluginActions = append([]Action(nil), actions...)
}

// All is the catalog followed by the plugin commands offered now.
func All() []Action {
	pluginMu.RLock()
	defer pluginMu.RUnlock()
	all := make([]Action, 0, len(Catalog)+len(pluginActions))
	all = append(all, Catalog...)
	return append(all, pluginActions...)
}

// Find is the catalog action with id, plugin commands included.
func Find(id string) (Action, bool) {
	for _, action := range All() {
		if action.ID == id {
			return action, true
		}
	}
	return Action{}, false
}

// Overrides are the user's changes, by action ID: a list replaces the action's
// defaults, an empty list unbinds it, and an absent entry keeps its defaults. They are
// stored as written by Encode.
type Overrides map[string][]string

// Bindable reports whether chord may be bound: a character needs Command, Control or
// Alt, so plain typing never runs an action; a named key such as F5 may stand alone.
func Bindable(c keymap.Chord) bool {
	if !c.Valid() {
		return false
	}
	if c.Char != 0 && c.Modifiers&(gfx.ModifierMeta|gfx.ModifierControl|gfx.ModifierAlt) == 0 {
		return false
	}
	return true
}

var modifierNames = []struct {
	modifier gfx.Modifiers
	name     string
}{
	{gfx.ModifierControl, "ctrl"},
	{gfx.ModifierAlt, "alt"},
	{gfx.ModifierShift, "shift"},
	{gfx.ModifierMeta, "meta"},
}

// Encode is how the settings file keeps a chord: its modifiers then its key name,
// joined by "+" ("meta+shift+o", "f5"). The key "+" itself ends the text.
func Encode(c keymap.Chord) string {
	var parts []string
	for _, m := range modifierNames {
		if c.Modifiers&m.modifier != 0 {
			parts = append(parts, m.name)
		}
	}
	return strings.Join(append(parts, c.Name()), "+")
}

// Decode reads what Encode wrote; ok is false for text that is not a bindable chord.
func Decode(text string) (keymap.Chord, bool) {
	var modifiers gfx.Modifiers
	for {
		index := strings.IndexByte(text, '+')
		if index <= 0 || index == len(text)-1 {
			break
		}
		name := text[:index]
		found := false
		for _, m := range modifierNames {
			if m.name == name {
				modifiers |= m.modifier
				found = true
			}
		}
		if !found {
			return keymap.Chord{}, false
		}
		text = text[index+1:]
	}
	c, ok := keymap.Parse(modifiers, text)
	if !ok || !Bindable(c) {
		return keymap.Chord{}, false
	}
	return c, true
}

// Effective are the chords action runs on, after the user's changes. A stored list
// whose entries cannot be read keeps only the ones that can.
func (o Overrides) Effective(action Action) []keymap.Chord {
	stored, changed := o[action.ID]
	if !changed {
		return action.Defaults
	}
	var out []keymap.Chord
	for _, text := range stored {
		if c, ok := Decode(text); ok && !slices.Contains(out, c) {
			out = append(out, c)
		}
	}
	return out
}

// Changed reports whether the user changed the action's keys.
func (o Overrides) Changed(id string) bool {
	_, changed := o[id]
	return changed
}

// Owner is the action, other than except, that chord runs now; ok is false when none does.
func (o Overrides) Owner(c keymap.Chord, except string) (Action, bool) {
	for _, action := range All() {
		if action.ID != except && slices.Contains(o.Effective(action), c) {
			return action, true
		}
	}
	return Action{}, false
}

// With is a copy of o in which action id runs on chords; the entry is removed when the
// chords are the defaults again.
func (o Overrides) With(id string, list []keymap.Chord) Overrides {
	out := make(Overrides, len(o)+1)
	for key, value := range o {
		out[key] = value
	}
	if action, ok := Find(id); ok && slices.Equal(action.Defaults, list) {
		delete(out, id)
		return out
	}
	stored := make([]string, 0, len(list))
	for _, c := range list {
		stored = append(stored, Encode(c))
	}
	out[id] = stored
	return out
}

// Without is a copy of o in which action id has its defaults again.
func (o Overrides) Without(id string) Overrides {
	out := make(Overrides, len(o))
	for key, value := range o {
		if key != id {
			out[key] = value
		}
	}
	return out
}

// Normalize drops entries of unknown actions and chords that cannot be read, so a
// damaged settings file costs only its damaged entries. An empty list stays: it is a
// deliberate unbinding.
func Normalize(o Overrides) Overrides {
	if len(o) == 0 {
		return nil
	}
	out := make(Overrides, len(o))
	for id, stored := range o {
		action, ok := Find(id)
		if !ok {
			continue
		}
		list := Overrides{id: stored}.Effective(action)
		texts := make([]string, 0, len(list))
		for _, c := range list {
			texts = append(texts, Encode(c))
		}
		out[id] = texts
	}
	return out
}

// Keycaps is a chord as a menu writes it on this platform: "⌘⇧O" on macOS, "Ctrl+Shift+O"
// elsewhere.
func Keycaps(c keymap.Chord) string {
	caps := c.Keycaps(nil)
	if runtime.GOOS == "darwin" {
		return strings.Join(caps, "")
	}
	return strings.Join(caps, "+")
}

// Label is an action's keys as Find Action and the Keymap page show them: each chord's
// keycaps, separated by commas; empty when the action has none.
func (o Overrides) Label(id string) string {
	action, ok := Find(id)
	if !ok {
		return ""
	}
	list := o.Effective(action)
	parts := make([]string, 0, len(list))
	for _, c := range list {
		parts = append(parts, Keycaps(c))
	}
	return strings.Join(parts, ", ")
}
