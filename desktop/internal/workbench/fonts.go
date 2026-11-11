package workbench

import (
	"math"
	"runtime"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// This file applies the user's fonts (internal/fontprefs) to the places that draw
// fixed-pitch text: the editors, the terminals, and the run output with the Git console.
// The fonts are stored in settingsFile, in the application support directory, and are
// written only when the user changes them in the settings window.

// scopeFont is the font one scope is drawn with, as the settings say now, with the face
// its family names. The face is looked up when the settings change rather than on every
// frame, because gfx.MonoFamily takes the face table's lock.
type scopeFont struct {
	fontprefs.Resolved
	face gfx.MonoFace
}

// appFonts holds the font of each scope.
type appFonts struct {
	editor, terminal, output scopeFont
}

// resolveScopeFont is the font scope is drawn with in fonts. An empty family is the
// system's fixed-pitch face; gfx.MonoFamily gives that too for a name it cannot use.
func resolveScopeFont(fonts []fontprefs.Font, scope fontprefs.Scope) scopeFont {
	resolved := fontprefs.For(fonts, scope)
	if resolved.Family == "" && scope == fontprefs.Terminal {
		resolved.Family = preferredTerminalFamily()
	}
	if resolved.Family == "" && (scope == fontprefs.Terminal || scope == fontprefs.Editor) {
		// The code font is the bundled monospace face when the user chose none; the terminal
		// takes it too when no Nerd Font is there.
		resolved.Family = bundled().Mono
	}
	face := gfx.MonoSystem
	if resolved.Family != "" {
		face = gfx.MonoFamily(resolved.Family)
	}
	return scopeFont{Resolved: resolved, face: face}
}

// terminalNerdFonts are the families the terminal prefers on macOS when the user chose none,
// in the earlier client's order: Nerd Fonts carry the icons of prompts such as Powerlevel10k and
// Starship, which the system's fixed-pitch face draws as boxes.
var terminalNerdFonts = []string{
	"MesloLGS Nerd Font Mono",
	"JetBrainsMono Nerd Font Mono",
	"Hack Nerd Font Mono",
	"FiraCode Nerd Font Mono",
	"IosevkaTerm Nerd Font Mono",
}

// preferredTerminalFamily is the first available family of terminalNerdFonts on macOS, read
// once, and empty for the system's face elsewhere or when none is there. The Nerd Font the
// packaged build carries counts as available, so a MesloLGS the user installed still wins
// and the bundled JetBrainsMono Nerd Font Mono comes next.
var preferredTerminalFamily = sync.OnceValue(func() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	return firstAvailableFamily(terminalNerdFonts, app.MonospaceFamilies(), bundled().Terminal)
})

// firstAvailableFamily is the first of preferred that is installed or bundled, or "".
func firstAvailableFamily(preferred, installed []string, bundled string) string {
	available := map[string]bool{}
	for _, family := range installed {
		available[family] = true
	}
	if bundled != "" {
		available[bundled] = true
	}
	for _, family := range preferred {
		if available[family] {
			return family
		}
	}
	return ""
}

// applyFonts works out the font of each scope from the settings. The editors and the
// terminals take theirs at their next paint (see editorFont and terminalFont), and the
// output lists read a.fonts.output as they are declared.
func (a *App) applyFonts() {
	fonts := a.settings.Fonts
	a.fonts = appFonts{
		editor:   resolveScopeFont(fonts, fontprefs.Editor),
		terminal: resolveScopeFont(fonts, fontprefs.Terminal),
		output:   resolveScopeFont(fonts, fontprefs.Output),
	}
}

// setFonts stores the fonts the settings window chose and applies them at once. The
// defaults are stored as no list at all, so settingsFile keeps nothing a user never chose.
func (a *App) setFonts(fonts []fontprefs.Font) {
	fonts = fontprefs.Normalize(fonts)
	if fontprefs.Equal(fonts, a.settings.Fonts) {
		return
	}
	if fontprefs.Equal(fonts, fontprefs.Default()) {
		fonts = nil
	}
	a.settings.Fonts = fonts
	a.saveSettings()
	a.applyFonts()
}

// outputFont is the font of the run output and the Git console. An App that never read
// its settings, as some tests build, has the default.
func (a *App) outputFont() scopeFont {
	if a.fonts.output.Size <= 0 {
		return resolveScopeFont(nil, fontprefs.Output)
	}
	return a.fonts.output
}

// editorFont is what an editor view is handed before each paint; SetFont ignores it when
// nothing changed.
func (a *App) editorFont() editorview.Font {
	f := a.fonts.editor
	return editorview.Font{Face: f.face, Size: f.Size, LineSpacing: f.LineSpacing, Ligatures: f.Ligatures}
}

// terminalFont is what a terminal view is handed before each paint, like editorFont.
func (a *App) terminalFont() termview.Font {
	f := a.fonts.terminal
	return termview.Font{Face: f.face, Size: f.Size, LineSpacing: f.LineSpacing, Ligatures: f.Ligatures}
}

// lineHeight is the height of one line of text drawn in f: its character cell's height
// times its line spacing, rounded to a whole pixel as the editor rounds its lines.
func (f scopeFont) lineHeight(canvas *gfx.Canvas) float32 {
	_, cellH := canvas.MonoCellSize(f.Size, f.face)
	return float32(math.Round(float64(cellH * f.LineSpacing)))
}

// textStyle is the style of plain text in f, for measuring it.
func (f scopeFont) textStyle() gfx.TextStyle {
	return gfx.TextStyle{Size: f.Size, Mono: true, MonoFace: f.face}
}
