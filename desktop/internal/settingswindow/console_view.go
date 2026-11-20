package settingswindow

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// consolePage edits the application's decoding preference. Core owns the encodings and
// automatic candidates; opening the page reads the snapshot without changing settings.
func (w *window) consolePage(c ui.C) {
	language := w.marketLanguage()
	encodings, known := w.consoleEncodings()
	w.pageScroll(c, pageConsole, func() {
		w.card(c, i18n.Shared(language, "desktop.consoleSettings.outputCard"), "", func() {
			title := i18n.Shared(language, "desktop.consoleSettings.encoding")
			w.settingsRow(c.Part("encoding-row"), title, i18n.Shared(language, "desktop.consoleSettings.encodingHelp"), func() {
				choices := make([]string, 1, len(encodings.Choices)+1)
				for _, encoding := range encodings.Choices {
					choices = append(choices, encoding.ID)
				}
				value := w.sess.values.ConsoleEncoding
				if ui.Select(c.Part("encoding"), &value, choices, w.consoleEncodingLabel).FillWidth().Label(title).
					Disabled(!known || encodings.Error != "").Changed() {
					w.setConsoleEncoding(value, false)
				}
			})
			if encodings.Error != "" {
				ui.Wrap(c, encodings.Error).FontSize(12).Color(w.pal.danger)
			}
		})
	})
}

func (w *window) consoleEncodings() (ConsoleEncodings, bool) {
	if read := w.ctrl.opts.ConsoleEncodings; read != nil {
		return read()
	}
	return ConsoleEncodings{}, false
}

func (w *window) consoleEncodingLabel(id string) string {
	encodings, known := w.consoleEncodings()
	if id != "" && id != "auto" {
		for _, encoding := range encodings.Choices {
			if encoding.ID == id {
				return encoding.Label
			}
		}
		return id
	}
	language := w.marketLanguage()
	if encodings.Error != "" {
		return i18n.Shared(language, "desktop.consoleSettings.automaticFailed")
	}
	if !known {
		return i18n.Shared(language, "desktop.consoleSettings.automaticPending")
	}
	labels := make([]string, len(encodings.Automatic))
	for index, encoding := range encodings.Automatic {
		labels[index] = encoding.Label
	}
	return i18n.SharedFormat(language, "desktop.consoleSettings.automatic", map[string]string{
		"encodings": strings.Join(labels, i18n.Shared(language, "desktop.consoleSettings.otherwise")),
	})
}
