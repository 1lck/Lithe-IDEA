package keymapimport

import (
	"cmp"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
)

const maxActions = 4096

// Action is a stable snapshot of effective shortcuts, including user ownership.
type Action struct {
	ID         string
	Customized bool
	Keys       []string
}
type Binding struct {
	ID   string
	Keys []string
}
type Skipped struct{ Command, Reason string }
type Conflict struct{ ID, Owner, Key string }
type Displaced struct {
	ID   string
	Keys []string
}

// Preview is deterministic. A conflict leaves Proposal nil to prevent partial import.
type Preview struct {
	Proposal  shortcuts.Overrides
	Imported  []Binding
	Skipped   []Skipped
	Conflicts []Conflict
	Displaced []Displaced
	Inherited bool
}

type parsed struct {
	bindings  shortcuts.Overrides
	skipped   []Skipped
	inherited bool
}

func (p *parsed) skip(command, reason string) {
	p.skipped = append(p.skipped, Skipped{command, reason})
}

// Parse imports only explicitly configured keys, never guessed defaults. All
// incompatible rules remain visible in Skipped; contextual keys stay contextual.
func Parse(format, content string, catalog []Action) (Preview, error) {
	if len(content) > maxSourceBytes || !utf8.ValidString(content) || len(catalog) > maxActions {
		return Preview{}, ErrDocument
	}
	var p parsed
	var err error
	switch format {
	case "vscode":
		p, err = parseVSCode(content)
	case "idea":
		p, err = parseIDEA(content)
	default:
		return Preview{}, ErrDocument
	}
	if err != nil {
		return Preview{}, err
	}
	known := make(map[string]Action, len(catalog))
	owners := make(map[string][]Action)
	out := Preview{Skipped: p.skipped, Inherited: p.inherited, Proposal: make(shortcuts.Overrides)}
	for _, action := range catalog {
		if !validID(action.ID) || len(action.Keys) > 8 {
			return Preview{}, ErrDocument
		}
		if _, exists := known[action.ID]; exists {
			return Preview{}, ErrDocument
		}
		keys := make([]string, 0, len(action.Keys))
		for _, key := range action.Keys {
			value, ok := canonical(key)
			if !ok {
				return Preview{}, ErrDocument
			}
			keys = append(keys, value)
		}
		action.Keys = keys
		known[action.ID] = action
		if action.Customized {
			out.Proposal[action.ID] = slices.Clone(keys)
		}
		for _, key := range keys {
			owners[key] = append(owners[key], action)
		}
	}
	for id, keys := range p.bindings {
		if _, ok := known[id]; !ok {
			out.Skipped = append(out.Skipped, Skipped{id, "unavailable"})
			delete(p.bindings, id)
			continue
		}
		out.Imported = append(out.Imported, Binding{id, keys})
	}
	slices.SortFunc(out.Imported, func(a, b Binding) int { return cmp.Compare(a.ID, b.ID) })
	slices.SortFunc(out.Skipped, func(a, b Skipped) int {
		if c := cmp.Compare(a.Command, b.Command); c != 0 {
			return c
		}
		return cmp.Compare(a.Reason, b.Reason)
	})
	comparisons := 0
	incomingOwners := make(map[string]string)
	displaced := make(map[string]map[string]bool)
	for _, binding := range out.Imported {
		out.Proposal[binding.ID] = slices.Clone(binding.Keys)
		for _, key := range binding.Keys {
			if owner, exists := incomingOwners[key]; exists && owner != binding.ID {
				out.Conflicts = append(out.Conflicts, Conflict{binding.ID, owner, key})
			} else {
				incomingOwners[key] = binding.ID
			}
			for _, owner := range owners[key] {
				comparisons++
				if comparisons > 131072 || len(out.Conflicts) >= maxActions {
					return Preview{}, ErrDocument
				}
				if _, replaced := p.bindings[owner.ID]; replaced {
					continue
				}
				if owner.Customized {
					out.Conflicts = append(out.Conflicts, Conflict{binding.ID, owner.ID, key})
					continue
				}
				if displaced[owner.ID] == nil {
					displaced[owner.ID] = make(map[string]bool)
				}
				displaced[owner.ID][key] = true
			}
		}
	}
	for id, removed := range displaced {
		remaining := make([]string, 0, len(known[id].Keys))
		keys := make([]string, 0, len(removed))
		for _, key := range known[id].Keys {
			if removed[key] {
				keys = append(keys, key)
			} else {
				remaining = append(remaining, key)
			}
		}
		out.Proposal[id] = remaining
		out.Displaced = append(out.Displaced, Displaced{id, keys})
	}
	slices.SortFunc(out.Displaced, func(a, b Displaced) int { return cmp.Compare(a.ID, b.ID) })
	if len(out.Conflicts) > 0 {
		out.Proposal = nil
	}
	return out, nil
}

func validID(id string) bool {
	return len(id) > 0 && len(id) <= 128 && !strings.ContainsFunc(id, unicode.IsControl)
}

// canonical translates source modifier aliases to the exact Viva representation.
// Parsing with the existing shortcut package keeps validation and actual dispatch aligned.
func canonical(text string) (string, bool) {
	if len(text) > 128 || strings.ContainsFunc(text, unicode.IsSpace) {
		return "", false
	}
	rest := strings.ToLower(text)
	var modifiers []string
	for {
		head, tail, found := strings.Cut(rest, "+")
		if !found {
			break
		}
		var name string
		switch head {
		case "ctrl", "control":
			name = "ctrl"
		case "alt", "option":
			name = "alt"
		case "shift":
			name = "shift"
		case "cmd", "command", "meta", "win", "super":
			name = "meta"
		default:
			name = ""
		}
		if name == "" {
			break
		}
		if slices.Contains(modifiers, name) {
			return "", false
		}
		modifiers = append(modifiers, name)
		rest = tail
	}
	aliases := map[string]string{"enter": "return", "esc": "escape", "backquote": "`", "back_space": "backspace", "page_up": "pageup", "page_down": "pagedown", "equals": "=", "minus": "-", "slash": "/", "comma": ",", "period": ".", "open_bracket": "[", "close_bracket": "]", "back_slash": "\\", "semicolon": ";", "quote": "'"}
	if value, ok := aliases[rest]; ok {
		rest = value
	}
	// The host decoder accepts explicit modifier names and canonicalizes their order.
	key, ok := shortcuts.Decode(strings.Join(append(modifiers, rest), "+"))
	if !ok {
		return "", false
	}
	return shortcuts.Encode(key), true
}
