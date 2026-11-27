package keymapimport

import (
	"encoding/json"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/tailscale/hujson"
)

func parseVSCode(content string) (parsed, error) {
	p := parsed{bindings: make(shortcuts.Overrides)}
	if !boundedJSONDepth(content) {
		return p, ErrDocument
	}
	data, err := hujson.Standardize([]byte(strings.TrimPrefix(content, "\ufeff")))
	if err != nil {
		return p, ErrDocument
	}
	var rules []map[string]json.RawMessage
	if err = json.Unmarshal(data, &rules); err != nil || rules == nil || len(rules) > maxActions {
		return p, ErrDocument
	}
	blocked := make(map[string]bool)
	for _, rule := range rules {
		var command, key string
		if json.Unmarshal(rule["command"], &command) != nil || !validID(command) || json.Unmarshal(rule["key"], &key) != nil {
			return p, ErrDocument
		}
		removal := strings.HasPrefix(command, "-")
		id := vscodeCommand(strings.TrimPrefix(command, "-"))
		if id == "" {
			p.skip(command, "unmapped")
			continue
		}
		reason := ""
		if removal {
			reason = "removal"
		} else if raw, ok := rule["when"]; ok {
			var when string
			if json.Unmarshal(raw, &when) != nil {
				return p, ErrDocument
			}
			if strings.TrimSpace(when) != "" && strings.TrimSpace(when) != "true" {
				reason = "conditional"
			}
		}
		if _, ok := rule["args"]; ok && reason == "" {
			reason = "arguments"
		}
		if len(strings.Fields(key)) > 1 && reason == "" {
			reason = "sequence"
		}
		value, ok := canonical(key)
		if !ok && reason == "" {
			reason = "unsupported_key"
		}
		if reason != "" {
			p.skip(command, reason)
			if !removal {
				blocked[id] = true
			}
			continue
		}
		if !contains(p.bindings[id], value) {
			p.bindings[id] = append(p.bindings[id], value)
		}
		if len(p.bindings[id]) > 8 {
			return p, ErrDocument
		}
	}
	for id := range blocked {
		delete(p.bindings, id)
	}
	return p, nil
}
func contains(keys []string, key string) bool {
	for _, value := range keys {
		if value == key {
			return true
		}
	}
	return false
}

func vscodeCommand(command string) string {
	return map[string]string{
		"workbench.action.openSettings":        "settings.open",
		"workbench.action.files.openFolder":    "project.open",
		"workbench.action.closeFolder":         "project.close",
		"workbench.action.closeActiveEditor":   "tab.close",
		"workbench.action.files.saveAll":       "documents.saveAll",
		"workbench.action.files.saveAs":        "editor.saveAs",
		"workbench.action.showCommands":        "search.findAction",
		"workbench.action.quickOpen":           "search.everywhere",
		"workbench.action.findInFiles":         "search.files",
		"workbench.action.replaceInFiles":      "search.replace",
		"actions.find":                         "editor.find",
		"editor.action.startFindReplaceAction": "editor.replace",
		"workbench.action.gotoLine":            "navigate.gotoLine",
		"editor.fold":                          "editor.fold", "editor.unfold": "editor.unfold",
		"editor.foldAll": "editor.foldAll", "editor.unfoldAll": "editor.unfoldAll",
		"editor.action.addSelectionToNextFindMatch": "editor.addNextOccurrence",
		"editor.action.selectHighlights":            "editor.selectAllOccurrences",
		"editor.action.insertCursorAbove":           "editor.cloneCaretAbove",
		"editor.action.insertCursorBelow":           "editor.cloneCaretBelow",
		"workbench.action.toggleFullScreen":         "window.fullscreen",
		"workbench.action.terminal.new":             "terminal.new",
		"workbench.action.debug.start":              "debug.start",
		"workbench.action.debug.run":                "run.selected",
		"editor.debug.action.toggleBreakpoint":      "debug.toggleBreakpoint",
		"git.commit":                                "git.commit",
		"git.pull":                                  "git.pull",
		"git.push":                                  "git.push",
		"git.fetch":                                 "git.fetch",
	}[command]
}

// Bound nesting before invoking the recursive JSONC parser. This lexical pass
// ignores strings and comments; hujson still owns syntax validation.
func boundedJSONDepth(text string) bool {
	depth := 0
	for i := 0; i < len(text); i++ {
		switch text[i] {
		case '"':
			i++
			for i < len(text) && text[i] != '"' {
				if text[i] == '\\' {
					i++
				}
				i++
			}
		case '/':
			if i+1 < len(text) && text[i+1] == '/' {
				i += 2
				for i < len(text) && text[i] != '\n' {
					i++
				}
			} else if i+1 < len(text) && text[i+1] == '*' {
				i += 2
				for i+1 < len(text) && (text[i] != '*' || text[i+1] != '/') {
					i++
				}
				i++
			}
		case '[', '{':
			depth++
			if depth > 32 {
				return false
			}
		case ']', '}':
			depth--
			if depth < 0 {
				return false
			}
		}
	}
	return depth == 0
}
