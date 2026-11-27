package workbench

import "github.com/1lck/Lithe-IDEA/desktop/internal/editorview"

// editorPresentation keeps full-source document views and editable previews on the same settings.
func (a *App) editorPresentation() editorview.Presentation {
	prefs := a.editorPreferences
	presentation := editorview.Presentation{
		HideLineNumbers: !prefs.LineNumbers, ShowWhitespace: prefs.Whitespace,
		CursorStyle: prefs.CursorStyle, DisableCursorBlink: !prefs.CursorBlink,
		IndentGuides: prefs.IndentGuides,
	}
	if prefs.RainbowIndentGuidesEffective {
		presentation.IndentGuideColors = prefs.RainbowLightColors
		if a.colors.Dark {
			presentation.IndentGuideColors = prefs.RainbowDarkColors
		}
	}
	return presentation
}
