// Package legacyimport reads the preferences and recent projects an earlier Lithe client
// left on this machine, for an import the user starts. The Viva client is a separate
// product installed beside that client, which is still used: this package only reads its
// data, never writes, moves or deletes it, and the caller decides what to keep.
//
// Sources, read-only:
//   - macOS: the user defaults domain app.lithe.desktop, through `defaults export`, which
//     reads them as the earlier client sees them without touching the file, and the
//     installation records under Application Support/Lithe/Plugins.
//   - Windows: %APPDATA%\app.lithe.windows\settings.json, the Tauri store, and the
//     installation records under %LOCALAPPDATA%\app.lithe.windows\plugins. Its recent
//     folders live in the WebView's localStorage and are not read.
//
// Not imported: the custom log directory, since sharing it with the earlier client mixes
// two products' logs; keyboard shortcuts, sessions, local history and shelves, which the
// Viva client does not store yet; and plugin secrets, which have their own import.
package legacyimport

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"strings"
)

// Font is an editor or terminal font the earlier client used. An empty Family is its
// default family; Size is in points.
type Font struct {
	Family string
	Size   float32
}

// Recent is one recent project: its root and when it was last opened, in Unix
// milliseconds.
type Recent struct {
	Path     string
	OpenedAt int64
}

// ProcessTermination is the earlier client's process termination choices in the Viva
// client's values: "terminate" or empty (ask), and whether closing a busy terminal tab
// asks.
type ProcessTermination struct {
	RunServicesOnExit       string
	TerminalOnQuit          string
	ConfirmTerminalTabClose bool
}

// Found is what an earlier client stored, mapped onto the Viva client's settings. A nil
// field was not stored, or held a value the Viva client has no equivalent for.
type Found struct {
	// Source names where it was read: the defaults domain or the settings file.
	Source string
	// Language is an i18n code ("en", "zh-Hans").
	Language *string
	// Theme is "" (follow the system), "light" or "dark".
	Theme       *string
	HideMinimap *bool
	// EditorTabRows is "multiple" when tabs wrap onto more rows, and "" for one row.
	EditorTabRows *string
	// TerminalShell is the shell's executable path, "" for the system's default.
	TerminalShell      *string
	ProcessTermination *ProcessTermination
	EditorFont         *Font
	TerminalFont       *Font
	Recent             []Recent
	// Plugins are the plugins the earlier client had installed, by ID.
	Plugins []Plugin
}

// Empty says nothing was found to import.
func (f Found) Empty() bool {
	return f.Language == nil && f.Theme == nil && f.HideMinimap == nil && f.EditorTabRows == nil && f.TerminalShell == nil &&
		f.ProcessTermination == nil && f.EditorFont == nil && f.TerminalFont == nil && len(f.Recent) == 0 && len(f.Plugins) == 0
}

// ErrNotFound says this machine has no earlier client's preferences.
var ErrNotFound = errors.New("no earlier Lithe preferences were found")

// Read reads the earlier client's preferences on this platform. It returns ErrNotFound
// when there are none, and never changes them.
func Read(ctx context.Context) (Found, error) {
	return read(ctx)
}

// maxRecent bounds the recent projects taken from a source; the earlier clients kept a
// few dozen.
const maxRecent = 200

// appleReferenceDate is 2001-01-01 UTC in Unix seconds, the origin Foundation's
// JSONEncoder writes a Date relative to.
const appleReferenceDate = 978307200

// fromDefaults maps the earlier macOS client's user defaults.
func fromDefaults(values map[string]any) Found {
	found := Found{Source: macDomain}
	if code, ok := values["settings.language"].(string); ok && (code == "en" || code == "zh-Hans") {
		found.Language = &code
	}
	if theme, ok := values["settings.themePreference"].(string); ok {
		found.Theme = themeFrom(theme, "system", "light", "dark")
	}
	if shown, ok := values["settings.editorMinimap"].(bool); ok {
		hidden := !shown
		found.HideMinimap = &hidden
	}
	if layout, ok := values["settings.editorTabLayoutMode"].(string); ok {
		found.EditorTabRows = tabRows(layout)
	}
	found.TerminalShell = macShell(values)
	if data, ok := values["settings.processTermination"].([]byte); ok {
		found.ProcessTermination = processTermination(data)
	}
	family, _ := values["settings.editorFontFamily"].(string)
	if size, ok := number(values["settings.editorFontSize"]); ok {
		found.EditorFont = font(family, size)
	} else if family != "" {
		found.EditorFont = font(family, 0)
	}
	if data, ok := values["lithe.recent-projects"].([]byte); ok {
		found.Recent = macRecent(data)
	}
	return found
}

// themeFrom maps a theme preference the source spells system, light and dark; an empty
// spelling is never matched.
func themeFrom(value, system, light, dark string) *string {
	var theme string
	switch {
	case value == "":
		return nil
	case value == system:
		theme = ""
	case value == light:
		theme = "light"
	case value == dark:
		theme = "dark"
	default:
		return nil
	}
	return &theme
}

func tabRows(layout string) *string {
	var rows string
	switch layout {
	case "singleLine":
	case "multipleRows":
		rows = "multiple"
	default:
		return nil
	}
	return &rows
}

