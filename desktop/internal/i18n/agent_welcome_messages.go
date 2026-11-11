package i18n

// AgentWelcomeMessages label the welcome page the Agent panel shows until an Agent is chosen.
type AgentWelcomeMessages struct {
	Title          string
	BannerTitle    string
	BannerBody     string
	ChooseAgent    string
	Codex          string
	Claude         string
	MoreAgents     string
	MoreSubtitle   string
	ProviderTitle  string
	ProviderButton string
}

func agentWelcomeMessages(language Language) AgentWelcomeMessages {
	return AgentWelcomeMessages{
		Title:          Shared(language, "desktop.agent.welcome.title"),
		BannerTitle:    Shared(language, "desktop.agent.welcome.bannerTitle"),
		BannerBody:     Shared(language, "desktop.agent.welcome.bannerBody"),
		ChooseAgent:    Shared(language, "desktop.agent.welcome.chooseAgent"),
		Codex:          Shared(language, "desktop.agent.welcome.codex"),
		Claude:         Shared(language, "desktop.agent.welcome.claude"),
		MoreAgents:     Shared(language, "desktop.agent.welcome.moreAgents"),
		MoreSubtitle:   Shared(language, "desktop.agent.welcome.moreSubtitle"),
		ProviderTitle:  Shared(language, "desktop.agent.welcome.providerTitle"),
		ProviderButton: Shared(language, "desktop.agent.welcome.providerButton"),
	}
}
