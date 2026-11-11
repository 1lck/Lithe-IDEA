package i18n

// AgentReplyMessages label the actions under an assistant reply: copying a code block and
// putting it into the composer.
type AgentReplyMessages struct {
	CopyCode   string
	InsertCode string
	Link       string
}

func agentReplyMessages(language Language) AgentReplyMessages {
	return AgentReplyMessages{
		CopyCode:   Shared(language, "desktop.agent.reply.copyCode"),
		InsertCode: Shared(language, "desktop.agent.reply.insertCode"),
		Link:       Shared(language, "desktop.agent.reply.link"),
	}
}