// macShell maps the shell choice: a path override wins, then zsh and bash at their
// system paths, and "system" is the default shell.
func macShell(values map[string]any) *string {
	if path, ok := values["settings.terminalShellPathOverride"].(string); ok && strings.TrimSpace(path) != "" {
		path = strings.TrimSpace(path)
		return &path
	}
	choice, ok := values["settings.terminalShell"].(string)
	if !ok {
		return nil
	}
	var shell string
	switch choice {
	case "system":
	case "zsh":
		shell = "/bin/zsh"
	case "bash":
		shell = "/bin/bash"
	default:
		return nil
	}
	return &shell
}

// processTermination maps the JSON the macOS client stored for its Process Termination
// page. Fields it did not store keep their defaults, which ask.
func processTermination(data []byte) *ProcessTermination {
	var stored struct {
		TerminalOnQuit          string `json:"terminalOnQuit"`
		ConfirmTerminalTabClose *bool  `json:"confirmTerminalTabClose"`
		RunServicesOnExit       string `json:"runServicesOnExit"`
	}
	if json.Unmarshal(data, &stored) != nil {
		return nil
	}
	value := ProcessTermination{ConfirmTerminalTabClose: true}
	if stored.TerminalOnQuit == "terminate" {
		value.TerminalOnQuit = "terminate"
	}
	if stored.RunServicesOnExit == "terminate" {
		value.RunServicesOnExit = "terminate"
	}
	if stored.ConfirmTerminalTabClose != nil {
		value.ConfirmTerminalTabClose = *stored.ConfirmTerminalTabClose
	}
	return &value
}

// macRecent maps the JSON list of {path, lastOpened}, lastOpened in seconds since 2001.
func macRecent(data []byte) []Recent {
	var stored []struct {
		Path       string  `json:"path"`
		LastOpened float64 `json:"lastOpened"`
	}
	if json.Unmarshal(data, &stored) != nil {
		return nil
	}
	recent := make([]Recent, 0, min(len(stored), maxRecent))
	for _, entry := range stored {
		if len(recent) == maxRecent {
			break
		}
		if entry.Path == "" || math.IsNaN(entry.LastOpened) || math.IsInf(entry.LastOpened, 0) {
			continue
		}
		opened := int64(math.Round((entry.LastOpened + appleReferenceDate) * 1000))
		recent = append(recent, Recent{Path: entry.Path, OpenedAt: max(opened, 0)})
	}
	return recent
}

// fromTauriSettings maps the earlier Windows client's settings store, whose top-level
// keys are its settings.
func fromTauriSettings(source string, values map[string]json.RawMessage) Found {
	found := Found{Source: source}
	text := func(key string) (string, bool) {
		var value string
		raw, ok := values[key]
		return value, ok && json.Unmarshal(raw, &value) == nil
	}
	flag := func(key string) (bool, bool) {
		var value bool
		raw, ok := values[key]
		return value, ok && json.Unmarshal(raw, &value) == nil
	}
	size := func(key string) (float64, bool) {
		var value float64
		raw, ok := values[key]
		return value, ok && json.Unmarshal(raw, &value) == nil
	}
	if language, ok := text("displayLanguage"); ok {
		code := map[string]string{"en-US": "en", "zh-CN": "zh-Hans"}[language]
		if code != "" {
			found.Language = &code
		}
	}
	if follow, ok := flag("syncSystemTheme"); ok && follow {
		system := ""
		found.Theme = &system
	} else if theme, ok := text("theme"); ok {
		found.Theme = themeFrom(theme, "", "lithe-light", "lithe-dark")
	}
	if shown, ok := flag("showMinimap"); ok {
		hidden := !shown
		found.HideMinimap = &hidden
	}
	if layout, ok := text("editorTabLayoutMode"); ok {
		found.EditorTabRows = tabRows(layout)
	}
	if policy, ok := text("runServicesOnExit"); ok && (policy == "ask" || policy == "terminate") {
		value := ProcessTermination{ConfirmTerminalTabClose: true}
		if policy == "terminate" {
			value.RunServicesOnExit = "terminate"
		}
		found.ProcessTermination = &value
	}
	family, _ := text("fontFamily")
	if points, ok := size("fontSize"); ok {
		found.EditorFont = font(family, points)
	}
	terminalFamily, _ := text("terminalFontFamily")
	if points, ok := size("terminalFontSize"); ok {
		found.TerminalFont = font(terminalFamily, points)
	}
	return found
}

// font keeps the first family of a CSS-style list, unquoted, and a usable size.
func font(family string, size float64) *Font {
	family, _, _ = strings.Cut(family, ",")
	family = strings.Trim(strings.TrimSpace(family), `"'`)
	if size <= 0 || math.IsNaN(size) || size > 200 {
		size = 0
	}
	if family == "" && size == 0 {
		return nil
	}
	return &Font{Family: family, Size: float32(size)}
}

// number reads a plist integer or real.
func number(value any) (float64, bool) {
	switch v := value.(type) {
	case int64:
		return float64(v), true
	case float64:
		return v, true
	}
	return 0, false
}
