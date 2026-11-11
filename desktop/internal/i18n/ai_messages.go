package i18n

import "strconv"

// AIMessages are the words of the AI-assisted features: commit message generation, inline
// edits, and the MCP and IDE API settings.
type AIMessages struct {
	Commit     AICommitMessages
	InlineEdit AIInlineEditMessages
}

// AIInlineEditMessages are the words of the editor's AI inline edit.
type AIInlineEditMessages struct {
	Title, ReviewTitle, Instruction, Run, Running, Cancel, Accept, Reject string
	NoSelection, ReadOnly, Empty, Stale, Unchanged                        string
	// Provider labels the picker that chooses the configuration the edit is sent with;
	// ProviderDefault is the choice that follows the AI settings.
	Provider, ProviderDefault, ProviderCodex, ProviderClaude string
	Failed                                                   func(reason string) string
}

// AICommitMessages are the words of the Commit panel's "generate message" action.
type AICommitMessages struct {
	Generate         string
	Generating       string
	Cancel           string
	NoProvider       string
	Stale            string
	ReplaceTitle     string
	ReplaceBody      string
	Replace          string
	Keep             string
	ResponseTooLarge string
	Timeout          string
	// Failed reports a generation that did not produce a message.
	Failed func(reason string) string
	// HTTPStatus reports a provider answer that was not a success; the body is never shown.
	HTTPStatus func(status int) string
}

func aiMessages(language Language) AIMessages {
	return AIMessages{
		InlineEdit: AIInlineEditMessages{
			Title:           Shared(language, "desktop.inlineEdit.title"),
			ReviewTitle:     Shared(language, "desktop.inlineEdit.reviewTitle"),
			Instruction:     Shared(language, "desktop.inlineEdit.instruction"),
			Run:             Shared(language, "desktop.inlineEdit.run"),
			Running:         Shared(language, "desktop.inlineEdit.running"),
			Cancel:          Shared(language, "desktop.inlineEdit.cancel"),
			Accept:          Shared(language, "desktop.inlineEdit.accept"),
			Reject:          Shared(language, "desktop.inlineEdit.reject"),
			NoSelection:     Shared(language, "desktop.inlineEdit.noSelection"),
			ReadOnly:        Shared(language, "desktop.inlineEdit.readOnly"),
			Empty:           Shared(language, "desktop.inlineEdit.empty"),
			Stale:           Shared(language, "desktop.inlineEdit.stale"),
			Unchanged:       Shared(language, "desktop.inlineEdit.unchanged"),
			Provider:        Shared(language, "desktop.inlineEdit.provider"),
			ProviderDefault: Shared(language, "desktop.inlineEdit.providerDefault"),
			ProviderCodex:   Shared(language, "desktop.inlineEdit.providerCodex"),
			ProviderClaude:  Shared(language, "desktop.inlineEdit.providerClaude"),
			Failed: func(reason string) string {
				return SharedFormat(language, "desktop.inlineEdit.failed", map[string]string{"reason": reason})
			},
		},
		Commit: AICommitMessages{
			Generate:         Shared(language, "desktop.aiCommit.generate"),
			Generating:       Shared(language, "desktop.aiCommit.generating"),
			Cancel:           Shared(language, "desktop.aiCommit.cancel"),
			NoProvider:       Shared(language, "desktop.aiCommit.noProvider"),
			Stale:            Shared(language, "desktop.aiCommit.stale"),
			ReplaceTitle:     Shared(language, "desktop.aiCommit.replaceTitle"),
			ReplaceBody:      Shared(language, "desktop.aiCommit.replaceBody"),
			Replace:          Shared(language, "desktop.aiCommit.replace"),
			Keep:             Shared(language, "desktop.aiCommit.keep"),
			ResponseTooLarge: Shared(language, "desktop.aiCommit.responseTooLarge"),
			Timeout:          Shared(language, "desktop.aiCommit.timeout"),
			Failed: func(reason string) string {
				return SharedFormat(language, "desktop.aiCommit.failed", map[string]string{"reason": reason})
			},
			HTTPStatus: func(status int) string {
				return SharedFormat(language, "desktop.aiCommit.httpStatus", map[string]string{"status": strconv.Itoa(status)})
			},
		},
	}
}
