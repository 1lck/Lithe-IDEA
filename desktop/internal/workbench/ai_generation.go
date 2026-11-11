package workbench

import (
	"context"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// This file keeps the provider and output choice of commit message generation and inline
// edits (matrix ids ai-commit-generation, ai-inline-edit). The choice is Lithe's own setting
// and never written into the Codex or Claude configuration. The provider each source offers
// comes from the same discovery the generation uses, so the Agents page shows what it reads.

// aiGenerationSettings is the stored choice; it is read on the window thread.
func (a *App) aiGenerationSettings() settingswindow.AIGenerationSettings {
	return a.settings.AIGeneration
}

// setAIGenerationSettings stores a choice and refreshes the settings window.
func (a *App) setAIGenerationSettings(value settingswindow.AIGenerationSettings) {
	if a.settings.AIGeneration == value {
		return
	}
	a.settings.AIGeneration = value
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
	a.saveSettings()
}

// aiInstructionsDraft is the text the commit options edit of the generation instructions. A
// text area keeps its editor under the address of the string it edits, so the text lives here
// rather than in the stored settings, which a save replaces; synced is the stored value it
// last agreed with, so a change made in the settings window replaces the draft and a draft
// being typed is never reset by its own saves.
type aiInstructionsDraft struct {
	text, synced string
}

// instructionsDraft is the draft of the generation instructions, first brought up to date
// with the stored value when that changed elsewhere.
func (a *App) instructionsDraft() *string {
	if stored := a.settings.AIGeneration.CustomInstructions; stored != a.instructions.synced {
		a.instructions.text, a.instructions.synced = stored, stored
	}
	return &a.instructions.text
}

// storeInstructionsDraft stores the instructions typed in the commit options, as the settings
// window stores a choice; the text is kept as typed, and a generation trims it. The settings
// window paints on the same event-loop thread, so it reads the value only between paints.
func (a *App) storeInstructionsDraft() {
	value := a.settings.AIGeneration
	value.CustomInstructions = a.instructions.text
	a.instructions.synced = value.CustomInstructions
	a.setAIGenerationSettings(value)
}

// aiGenerationSources are the AI CLI sources the choice allows, in the order generation tries
// them. It is read on the window thread and the list is handed to the background work.
func (a *App) aiGenerationSources() []string {
	if provider := a.aiGenerationSettings().Provider; provider != "" {
		return []string{provider}
	}
	return agentProviderSources()
}

// aiProviderStatuses reports, for each source, the provider discovery reads and the native
// configuration file it comes from. It runs off the window thread and never returns a key.
func (a *App) aiProviderStatuses(ctx context.Context) []settingswindow.AIProviderStatus {
	providers, _ := a.discoverAgentProviders(ctx)
	var out []settingswindow.AIProviderStatus
	for _, source := range agentProviderSources() {
		status := settingswindow.AIProviderStatus{Source: source, Path: a.aiConfigurationPath(ctx, source)}
		if provider, ok := pickAIProviderFrom(providers, []string{source}); ok {
			status.Name, status.Model, status.Usable = provider.Name, provider.Model, true
		}
		out = append(out, status)
	}
	return out
}

// aiConfigurationPath is the first native file of a source that exists, or the first file Core
// names when none does. Empty means Core named no file.
func (a *App) aiConfigurationPath(ctx context.Context, source string) string {
	if a.agentKernel == nil {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	files, err := a.agentKernel.AIConfigurationSources(ctx, source, home, agentEnvironment())
	if err != nil || len(files) == 0 {
		return ""
	}
	for _, file := range files {
		if _, err := os.Stat(file.Path); err == nil {
			return file.Path
		}
	}
	return files[0].Path
}
