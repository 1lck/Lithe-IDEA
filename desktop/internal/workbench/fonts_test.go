package workbench

import "testing"

func TestTerminalFamilyPrefersAnInstalledNerdFontThenTheBundledOne(t *testing.T) {
	const bundledNerd = "JetBrainsMono Nerd Font Mono"
	for _, test := range []struct {
		name      string
		installed []string
		bundled   string
		want      string
	}{
		{"an installed MesloLGS comes first", []string{"Menlo", "MesloLGS Nerd Font Mono"}, bundledNerd, "MesloLGS Nerd Font Mono"},
		{"the bundled Nerd Font comes next", []string{"Menlo", "Hack Nerd Font Mono"}, bundledNerd, bundledNerd},
		{"without a bundled one an installed Nerd Font is used", []string{"Hack Nerd Font Mono"}, "", "Hack Nerd Font Mono"},
		{"no Nerd Font leaves the choice to the code font", []string{"Menlo"}, "", ""},
	} {
		if got := firstAvailableFamily(terminalNerdFonts, test.installed, test.bundled); got != test.want {
			t.Errorf("%s: got %q, want %q", test.name, got, test.want)
		}
	}
}
