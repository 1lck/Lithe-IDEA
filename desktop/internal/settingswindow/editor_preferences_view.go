package settingswindow

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

func (w *window) editorPresentationCard(c ui.C) {
	lang := w.marketLanguage()

	values := &w.sess.values
	if !w.editorDelayReady {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		resolved, err := core.NewClient().ResolveEditorPreferences(ctx, values.EditorStoredPreferences)
		cancel()
		if err != nil {
			w.editorPrefsError = i18n.Shared(lang, "desktop.editorPrefs.failed")
			w.reportEssentialsFailure("editor_preferences", err)
		} else {
			values.EditorPreferences = resolved
		}
		w.editorDelay.SetText(strconv.FormatUint(values.EditorPreferences.AutoSaveDelayMilliseconds, 10))
		w.loadRainbowPalettes(values.EditorPreferences)
		w.editorDelayReady = true
	}
	current := values.EditorPreferences
	w.card(c, i18n.Shared(lang, "desktop.editorPrefs.title"), "", func() {
		if ui.Switch(c.Part("line-numbers"), &current.LineNumbers, i18n.Shared(lang, "desktop.editorPrefs.lineNumbers")).Changed() {
			w.setEditorPresentation(current)
		}
		if ui.Switch(c.Part("whitespace"), &current.Whitespace, i18n.Shared(lang, "desktop.editorPrefs.whitespace")).Changed() {
			w.setEditorPresentation(current)
		}
		if ui.Switch(c.Part("indent-guides"), &current.IndentGuides, i18n.Shared(lang, "desktop.editorPrefs.indentGuides")).Changed() {
			w.setEditorPresentation(current)
		}
		ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
			if ui.Switch(c.Part("inlay-hints"), &current.InlayHints, i18n.Shared(lang, "desktop.editorPrefs.inlayHints")).Changed() {
				w.setEditorPresentation(current)
			}
			w.infoButton(c.Part("inlay-hints-info"), i18n.Shared(lang, "desktop.editorPrefs.inlayHintsHelp"))
		})
		ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
			autoCompletion := !values.DisableAutoCompletion
			if ui.Switch(c.Part("auto-completion"), &autoCompletion, i18n.Shared(lang, "desktop.editorPrefs.autoCompletion")).Changed() {
				w.setDisableAutoCompletion(!autoCompletion)
			}
			w.infoButton(c.Part("auto-completion-info"), i18n.Shared(lang, "desktop.editorPrefs.autoCompletionHelp"))
		})
		w.settingsRow(c, i18n.Shared(lang, "desktop.editorPrefs.cursorStyle"), "", func() {
			if ui.Select(c.Part("caret-style"), &current.CursorStyle, []string{"line", "block", "underline"}, func(style string) string {
				switch style {
				case "block":
					return i18n.Shared(lang, "desktop.editorPrefs.block")
				case "underline":
					return i18n.Shared(lang, "desktop.editorPrefs.underline")
				default:
					return i18n.Shared(lang, "desktop.editorPrefs.line")
				}
			}).Width(selectWidth).Label(i18n.Shared(lang, "desktop.editorPrefs.cursorStyle")).Changed() {
				w.setEditorPresentation(current)
			}
		})
		if ui.Switch(c.Part("cursor-blink"), &current.CursorBlink, i18n.Shared(lang, "desktop.editorPrefs.cursorBlink")).Changed() {
			w.setEditorPresentation(current)
		}
		w.settingsRow(c, i18n.Shared(lang, "desktop.editorPrefs.saveDelay"), i18n.Shared(lang, "desktop.editorPrefs.saveDelayHelp"), func() {
			ui.TextField(c.Part("autosave-delay"), &w.editorDelay, i18n.Shared(lang, "desktop.editorPrefs.saveDelay"), "").Width(105)
			if ui.Button(c, w.text.Settings.OK).Outline().Small().Clicked() {
				n, err := strconv.ParseUint(w.editorDelay.Text(), 10, 64)
				if err != nil {
					w.editorPrefsError = i18n.Shared(lang, "desktop.editorPrefs.saveDelayHelp")
					w.reportEssentialsFailure("editor_preferences", errors.New("invalid_autosave_delay"))
				} else {
					current.AutoSaveDelayMilliseconds = n
					w.setEditorPresentation(current)
				}
			}
		})
		if w.editorPrefsError != "" {
			ui.Wrap(c, w.editorPrefsError).Color(w.pal.danger).FontSize(12)
		}
	})
}

func (w *window) setDisableAutoCompletion(value bool) {
	if w.sess.finished.Load() || w.sess.values.DisableAutoCompletion == value {
		return
	}
	w.sess.values.DisableAutoCompletion = value
	if set := w.ctrl.opts.SetDisableAutoCompletion; set != nil {
		set(value)
	}
}

func (w *window) setEditorPresentation(value core.EditorPreferences) {
	stored := w.sess.values.EditorStoredPreferences
	stored.LineNumbers = &value.LineNumbers
	stored.Whitespace = &value.Whitespace
	stored.InlayHints = &value.InlayHints
	stored.CursorStyle = value.CursorStyle
	stored.CursorBlink = &value.CursorBlink
	stored.AutoSaveDelayMilliseconds = &value.AutoSaveDelayMilliseconds
	if value.RainbowBrackets != w.sess.values.EditorPreferences.RainbowBrackets {
		stored.RainbowBrackets = &value.RainbowBrackets
	}
	if value.RainbowVariables != w.sess.values.EditorPreferences.RainbowVariables {
		stored.RainbowVariables = &value.RainbowVariables
	}
	if value.IndentGuides != w.sess.values.EditorPreferences.IndentGuides {
		stored.IndentGuides = &value.IndentGuides
	}
	if value.RainbowIndentGuides != w.sess.values.EditorPreferences.RainbowIndentGuides {
		stored.RainbowIndentGuides = &value.RainbowIndentGuides
	}
	if resolved, ok := w.resolveEditorPresentation(stored); ok {
		stored.AutoSaveDelayMilliseconds = &resolved.AutoSaveDelayMilliseconds
		w.publishEditorPresentation(stored, resolved)
	}
}

func (w *window) resolveEditorPresentation(stored core.EditorStoredPreferences) (core.EditorPreferences, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resolved, err := core.NewClient().ResolveEditorPreferences(ctx, stored)
	if err != nil {
		w.editorPrefsError = i18n.Shared(w.marketLanguage(), "desktop.editorPrefs.failed")
		w.reportEssentialsFailure("editor_preferences", err)
	}
	return resolved, err == nil
}

func (w *window) publishEditorPresentation(stored core.EditorStoredPreferences, resolved core.EditorPreferences) {
	w.sess.values.EditorStoredPreferences, w.sess.values.EditorPreferences = stored, resolved
	w.editorDelay.SetText(strconv.FormatUint(resolved.AutoSaveDelayMilliseconds, 10))
	w.editorPrefsError = ""
	if set := w.ctrl.opts.SetEditorPreferences; set != nil {
		set(stored, resolved)
	}
}

func (w *window) resetEditorPresentation() {
	stored := core.EditorStoredPreferences{}
	if value, ok := w.resolveEditorPresentation(stored); ok {
		w.publishEditorPresentation(stored, value)
		w.loadRainbowPalettes(value)
	}
}
