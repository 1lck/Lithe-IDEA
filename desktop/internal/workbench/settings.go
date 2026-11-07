package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/flex"
)

// The identities of the settings dialog's controls.
var (
	// settingsDialogScope is the focus scope Tab stays inside while the dialog is open.
	settingsDialogScope = tree.ID(settingsPage, "dialog")
	settingsClose       = tree.ID(settingsPage, "close")
	// settingsDone is also the dialog's dismiss target, so the Done button, a press on
	// the scrim and Escape all end in the one Dismissed check in drawSettings.
	settingsDone        = tree.ID(settingsPage, "done")
	settingsResetLayout = tree.ID(settingsPage, "reset-layout")
	// settingsLanguage and settingsTheme identify the segments of the two choices:
	// scope.At(i) is segment i.
	settingsLanguage = tree.Sub(settingsPage, tree.Name("language"))
	settingsTheme    = tree.Sub(settingsPage, tree.Name("theme"))
)

// settingsDialogWidth fits the widest choice (language, with its three segments) and
// its label on one line in both catalogs.
const settingsDialogWidth = 480

// settingsThemes lists the segments of the theme choice, in the order they are shown.
var settingsThemes = [...]themeChoice{themeSystem, themeLight, themeDark}

// settingsLanguageIndex is the segment of the language choice for a stored code. Segment
// 0 follows the system, which is what an empty or unknown code does; the languages
// follow in the order i18n lists them.
func settingsLanguageIndex(code string) int {
	language, ok := i18n.Parse(code)
	if !ok {
		return 0
	}
	for index, candidate := range i18n.Languages {
		if candidate == language {
			return index + 1
		}
	}
	return 0
}

// settingsLanguageCode is the code to store for a segment of the language choice, the
// reverse of settingsLanguageIndex.
func settingsLanguageCode(index int) string {
	if index < 1 || index > len(i18n.Languages) {
		return ""
	}
	return i18n.Languages[index-1].Code()
}

// settingsThemeIndex is the segment of the theme choice for the stored look.
func settingsThemeIndex(choice themeChoice) int {
	for index, candidate := range settingsThemes {
		if candidate == choice {
			return index
		}
	}
	return 0
}

// drawSettings is the settings dialog, declared only while it is open. A choice applies
// the moment it is clicked, the way the rest of the window reacts to a preference, so the
// dialog has nothing to confirm: Done just closes it.
func (a *App) drawSettings(f *flex.Frame) {
	words := &a.text.Settings
	// Each language is named in its own language whatever the window is shown in, so a
	// reader who cannot read the current one still finds theirs. Choice copies the labels
	// it is given, so the arrays are plain locals rebuilt every frame (the window's own
	// words may change between frames when the language does).
	var languages [len(i18n.Languages) + 1]string
	languages[0] = words.FollowSystem(a.systemLanguage.Native())
	for index, language := range i18n.Languages {
		languages[index+1] = language.Native()
	}
	systemLook := words.Light
	if app.SystemAppearance() == app.AppearanceDark {
		systemLook = words.Dark
	}
	themes := [len(settingsThemes)]string{words.FollowSystem(systemLook), words.Light, words.Dark}

	dialog := f.Dialog(flex.DialogSpec{
		Title:     words.Title,
		Width:     settingsDialogWidth,
		Scope:     settingsDialogScope,
		DismissID: settingsDone,
		CloseID:   settingsClose,
	})
	dialog.Body(func() {
		f.Column().Gap(16).Children(func() {
			f.Row().Items(flex.Center).Gap(16).Children(func() {
				f.Text(words.Language).Grow(1)
				choice := f.Choice(settingsLanguage, languages[:], settingsLanguageIndex(a.settings.Language)).Shrink(0)
				if index, ok := choice.ChosenIndex(); ok {
					a.setLanguage(settingsLanguageCode(index))
				}
			})
			f.Row().Items(flex.Center).Gap(16).Children(func() {
				f.Text(words.Theme).Grow(1)
				choice := f.Choice(settingsTheme, themes[:], settingsThemeIndex(a.settings.Theme)).Shrink(0)
				if index, ok := choice.ChosenIndex(); ok {
					a.setTheme(settingsThemes[index])
				}
			})
			// Self keeps the button as wide as its label; a column would stretch it.
			if f.Button(settingsResetLayout, words.ResetLayout).Outline().Self(flex.Start).Clicked() {
				a.resetLayout()
			}
		})
	})
	dialog.Footer(func() {
		f.Button(settingsDone, words.Done)
	})
	if dialog.Dismissed() {
		a.settingsOpen = false
	}
}
