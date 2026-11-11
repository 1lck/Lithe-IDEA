package settingswindow

import (
	"context"
)

// The generation choices are Lithe's own preferences: the commit message generator and the
// inline edit pick their provider and output from them. They are stored in the application's
// settings, never in the Codex or Claude configuration, so the page says so. The provider
// lines show what the platform read from those configurations; the page never shows a key.

// AIGenerationSettings are the choices of commit message generation and inline edits.
type AIGenerationSettings struct {
	// Provider is "" for the first usable provider (Codex, then Claude), or "codex" or "claude".
	Provider string `json:"provider,omitempty"`
	// Language is "" to follow the interface, or "english" or "simplifiedChinese".
	Language string `json:"language,omitempty"`
	// IncludeBody asks a commit message generation for a body after the subject.
	IncludeBody bool `json:"includeBody,omitempty"`
	// CustomInstructions are requirements handed to a commit message generation with the
	// changes, such as the tone or what to leave out; empty for none.
	CustomInstructions string `json:"customInstructions,omitempty"`
}

// AIProviderStatus is what the platform read for one AI CLI source. Usable says the source
// holds a provider that generation can call; the key itself is never part of it.
type AIProviderStatus struct {
	Source string
	Name   string
	Model  string
	// Path is the configuration file the provider was read from.
	Path   string
	Usable bool
}

// generationProviderChoices are the provider options in the order they are shown.
var generationProviderChoices = [...]string{"", "codex", "claude"}

// generationLanguageChoices are the output options in the order they are shown.
var generationLanguageChoices = [...]string{"", "english", "simplifiedChinese"}

// generationIndex is the option of a stored value in choices; an unknown value is the first
// option, which is the default.
func generationIndex(choices []string, value string) int {
	for index, choice := range choices {
		if choice == value {
			return index
		}
	}
	return 0
}

// generationState is the provider read the generation card shows. Background work writes it
// under the agentSettings lock.
type generationState struct {
	loaded, loading bool
	providers       []AIProviderStatus
	err             error
}

// generationInstructions is the text of the instructions field of the generation card. A text
// area edits one string in place and keeps its editor state under that string's address, so
// the text lives here, for the life of the window, instead of being copied from the store into
// a fresh variable each paint. It is read and written only by the settings window thread, in a
// paint, so it needs no lock.
type generationInstructions struct {
	// text is the string the text area is bound to.
	text string
	// seen is the stored value as of the last paint. It tells a change of the store from no
	// change, so a value the store keeps showing is not taken for a new edit by someone else.
	seen string
	// sent is the last text this field handed to a save, and waiting says the store has not
	// shown it yet. The owner stores a save when its own window next drains its queue, so for
	// a paint or two after a keystroke the store still shows the text from before it.
	sent    string
	waiting bool
	// started says the first paint has taken in the stored value.
	started bool
}

// sync takes in the stored value a paint read, before the text area is declared. The first
// paint shows the stored value. After that the text is replaced only when the store changes
// to something this field did not send, such as the options of the Commit panel editing the
// same instructions. While a save is unanswered the store may still show an older text,
// which is ignored: replacing the text with it would erase what the user just typed. A
// store that never shows the sent text (it refused or rewrote it) leaves the user's text in
// place until the window is opened again.
func (g *generationInstructions) sync(stored string) {
	switch {
	case !g.started:
		g.text, g.seen, g.started = stored, stored, true
	case g.waiting && stored == g.sent:
		g.seen, g.waiting = stored, false
	case stored == g.seen:
	default:
		g.seen = stored
		if !g.waiting {
			g.text = stored
		}
	}
}

// send records that the text, exactly as typed, is being handed to a save. It is not trimmed
// here: trimming on every keystroke would fight the typing, so whoever uses the text trims it.
func (g *generationInstructions) send() {
	g.sent, g.waiting = g.text, true
}

// generation returns the stored choices; an unset callback means the defaults.
func (s *agentSettings) generation() AIGenerationSettings {
	if s.aiGeneration == nil {
		return AIGenerationSettings{}
	}
	return s.aiGeneration()
}

// saveGeneration hands a changed choice to the settings owner, which stores it.
func (s *agentSettings) saveGeneration(value AIGenerationSettings) {
	if s.setAIGeneration != nil {
		s.setAIGeneration(value)
	}
}

// beginProviders reads the provider lines once, off the window thread.
func (s *agentSettings) beginProviders(force bool) {
	s.mu.Lock()
	st := &s.providerRead
	if s.aiProviders == nil || st.loading || (st.loaded && !force) {
		s.mu.Unlock()
		return
	}
	st.loading, st.err = true, nil
	s.mu.Unlock()
	s.run(func(ctx context.Context) {
		providers := s.aiProviders(ctx)
		s.mu.Lock()
		defer s.mu.Unlock()
		st.loading, st.loaded, st.providers = false, true, providers
	})
}

// providerSourceName is the product name a source is shown under.
func providerSourceName(source string) string {
	if source == "claude" {
		return "Claude Code"
	}
	return "Codex"
}
