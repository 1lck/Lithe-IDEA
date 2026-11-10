package i18n

import "strconv"

// AIMessages are the words of the AI-assisted features: commit message generation, inline
// edits, and the MCP and IDE API settings.
type AIMessages struct {
	Commit AICommitMessages
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
