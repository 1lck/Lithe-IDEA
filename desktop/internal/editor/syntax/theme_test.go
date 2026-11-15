package syntax

import (
	"encoding/json"
	"testing"
)

func TestParseColor(t *testing.T) {
	for s, want := range map[string]Color{"#cf8e6d": 0xcf8e6d, "CF8E6D": 0xcf8e6d, "#cf8e6d80": 0xcf8e6d} {
		if got, ok := ParseColor(s); !ok || got != want {
			t.Errorf("ParseColor(%q) = %06x, %v", s, got, ok)
		}
	}
	for _, s := range []string{"", "#fff", "#cf8e6dzz", "#gggggg", "#cf8e6d8"} {
		if _, ok := ParseColor(s); ok {
			t.Errorf("ParseColor(%q) succeeds", s)
		}
	}
}

func TestThemeInheritsByDottedPrefix(t *testing.T) {
	theme := NewTheme([]ThemeRule{
		{Token: "comment.line", Foreground: "#333333"},
		{Token: "", Foreground: "#111111"},
		{Token: "comment", Foreground: "#222222", FontStyle: "italic", SetsFontStyle: true},
		{Token: "comment", Foreground: "not a color"},
		{Token: "keyword.bold", FontStyle: "bold underline", SetsFontStyle: true},
	})
	for token, want := range map[string]Style{
		"comment.line.java": {0x333333, Italic},
		"comment.block":     {0x222222, Italic},
		"commentary":        {0x111111, 0},
		"keyword":           {0x111111, 0},
		"keyword.bold.x":    {0x111111, Bold | Underline},
	} {
		if got := theme.Match(token); got != want {
			t.Errorf("Match(%q) = %+v, want %+v", token, got, want)
		}
		// Style answers for names made after the theme as well.
		if got := theme.Style(Intern(token + ".theme-test")); got != theme.Match(token+".theme-test") {
			t.Errorf("Style(%q) = %+v, Match %+v", token, got, theme.Match(token))
		}
	}
	if got := theme.Default(); got != (Style{0x111111, 0}) {
		t.Errorf("Default() = %+v", got)
	}
}

func TestBuildTheme(t *testing.T) {
	palette := DefaultPalette()
	lithe := BuildTheme(ThemeOptions{Dark: true}, palette)
	if got := lithe.Match("keyword.java").Foreground; got != 0xcf8e6d {
		t.Errorf("Lithe dark keyword %06x", got)
	}
	if got := BuildTheme(ThemeOptions{}, palette).Match("keyword.java").Foreground; got != 0xb83280 {
		t.Errorf("Lithe light keyword %06x", got)
	}
	if got := lithe.Default().Foreground; got != 0xdfe1e5 {
		t.Errorf("Lithe dark text %06x", got)
	}

	idea := BuildTheme(ThemeOptions{Dark: true, Scheme: SchemeIDEA, ItalicComments: true}, palette)
	for token, want := range map[string]Color{
		"keyword.java":       0xcf8e6d,
		"string.java":        0x6aab73,
		"number.java":        0x2aacb8,
		"method":             0xbcbec4,
		"method.declaration": 0x56a8f5,
		"tag.html":           0xd5b778,
	} {
		if got := idea.Match(token).Foreground; got != want {
			t.Errorf("IDEA dark %s: %06x, want %06x", token, got, want)
		}
	}
	if idea.Match("comment.block.java").Font&Italic == 0 {
		t.Error("italic comments are not italic")
	}
	plain := BuildTheme(ThemeOptions{Dark: true, Scheme: SchemeIDEA}, palette)
	if plain.Match("comment.block.java").Font&Italic != 0 {
		t.Error("comments are italic without italic comments")
	}
	if idea.Match("method.deprecated").Font&Strikethrough == 0 {
		t.Error("deprecated methods are not struck out")
	}

	// The workbench's text color is the default unless a custom theme sets its own.
	if got := BuildTheme(ThemeOptions{Dark: true, Foreground: "#010101"}, palette).Default().Foreground; got != 0x010101 {
		t.Errorf("workbench foreground %06x", got)
	}
	custom := BuildTheme(ThemeOptions{Dark: true, Foreground: "#010101", Custom: &CustomTheme{
		Dark:   true,
		Colors: map[string]string{"foreground": "#020202"},
		Tokens: map[string]CustomTokenStyle{
			"keyword":            {Foreground: "#ff0000"},
			"method.declaration": {Foreground: "#00ff00", FontStyle: "bold", SetsFontStyle: true},
		},
	}}, palette)
	if got := custom.Default().Foreground; got != 0x020202 {
		t.Errorf("custom foreground %06x", got)
	}
	if got := custom.Match("keyword.java").Foreground; got != 0xff0000 {
		t.Errorf("custom keyword %06x", got)
	}
	if got := custom.Match("method.declaration.static"); got.Foreground != 0x00ff00 || got.Font != Bold {
		t.Errorf("custom method declaration %+v", got)
	}
	if got := custom.Match("method.deprecated"); got.Font&Strikethrough == 0 {
		t.Errorf("custom deprecated method %+v", got)
	}
}

func TestBundledSchemesParse(t *testing.T) {
	for id, colors := range schemeVariants() {
		for token, color := range colors {
			if _, ok := ParseColor(color); !ok {
				t.Errorf("%s: %s has color %q", id, token, color)
			}
		}
	}
	for role, color := range DefaultPalette() {
		for _, c := range []string{color.Light, color.Dark} {
			if _, ok := ParseColor(c); !ok {
				t.Errorf("palette %s has color %q", role, c)
			}
		}
	}
	data, err := schemeFiles.ReadFile("schemes/lithe.json")
	if err != nil || !json.Valid(data) {
		t.Fatalf("lithe scheme: %v", err)
	}
	for _, scheme := range []string{SchemeLithe, SchemeGitHub, SchemeOne, SchemeVSCode, SchemeIDEA} {
		for _, dark := range []bool{false, true} {
			if BuildTheme(ThemeOptions{Dark: dark, Scheme: scheme}, DefaultPalette()) == nil {
				t.Errorf("%s dark=%v: no theme", scheme, dark)
			}
		}
	}
}
