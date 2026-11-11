package legacyimport

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

// defaultsExport is what `defaults export app.lithe.desktop -` writes for an earlier
// client with every imported key set.
func defaultsExport(t *testing.T) string {
	t.Helper()
	encode := func(value string) string { return base64.StdEncoding.EncodeToString([]byte(value)) }
	recent := encode(`[{"path":"/Users/me/app","lastOpened":800000000.5,"branch":"main"},{"path":"","lastOpened":1},{"path":"/Users/me/lib","lastOpened":-978307300}]`)
	termination := encode(`{"terminalOnQuit":"terminate","confirmTerminalTabClose":false,"runServicesOnExit":"ask","gracefulStopSeconds":5}`)
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>settings.language</key>
	<string>zh-Hans</string>
	<key>settings.themePreference</key>
	<string>dark</string>
	<key>settings.editorMinimap</key>
	<false/>
	<key>settings.editorTabLayoutMode</key>
	<string>multipleRows</string>
	<key>settings.terminalShell</key>
	<string>bash</string>
	<key>settings.terminalShellPathOverride</key>
	<string></string>
	<key>settings.editorFontFamily</key>
	<string>JetBrains Mono</string>
	<key>settings.editorFontSize</key>
	<real>14</real>
	<key>settings.processTermination</key>
	<data>
	` + termination[:8] + `
	` + termination[8:] + `
	</data>
	<key>lithe.recent-projects</key>
	<data>` + recent + `</data>
	<key>settings.searchExcludedPathPatterns</key>
	<array>
		<string>node_modules</string>
		<integer>3</integer>
		<dict><key>nested</key><true/></dict>
	</array>
	<key>SULastCheckTime</key>
	<date>2026-11-01T10:00:00Z</date>
</dict>
</plist>
`
}

func TestDefaultsMapOntoTheVivaSettings(t *testing.T) {
	values, err := parsePlist(strings.NewReader(defaultsExport(t)))
	if err != nil {
		t.Fatal(err)
	}
	if list, ok := values["settings.searchExcludedPathPatterns"].([]any); !ok || len(list) != 3 || list[1] != int64(3) {
		t.Fatalf("array = %#v", values["settings.searchExcludedPathPatterns"])
	}
	found := fromDefaults(values)
	if found.Source != "app.lithe.desktop" || *found.Language != "zh-Hans" || *found.Theme != "dark" || !*found.HideMinimap ||
		*found.EditorTabRows != "multiple" || *found.TerminalShell != "/bin/bash" {
		t.Fatalf("found = %+v", found)
	}
	if found.EditorFont == nil || *found.EditorFont != (Font{Family: "JetBrains Mono", Size: 14}) || found.TerminalFont != nil {
		t.Fatalf("fonts = %+v %+v", found.EditorFont, found.TerminalFont)
	}
	if p := found.ProcessTermination; p == nil || *p != (ProcessTermination{TerminalOnQuit: "terminate"}) {
		t.Fatalf("process termination = %+v", p)
	}
	want := []Recent{{Path: "/Users/me/app", OpenedAt: 1778307200500}, {Path: "/Users/me/lib", OpenedAt: 0}}
	if len(found.Recent) != 2 || found.Recent[0] != want[0] || found.Recent[1] != want[1] {
		t.Fatalf("recent = %+v", found.Recent)
	}
}

func TestDefaultsKeepOnlyKnownValues(t *testing.T) {
	found := fromDefaults(map[string]any{
		"settings.language":                  "fr",
		"settings.themePreference":           "sepia",
		"settings.editorTabLayoutMode":       "columns",
		"settings.terminalShell":             "fish",
		"settings.terminalShellPathOverride": "  /opt/homebrew/bin/fish ",
		"settings.processTermination":        []byte("not json"),
		"lithe.recent-projects":              []byte("{}"),
	})
	if found.Language != nil || found.Theme != nil || found.EditorTabRows != nil || found.ProcessTermination != nil || found.Recent != nil {
		t.Fatalf("found = %+v", found)
	}
	if found.TerminalShell == nil || *found.TerminalShell != "/opt/homebrew/bin/fish" {
		t.Fatalf("shell = %v", found.TerminalShell)
	}
	if !fromDefaults(map[string]any{}).Empty() {
		t.Fatal("an empty domain is not empty")
	}
}

func TestTauriSettingsMapOntoTheVivaSettings(t *testing.T) {
	var values map[string]json.RawMessage
	if err := json.Unmarshal([]byte(`{"displayLanguage":"zh-CN","theme":"lithe-light","syncSystemTheme":false,"showMinimap":true,
		"editorTabLayoutMode":"singleLine","runServicesOnExit":"terminate","fontFamily":"'Cascadia Code', Consolas, monospace",
		"fontSize":15,"terminalFontFamily":"","terminalFontSize":0,"agentPanel":{"x":1}}`), &values); err != nil {
		t.Fatal(err)
	}
	found := fromTauriSettings(`C:\Users\me\AppData\Roaming\app.lithe.windows\settings.json`, values)
	if *found.Language != "zh-Hans" || *found.Theme != "light" || *found.HideMinimap || *found.EditorTabRows != "" {
		t.Fatalf("found = %+v", found)
	}
	if p := found.ProcessTermination; p == nil || *p != (ProcessTermination{RunServicesOnExit: "terminate", ConfirmTerminalTabClose: true}) {
		t.Fatalf("process termination = %+v", p)
	}
	if found.EditorFont == nil || *found.EditorFont != (Font{Family: "Cascadia Code", Size: 15}) || found.TerminalFont != nil {
		t.Fatalf("fonts = %+v %+v", found.EditorFont, found.TerminalFont)
	}
	if found.TerminalShell != nil || found.Recent != nil {
		t.Fatalf("found = %+v", found)
	}
	values["syncSystemTheme"] = json.RawMessage("true")
	if theme := fromTauriSettings("", values).Theme; theme == nil || *theme != "" {
		t.Fatalf("theme = %v, want the system's", theme)
	}
}

func TestPlistRejectsMalformedDocuments(t *testing.T) {
	for _, document := range []string{
		`<plist><array/></plist>`,
		`<plist><dict><string>no key</string></dict></plist>`,
		`<plist><dict><key>a</key><integer>x</integer></dict></plist>`,
		`<plist><dict><key>a</key><widget/></dict></plist>`,
		`<plist><dict><key>a</key>`,
		`<plist>` + strings.Repeat("<array>", maxPlistDepth+2) + strings.Repeat("</array>", maxPlistDepth+2) + `</plist>`,
	} {
		if _, err := parsePlist(strings.NewReader(document)); err == nil {
			t.Errorf("%q parsed", document)
		}
	}
}
