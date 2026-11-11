package i18n

import "strconv"

// AgentProcessMessages label the collapsed process of one turn: the thinking, progress text
// and tool calls that come before the reply.
type AgentProcessMessages struct {
	Title func(steps int) string
}

func agentProcessMessages(language Language) AgentProcessMessages {
	return AgentProcessMessages{
		Title: func(steps int) string {
			return SharedFormat(language, "desktop.agent.process.title", map[string]string{"count": strconv.Itoa(steps)})
		},
	}
}
