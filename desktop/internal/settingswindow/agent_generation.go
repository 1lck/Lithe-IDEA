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
