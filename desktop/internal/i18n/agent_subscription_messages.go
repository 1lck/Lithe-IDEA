package i18n

// AgentSubscriptionMessages label the official-subscription routes of an Agent
// provider. Account names and email addresses come from the Agent and are never
// translated here.
type AgentSubscriptionMessages struct {
	CodexProvider string
	SignIn        string
}

func agentSubscriptionMessages(language Language) AgentSubscriptionMessages {
	return AgentSubscriptionMessages{
		CodexProvider: Shared(language, "desktop.agent.subscription.codexProvider"),
		SignIn:        Shared(language, "desktop.agent.subscription.signIn"),
	}
}
