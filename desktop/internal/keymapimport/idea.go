package keymapimport

import (
	"encoding/xml"
	"io"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
)

func xmlAttributes(tag xml.StartElement) (map[string]string, error) {
	values := make(map[string]string, len(tag.Attr))
	for _, attr := range tag.Attr {
		if attr.Name.Space != "" {
			return nil, ErrDocument
		}
		if _, duplicate := values[attr.Name.Local]; duplicate {
			return nil, ErrDocument
		}
		values[attr.Name.Local] = attr.Value
	}
	return values, nil
}

func parseIDEA(content string) (parsed, error) {
	p := parsed{bindings: make(shortcuts.Overrides)}
	reader := xml.NewDecoder(strings.NewReader(strings.TrimPrefix(content, "\ufeff")))
	var stack []string
	seenRoot := false
	seenActions := make(map[string]bool)
	var source, id string
	var keys []string
	blocked := false
	for {
		if len(p.skipped) > maxActions {
			return p, ErrDocument
		}
		token, err := reader.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return p, ErrDocument
		}
		switch tag := token.(type) {
		case xml.StartElement:
			if tag.Name.Space != "" || len(stack) >= 16 {
				return p, ErrDocument
			}
			attrs, err := xmlAttributes(tag)
			if err != nil {
				return p, err
			}
			name := tag.Name.Local
			switch len(stack) {
			case 0:
				if seenRoot || name != "keymap" {
					return p, ErrDocument
				}
				seenRoot = true
				p.inherited = attrs["parent"] != ""
			case 1:
				if name != "action" {
					return p, ErrDocument
				}
				source = attrs["id"]
				if !validID(source) || seenActions[source] || len(seenActions) >= maxActions {
					return p, ErrDocument
				}
				seenActions[source] = true
				id = ideaCommand(source)
				keys = make([]string, 0)
				blocked = false
			case 2:
				if name != "keyboard-shortcut" {
					p.skip(source, "unsupported_rule")
					blocked = true
					break
				}
				if attrs["second-keystroke"] != "" {
					p.skip(source, "sequence")
					blocked = true
					break
				}
				value, ok := canonical(strings.Join(strings.Fields(attrs["first-keystroke"]), "+"))
				if !ok {
					p.skip(source, "unsupported_key")
					blocked = true
					break
				}
				if !contains(keys, value) {
					keys = append(keys, value)
				}
				if len(keys) > 8 {
					return p, ErrDocument
				}
			default:
				return p, ErrDocument
			}
			stack = append(stack, name)
		case xml.EndElement:
			if len(stack) == 0 || stack[len(stack)-1] != tag.Name.Local {
				return p, ErrDocument
			}
			if len(stack) == 2 {
				if id == "" {
					p.skip(source, "unmapped")
				} else if !blocked {
					if _, duplicate := p.bindings[id]; duplicate {
						return p, ErrDocument
					}
					p.bindings[id] = keys
				}
			}
			stack = stack[:len(stack)-1]
		case xml.Directive:
			return p, ErrDocument // No DTD or external/internal entity declarations.
		case xml.ProcInst:
			if tag.Target != "xml" || seenRoot {
				return p, ErrDocument
			}
		case xml.CharData:
			if strings.TrimSpace(string(tag)) != "" {
				return p, ErrDocument
			}
		}
	}
	if !seenRoot || len(stack) != 0 {
		return p, ErrDocument
	}
	return p, nil
}

func ideaCommand(command string) string {
	return map[string]string{
		"ShowSettings": "settings.open", "OpenFile": "project.open",
		"CloseProject": "project.close", "CloseContent": "tab.close",
		"SaveAll": "documents.saveAll", "SaveAs": "editor.saveAs",
		"GotoAction": "search.findAction", "SearchEverywhere": "search.everywhere",
		"FindInPath": "search.files", "ReplaceInPath": "search.replace",
		"Find": "editor.find", "Replace": "editor.replace", "GotoLine": "navigate.gotoLine",
		"CollapseRegion": "editor.fold", "ExpandRegion": "editor.unfold",
		"CollapseAllRegions": "editor.foldAll", "ExpandAllRegions": "editor.unfoldAll",
		"SelectNextOccurrence": "editor.addNextOccurrence", "UnselectPreviousOccurrence": "editor.unselectOccurrence",
		"SelectAllOccurrences":  "editor.selectAllOccurrences",
		"EditorCloneCaretAbove": "editor.cloneCaretAbove", "EditorCloneCaretBelow": "editor.cloneCaretBelow",
		"RecentFiles": "editor.recentFiles", "RecentChangedFiles": "editor.recentEdits",
		"Run": "run.selected", "Debug": "debug.start", "ToggleLineBreakpoint": "debug.toggleBreakpoint",
		"CheckinProject": "git.commit", "Git.Pull": "git.pull", "Vcs.Push": "git.push",
		"Git.Fetch": "git.fetch", "Vcs.UpdateProject": "git.updateBranch",
		"ToggleFullScreen": "window.fullscreen",
	}[command]
}
