package i18n

// AgentProviderMessages label the read-only details of the provider the Agent setup
// selects. Values such as the endpoint and model come from the user's own configuration
// and are never translated here.
type AgentProviderMessages struct {
	Detail         string
	Source         string
	Endpoint       string
	Model          string
	Protocol       string
	Authentication string
	Key            string
	KeyFound       string
	KeyMissing     string
	ReadOnly       string
}

func agentProviderMessages(language Language) AgentProviderMessages {
	return AgentProviderMessages{
		Detail:         Shared(language, "desktop.agent.provider.detail"),
		Source:         Shared(language, "desktop.agent.provider.source"),
		Endpoint:       Shared(language, "desktop.agent.provider.endpoint"),
		Model:          Shared(language, "desktop.agent.provider.model"),
		Protocol:       Shared(language, "desktop.agent.provider.protocol"),
		Authentication: Shared(language, "desktop.agent.provider.authentication"),
		Key:            Shared(language, "desktop.agent.provider.key"),
		KeyFound:       Shared(language, "desktop.agent.provider.keyFound"),
		KeyMissing:     Shared(language, "desktop.agent.provider.keyMissing"),
		ReadOnly:       Shared(language, "desktop.agent.provider.readOnly"),
	}
}
