// Package fontprefs is the user's choice of fixed-pitch fonts: which family, size, line
// spacing and ligatures the editor, the terminal and the run output are drawn with.
//
// The choice is a list of fonts, each applying to the scopes it names. Every scope belongs
// to exactly one font of the list, so the places that share a font are edited together and
// a place given its own font is edited on its own. The package holds the rules of that list
// and touches no Viva type: the workbench turns a family name into a face and the settings
// window draws the list, and both read it through Normalize and For.
//
// Where it is stored: the workbench keeps the list in its settings.json, in the user's
// application support directory, written only when the user changes a font in the settings
// window; nothing is written into the application bundle.
package fontprefs

import (
	"math"
	"slices"
	"strings"
)

// Scope names a place that draws fixed-pitch text.
type Scope string

// The scopes a font applies to.
const (
	// Editor is the text of the code editor.
	Editor Scope = "editor"
	// Terminal is the integrated terminal.
	Terminal Scope = "terminal"
	// Output is the output of runs, builds and tests, and the Git console.
	Output Scope = "output"
)

// Scopes lists every scope in the order the settings window shows them and the list is
// sorted in.
var Scopes = []Scope{Editor, Terminal, Output}

// The ranges of a font's size and line spacing.
const (
	// DefaultSize is the size, in points, of a font that names none.
	DefaultSize float32 = 13
	MinSize     float32 = 6
	MaxSize     float32 = 72
	// MinLineSpacing and MaxLineSpacing bound a line spacing that is not automatic. It is a
	// multiple of the height of a character cell, kept to one decimal place, and
	// LineSpacingStep is the step the settings window moves it by.
	MinLineSpacing  float32 = 1
	MaxLineSpacing  float32 = 3
	LineSpacingStep float32 = 0.1
)

// Font is one font of the list and the scopes it applies to. A zero field is the default:
// an empty Family is the system's fixed-pitch font, a zero Size is DefaultSize and a zero
// LineSpacing is automatic, which is AutoLineSpacing of each scope.
type Font struct {
	Family      string  `json:"family,omitempty"`
	Size        float32 `json:"size,omitempty"`
	LineSpacing float32 `json:"lineSpacing,omitempty"`
	Ligatures   bool    `json:"ligatures,omitempty"`
	Scopes      []Scope `json:"scopes"`
}

// Resolved is the font one scope is drawn with: every field is the value in force.
type Resolved struct {
	// Family is the installed family's name; empty is the system's fixed-pitch font.
	Family string
	// Size is the size in points.
	Size float32
	// LineSpacing is the height of a line as a multiple of the height of a character cell,
	// and Auto says it is the scope's automatic spacing rather than one the user set.
	LineSpacing float32
	Auto        bool
	// Ligatures says character sequences the font joins (->, !=) are drawn joined.
	Ligatures bool
}

// AutoLineSpacing is the line spacing of a scope whose font sets none: the editor gives its
// lines room, the terminal keeps the rows of a full-screen program touching, and the run
// output sits between the two.
func AutoLineSpacing(scope Scope) float32 {
	switch scope {
	case Editor:
		return 1.4
	case Terminal:
		return 1
	default:
		return 1.2
	}
}

// Default is the list a user who has changed nothing has: one font, the system's, for
// every scope.
func Default() []Font {
	return []Font{{Size: DefaultSize, Scopes: slices.Clone(Scopes)}}
}

// known says whether scope is one of Scopes.
func known(scope Scope) bool {
	return slices.Contains(Scopes, scope)
}

// rank is where scope is in Scopes.
func rank(scope Scope) int {
	return slices.Index(Scopes, scope)
}

// ClampSize keeps size within MinSize and MaxSize, rounded to a whole point; zero or less is
// DefaultSize.
func ClampSize(size float32) float32 {
	if size <= 0 || math.IsNaN(float64(size)) {
		return DefaultSize
	}
	return min(max(float32(math.Round(float64(size))), MinSize), MaxSize)
}

// ClampLineSpacing keeps a line spacing that is not automatic within MinLineSpacing and
// MaxLineSpacing, rounded to a step. Zero or less, or not a number, is automatic and stays
// zero.
func ClampLineSpacing(spacing float32) float32 {
	if spacing <= 0 || math.IsNaN(float64(spacing)) {
		return 0
	}
	rounded := float32(math.Round(float64(spacing)*10) / 10)
	return min(max(rounded, MinLineSpacing), MaxLineSpacing)
}

