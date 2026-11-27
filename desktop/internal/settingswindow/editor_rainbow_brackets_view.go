package settingswindow

import (
	"fmt"
	"slices"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/base"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Core editor preference accepts up to eight colors per theme.
const rainbowPaletteCapacity = 8

type rainbowSwatch struct {
	picker ui.ColorPickerState
	color  gfx.Color
}

type rainbowPaletteEditor struct {
	swatches []*rainbowSwatch
	add      rainbowSwatch
}

func (p *rainbowPaletteEditor) load(colors []string) {
	if len(p.swatches) != len(colors) {
		p.swatches = make([]*rainbowSwatch, len(colors))
		for i := range p.swatches {
			p.swatches[i] = &rainbowSwatch{}
		}
	}
	for i, hex := range colors {
		color, _ := syntax.ParseColor(hex)
		p.swatches[i].color = gfx.RGB24(uint32(color))
	}
}

func (p *rainbowPaletteEditor) changed(colors []string) ([]string, bool) {
	for i, swatch := range p.swatches {
		if !swatch.picker.Applied() {
			continue
		}
		if swatch.color.Alpha == 0 {
			if len(colors) == 1 {
				return nil, true
			}
			return slices.Delete(slices.Clone(colors), i, i+1), true
		}
		hex := rainbowHex(swatch.color)
		if hex == colors[i] {
			return nil, false
		}
		result := slices.Clone(colors)
		result[i] = hex
		return result, true
	}
	if p.add.picker.Applied() && p.add.color.Alpha != 0 && len(colors) < rainbowPaletteCapacity {
		return append(slices.Clone(colors), rainbowHex(p.add.color)), true
	}
	return nil, false
}

func rainbowHex(color gfx.Color) string {
	return fmt.Sprintf("#%02X%02X%02X", uint8(color.Red*255+.5), uint8(color.Green*255+.5), uint8(color.Blue*255+.5))
}

func (w *window) loadRainbowPalettes(value core.EditorPreferences) {
	w.rainbowLight.load(value.RainbowLightColors)
	w.rainbowDark.load(value.RainbowDarkColors)
}

func (w *window) editorRainbowCard(c ui.C) {
	w.card(c, i18n.Shared(w.marketLanguage(), "desktop.editorPrefs.rainbowBrackets"), "", func() {
		w.rainbowControls(c, w.sess.values.EditorPreferences)
	})
}

func (w *window) rainbowControls(c ui.C, current core.EditorPreferences) {
	lang := w.marketLanguage()
	ui.Row(c).FillWidth().Items(ui.Center).Gap(20).Children(func() {
		ui.Row(c.Part("rainbow-brackets")).Items(ui.Center).Gap(6).Children(func() {
			if ui.Switch(c, &current.RainbowBrackets, i18n.Shared(lang, "desktop.editorPrefs.rainbowBrackets")).Changed() {
				w.setEditorPresentation(current)
			}
			w.infoButton(c.Part("brackets-info"), i18n.Shared(lang, "desktop.editorPrefs.rainbowBracketsHelp"))
		})
		ui.Row(c.Part("rainbow-variables")).Items(ui.Center).Gap(6).Children(func() {
			if ui.Switch(c, &current.RainbowVariables, i18n.Shared(lang, "desktop.editorPrefs.rainbowVariables")).Changed() {
				w.setEditorPresentation(current)
			}
			w.infoButton(c.Part("variables-info"), i18n.Shared(lang, "desktop.editorPrefs.rainbowVariablesHelp"))
		})
	})
	ui.Row(c.Part("rainbow-indent-guides-row")).Items(ui.Center).Gap(6).Children(func() {
		if ui.Switch(c.Part("rainbow-indent-guides"), &current.RainbowIndentGuides, i18n.Shared(lang, "desktop.editorPrefs.rainbowIndentGuides")).
			Disabled(!current.IndentGuides).Changed() {
			w.setEditorPresentation(current)
		}
		w.infoButton(c.Part("rainbow-indent-guides-info"), i18n.Shared(lang, "desktop.editorPrefs.rainbowIndentGuidesHelp"))
	})
	if !current.RainbowBrackets && !current.RainbowVariables && !current.RainbowIndentGuidesEffective {
		return
	}
	stored := w.sess.values.EditorStoredPreferences
	light, lightChanged := w.rainbowLight.changed(current.RainbowLightColors)
	dark, darkChanged := w.rainbowDark.changed(current.RainbowDarkColors)
	if lightChanged || darkChanged {
		if lightChanged {
			stored.RainbowLightColors = light
		}
		if darkChanged {
			stored.RainbowDarkColors = dark
		}
		if value, ok := w.resolveEditorPresentation(stored); ok {
			w.publishEditorPresentation(stored, value)
			current = value
		}
		w.loadRainbowPalettes(current)
	}
	w.rainbowPaletteRow(c.Part("rainbow-light"), &w.rainbowLight, i18n.Shared(lang, "desktop.editorPrefs.rainbowLightColors"), false, current)
	w.rainbowPaletteRow(c.Part("rainbow-dark"), &w.rainbowDark, i18n.Shared(lang, "desktop.editorPrefs.rainbowDarkColors"), true, current)
}

func (w *window) rainbowPaletteRow(c ui.C, draft *rainbowPaletteEditor, title string, dark bool, current core.EditorPreferences) {
	lang := w.marketLanguage()
	labels := base.ColorPickerLabels{
		Saturation:   i18n.Shared(lang, "desktop.editorPrefs.rainbowSaturation"),
		Hue:          i18n.Shared(lang, "desktop.editorPrefs.rainbowHue"),
		Hex:          i18n.Shared(lang, "desktop.editorPrefs.rainbowHex"),
		InvalidColor: i18n.Shared(lang, "desktop.editorPrefs.rainbowInvalidHex"),
		Clear:        i18n.Shared(lang, "ui.remove"),
		Cancel:       w.text.Settings.Cancel,
		Apply:        i18n.Shared(lang, "ui.save"),
	}
	if len(draft.swatches) == 1 {
		labels.Clear = i18n.Shared(lang, "desktop.editorPrefs.rainbowResetPalette")
	}
	w.settingsRow(c, title, "", func() {
		ui.Row(c.Part("swatches")).Items(ui.Center).Gap(5).Children(func() {
			for i, swatch := range draft.swatches {
				label := i18n.SharedFormat(lang, "desktop.editorPrefs.rainbowPaletteColor", map[string]string{
					"palette": title, "number": strconv.Itoa(i + 1),
				})
				ui.ColorPicker(c.KeyInt(i), &swatch.picker, &swatch.color, label).
					Size(22, 22).RoundTrigger().PanelLabels(labels)
			}
			if len(draft.swatches) < rainbowPaletteCapacity {
				addLabels := labels
				addLabels.Clear = i18n.Shared(lang, "ui.clear")
				label := i18n.SharedFormat(lang, "desktop.editorPrefs.rainbowAddColor", map[string]string{"palette": title})
				ui.ColorPicker(c.Part("add"), &draft.add.picker, &draft.add.color, label).
					Size(22, 22).RoundTrigger().NoColor(true).TriggerIcon(&icons.Plus).PanelLabels(addLabels)
			}
		})
		rainbowPreview(c.Part("preview"), draft, dark, current.RainbowBrackets, current.RainbowVariables)
	})
}

func rainbowPreview(c ui.C, draft *rainbowPaletteEditor, dark, brackets, variables bool) {
	look := paletteFor(dark)
	const opening = "([{"
	const closing = ")]}"
	previewColor := func(i int) gfx.Color {
		swatch := draft.swatches[i]
		if pending, ok := swatch.picker.Draft(); ok {
			return pending
		}
		return swatch.color
	}
	ui.Row(c).Items(ui.Center).Height(22).MarginLeft(12).PadX(5).Radius(4).Background(look.window).
		Stroke(0.5, look.border).Children(func() {
		if !brackets && !variables {
			for i := range draft.swatches {
				ui.Text(c, "│").Mono().Color(previewColor(i)).FontSize(12)
			}
			return
		}
		paint := func(samples string, i int) {
			index := i % len(samples)
			ui.Text(c, samples[index:index+1]).Mono().Color(previewColor(i)).FontSize(12)
		}
		if brackets {
			for i := range draft.swatches {
				paint(opening, i)
			}
		}
		if variables && len(draft.swatches) > 0 {
			color := previewColor(0)
			ui.Text(c, "x").Mono().Color(color).FontSize(12)
			ui.Text(c, "+").Mono().Color(look.text).FontSize(12)
			ui.Text(c, "x").Mono().Color(color).FontSize(12)
		} else {
			ui.Text(c, "x").Mono().Color(look.text).FontSize(12)
		}
		if brackets {
			for i := len(draft.swatches) - 1; i >= 0; i-- {
				paint(closing, i)
			}
		}
	})
}
