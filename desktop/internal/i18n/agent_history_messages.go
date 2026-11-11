package i18n

// AgentHistoryMetaMessages label the conversation actions of the history list: pinning,
// renaming and the Lithe-owned annotations shown beside a conversation.
type AgentHistoryMetaMessages struct {
	Pin           string
	Unpin         string
	Rename        string
	Pinned        string
	Save          string
	Cancel        string
	Search        string
	FilterAll     string
	FilterPinned  string
	FilterRemoved string
	Remove        string
	Restore       string
}

func agentHistoryMetaMessages(language Language) AgentHistoryMetaMessages {
	return AgentHistoryMetaMessages{
		Pin:           Shared(language, "desktop.agent.history.pin"),
		Unpin:         Shared(language, "desktop.agent.history.unpin"),
		Rename:        Shared(language, "desktop.agent.history.rename"),
		Pinned:        Shared(language, "desktop.agent.history.pinned"),
		Save:          Shared(language, "desktop.agent.history.save"),
		Cancel:        Shared(language, "desktop.agent.history.cancel"),
		Search:        Shared(language, "desktop.agent.history.search"),
		FilterAll:     Shared(language, "desktop.agent.history.filterAll"),
		FilterPinned:  Shared(language, "desktop.agent.history.filterPinned"),
		FilterRemoved: Shared(language, "desktop.agent.history.filterRemoved"),
		Remove:        Shared(language, "desktop.agent.history.remove"),
		Restore:       Shared(language, "desktop.agent.history.restore"),
	}
}