// Normalize returns the list fonts means, which every other function of the package also
// takes: each scope in exactly one font, in the first font of fonts that names it; a font's
// scopes in the order of Scopes; fonts that keep no scope dropped; the sizes and spacings
// clamped and the family names trimmed; and the fonts sorted by their first scope. Scopes
// no font names, as when the stored list is older than a new scope, get a font of their own
// with the defaults. Nil or empty fonts is Default. fonts is not changed.
func Normalize(fonts []Font) []Font {
	claimed := make(map[Scope]bool, len(Scopes))
	out := make([]Font, 0, len(Scopes))
	for _, font := range fonts {
		var scopes []Scope
		for _, scope := range font.Scopes {
			if known(scope) && !claimed[scope] {
				claimed[scope] = true
				scopes = append(scopes, scope)
			}
		}
		if len(scopes) == 0 {
			continue
		}
		slices.SortFunc(scopes, func(a, b Scope) int { return rank(a) - rank(b) })
		out = append(out, Font{
			Family:      strings.TrimSpace(font.Family),
			Size:        ClampSize(font.Size),
			LineSpacing: ClampLineSpacing(font.LineSpacing),
			Ligatures:   font.Ligatures,
			Scopes:      scopes,
		})
	}
	var missing []Scope
	for _, scope := range Scopes {
		if !claimed[scope] {
			missing = append(missing, scope)
		}
	}
	if len(missing) > 0 {
		out = append(out, Font{Size: DefaultSize, Scopes: missing})
	}
	slices.SortStableFunc(out, func(a, b Font) int { return rank(a.Scopes[0]) - rank(b.Scopes[0]) })
	return out
}

// For is the font scope is drawn with in fonts.
func For(fonts []Font, scope Scope) Resolved {
	font := Font{Size: DefaultSize}
	for _, candidate := range Normalize(fonts) {
		if slices.Contains(candidate.Scopes, scope) {
			font = candidate
			break
		}
	}
	resolved := Resolved{Family: font.Family, Size: font.Size, LineSpacing: font.LineSpacing, Ligatures: font.Ligatures}
	if resolved.LineSpacing == 0 {
		resolved.LineSpacing, resolved.Auto = AutoLineSpacing(scope), true
	}
	return resolved
}

// SetScope returns fonts with scope moved into or out of the font at index i of
// Normalize(fonts). Including it takes it from the font that had it, which is dropped if it
// keeps no scope. Excluding it gives it a font of its own with the values of font i, which
// the user then changes. A font keeps at least one scope, so excluding the last one, an
// index out of range or a scope not in Scopes leaves the list as it is. The result is
// normalized; fonts is not changed.
func SetScope(fonts []Font, i int, scope Scope, include bool) []Font {
	list := Normalize(fonts)
	if i < 0 || i >= len(list) || !known(scope) {
		return list
	}
	has := slices.Contains(list[i].Scopes, scope)
	switch {
	case include && !has:
		for j := range list {
			list[j].Scopes = slices.DeleteFunc(slices.Clone(list[j].Scopes), func(s Scope) bool { return s == scope })
		}
		list[i].Scopes = append(list[i].Scopes, scope)
	case !include && has && len(list[i].Scopes) > 1:
		split := list[i]
		split.Scopes = []Scope{scope}
		list[i].Scopes = slices.DeleteFunc(slices.Clone(list[i].Scopes), func(s Scope) bool { return s == scope })
		list = append(list, split)
	}
	return Normalize(list)
}

// Update returns fonts with the font at index i of Normalize(fonts) replaced by edit applied
// to a copy of it. edit may change any field but the scopes, which SetScope moves. An index
// out of range leaves the list as it is. The result is normalized; fonts is not changed.
func Update(fonts []Font, i int, edit func(*Font)) []Font {
	list := Normalize(fonts)
	if i < 0 || i >= len(list) || edit == nil {
		return list
	}
	font := list[i]
	scopes := font.Scopes
	font.Scopes = slices.Clone(scopes)
	edit(&font)
	font.Scopes = scopes
	list[i] = font
	return Normalize(list)
}

// Equal says whether a and b mean the same list.
func Equal(a, b []Font) bool {
	return slices.EqualFunc(Normalize(a), Normalize(b), func(x, y Font) bool {
		return x.Family == y.Family && x.Size == y.Size && x.LineSpacing == y.LineSpacing &&
			x.Ligatures == y.Ligatures && slices.Equal(x.Scopes, y.Scopes)
	})
}
