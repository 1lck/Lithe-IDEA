package i18n

// AgentDetailMessages label the session-detail sidebar of the editor conversation: the
// context usage, the files changed in the current turn and the session statistics. The
// Agent's own words (file names, diagnostics) are never translated here.
type AgentDetailMessages struct {
	Title          string
	Show           string
	Hide           string
	Context        string
	ContextUsed    func(used, size, percent string) string
	ContextUnknown string
	ContextSystem  string
	ContextTools   string
	ContextMessage string
	Changes        string
	ChangesNone    string
	Statistics     string
	Turns          string
	ToolCalls      string
	Duration       string
	Tokens         func(input, output, cacheRead string) string
	NoStatistics   string
}

func agentDetailMessages(language Language) AgentDetailMessages {
	return AgentDetailMessages{
		Title:   Shared(language, "desktop.agent.detail.title"),
		Show:    Shared(language, "desktop.agent.detail.show"),
		Hide:    Shared(language, "desktop.agent.detail.hide"),
		Context: Shared(language, "desktop.agent.detail.context"),
		ContextUsed: func(used, size, percent string) string {
			return SharedFormat(language, "desktop.agent.detail.contextUsed", map[string]string{"used": used, "size": size, "percent": percent})
		},
		ContextUnknown: Shared(language, "desktop.agent.detail.contextUnknown"),
		ContextSystem:  Shared(language, "desktop.agent.detail.contextSystem"),
		ContextTools:   Shared(language, "desktop.agent.detail.contextTools"),
		ContextMessage: Shared(language, "desktop.agent.detail.contextMessages"),
		Changes:        Shared(language, "desktop.agent.detail.changes"),
		ChangesNone:    Shared(language, "desktop.agent.detail.changesNone"),
		Statistics:     Shared(language, "desktop.agent.detail.statistics"),
		Turns:          Shared(language, "desktop.agent.detail.turns"),
		ToolCalls:      Shared(language, "desktop.agent.detail.toolCalls"),
		Duration:       Shared(language, "desktop.agent.detail.duration"),
		Tokens: func(input, output, cacheRead string) string {
			return SharedFormat(language, "desktop.agent.detail.tokens", map[string]string{"input": input, "output": output, "cacheRead": cacheRead})
		},
		NoStatistics: Shared(language, "desktop.agent.detail.noStatistics"),
	}
}
