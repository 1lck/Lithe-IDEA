package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// generationCard is the Agents page's section for commit message generation and inline edits:
// the provider and output choice, the instructions handed to a commit message generation, and
// the provider each source reads from its configuration.
func (w *window) generationCard(c ui.C) {
	s := w.agent
	s.beginProviders(false)
	current := s.generation()
	// The instructions text is brought up to date before the text area is declared, because
	// declaring it is what shows the text; opening the page only reads, so nothing is saved.
	draft := &s.generationDraft
	draft.sync(current.CustomInstructions)
	s.mu.Lock()
	st := s.providerRead
	s.mu.Unlock()
	w.card(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.title"), i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.help"), func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			if st.loading && !st.loaded {
				ui.Text(c, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.loading")).FontSize(12).Color(w.pal.muted)
			}
			for _, source := range []string{"codex", "claude"} {
				ui.Wrap(c.Key("gen/"+source), w.generationSourceLine(w.marketLanguage(), source, st.providers, st.loaded)).FontSize(12).Color(w.pal.muted)
			}
			provider := generationIndex(generationProviderChoices[:], current.Provider)
			providers := []int{0, 1, 2}
			// A bound control writes the user's choice into its value only when it is asked
			// (Changed) or when the page ends, so each is asked before the values are read.
			providerChanged := ui.Select(c.Key("genProvider"), &provider, providers, func(i int) string { return w.generationProviderLabel(i) }).
				Label(i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.provider")).Height(28).Changed()
			language := generationIndex(generationLanguageChoices[:], current.Language)
			languages := []int{0, 1, 2}
			languageChanged := ui.Select(c.Key("genLanguage"), &language, languages, func(i int) string { return w.generationLanguageLabel(i) }).
				Label(i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.language")).Height(28).Changed()
			body := current.IncludeBody
			bodyChanged := ui.Switch(c.Key("genBody"), &body, i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.includeBody")).Changed()
			// The text area is declared in every paint, before anything decides to save, so
			// it is drawn whether or not a choice changed.
			instructionsChanged := w.generationInstructionsField(c, draft)
			if !providerChanged && !languageChanged && !bodyChanged && !instructionsChanged {
				return
			}
			// One value carries every choice, the instructions as typed included, so a
			// choice and an edit delivered in the same paint do not undo each other.
			next := current
			next.Provider = generationProviderChoices[provider]
			next.Language = generationLanguageChoices[language]
			next.IncludeBody = body
			next.CustomInstructions = draft.text
			// The save is handed over in this paint: typing delivers no click, and After runs
			// only after a paint that does. An edit is always saved, even when the text equals
			// the stored value this paint read: the store may be about to show the text from
			// before an earlier keystroke, and skipping the save would leave it there.
			if instructionsChanged {
				draft.send()
				s.saveGeneration(next)
			} else if next != current {
				s.saveGeneration(next)
			}
		})
	})
}

// generationInstructionsField is the multi-line field for the instructions a commit message
// generation is given, under its title and information glyph. It edits the draft in place and
// reports whether this paint finds the text edited; the text is then in draft.text exactly as
// typed.
func (w *window) generationInstructionsField(c ui.C, draft *generationInstructions) bool {
	language := w.marketLanguage()
	label := i18n.Shared(language, "desktop.commit.instructions")
	ui.Row(c.Key("genInstructionsTitle")).FillWidth().Gap(6).Items(ui.Center).Children(func() {
		ui.Text(c, label).FontSize(12).Color(w.pal.text).Ellipsis()
		w.infoButton(c, i18n.Shared(language, "desktop.commit.instructionsHelp"))
	})
	return ui.TextArea(c.Key("genInstructions"), &draft.text, label, i18n.Shared(language, "desktop.commit.instructionsPlaceholder")).
		FillWidth().Height(76).Changed()
}

// generationSourceLine says what one source offers: its provider, model and file, or that it has
// no usable provider with a key. The key is never shown.
func (w *window) generationSourceLine(language i18n.Language, source string, providers []AIProviderStatus, loaded bool) string {
	name := providerSourceName(source)
	if !loaded {
		return name + " · " + i18n.Shared(language, "desktop.settings.agent.loading")
	}
	for _, p := range providers {
		if p.Source != source {
			continue
		}
		if !p.Usable {
			return i18n.SharedFormat(language, "desktop.settings.agent.generation.sourceUnavailable", map[string]string{"source": name})
		}
		return i18n.SharedFormat(language, "desktop.settings.agent.generation.sourceReady", map[string]string{
			"source": name, "name": p.Name, "model": p.Model, "path": p.Path,
		})
	}
	return i18n.SharedFormat(language, "desktop.settings.agent.generation.sourceUnavailable", map[string]string{"source": name})
}

func (w *window) generationProviderLabel(index int) string {
	switch generationProviderChoices[index] {
	case "codex":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.providerCodex")
	case "claude":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.providerClaude")
	}
	return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.providerAuto")
}

func (w *window) generationLanguageLabel(index int) string {
	switch generationLanguageChoices[index] {
	case "english":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.languageEnglish")
	case "simplifiedChinese":
		return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.languageChinese")
	}
	return i18n.Shared(w.marketLanguage(), "desktop.settings.agent.generation.languageInterface")
}
