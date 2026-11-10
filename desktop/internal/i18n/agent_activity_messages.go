package i18n

// AgentActivityMessages are the words around the Agent's tool calls, reasoning,
// plan, usage, statistics, quota and subagents. The text those rows carry (tool
// titles, plan steps, command names, subagent names) is Agent-owned and is never
// translated here.
type AgentActivityMessages struct {
	Expand, Collapse, Thought string
	ToolStatus                func(status string) string
	Plan                      func(done, total string) string
	PlanStatus                func(status string) string
	Context                   func(used, size, percent string) string
	Statistics                func(steps, input, cacheRead, output string) string
	StatisticsLatency         func(first, speed string) string
	StatisticsLowerBound      string
	StatisticsFailed          func(failed string) string
	TurnUsage                 func(total, input, output string) string
	Quiet, Retrying           string
	Quota                     func(name, percent string) string
	QuotaReset                func(time string) string
	QuotaRefresh              string
	QuotaFailed               func(code string) string
	Subagents                 func(count string) string
	SubagentTask              func(task string) string
	SubagentState             func(state string) string
	CommandHint               func(name, hint string) string

	SteerSend, SteerPending, SteerReceived, SteerQueued, SteerFailed string
	AttachCurrent                                                    string
	RemoveFile, AttachedFile                                         func(name string) string
	SkillsLoading, NoCommand                                         string

	ArchivedTitle                                                                                          func(count string) string
	ArchivedRestore, ArchivedCancel, ArchivedFailed, ArchivedListFailed, ArchivedEmpty, ArchivedIncomplete string
	ArchivedConfirm                                                                                        func(title string) string
}

func agentActivityMessages(language Language) AgentActivityMessages {
	return AgentActivityMessages{
		Expand:   Shared(language, "desktop.agent.activity.expand"),
		Collapse: Shared(language, "desktop.agent.activity.collapse"),
		Thought:  Shared(language, "desktop.agent.activity.thought"),
		ToolStatus: func(value string) string {
			switch value {
			case "pending":
				return Shared(language, "desktop.agent.activity.toolStatus.pending")
			case "in_progress":
				return Shared(language, "desktop.agent.activity.toolStatus.inProgress")
			case "completed":
				return Shared(language, "desktop.agent.activity.toolStatus.completed")
			case "failed":
				return Shared(language, "desktop.agent.activity.toolStatus.failed")
			}
			return value
		},
		Plan: func(done, total string) string {
			return SharedFormat(language, "desktop.agent.activity.plan", map[string]string{"done": done, "total": total})
		},
		PlanStatus: func(value string) string {
			switch value {
			case "pending":
				return Shared(language, "desktop.agent.activity.planStatus.pending")
			case "in_progress":
				return Shared(language, "desktop.agent.activity.planStatus.inProgress")
			case "completed":
				return Shared(language, "desktop.agent.activity.planStatus.completed")
			}
			return value
		},
		Context: func(used, size, percent string) string {
			return SharedFormat(language, "desktop.agent.activity.context", map[string]string{"used": used, "size": size, "percent": percent})
		},
		Statistics: func(steps, input, cacheRead, output string) string {
			return SharedFormat(language, "desktop.agent.activity.statistics", map[string]string{"steps": steps, "input": input, "cacheRead": cacheRead, "output": output})
		},
		StatisticsLatency: func(first, speed string) string {
			return SharedFormat(language, "desktop.agent.activity.statisticsLatency", map[string]string{"first": first, "speed": speed})
		},
		StatisticsLowerBound: Shared(language, "desktop.agent.activity.statisticsLowerBound"),
		StatisticsFailed: func(failed string) string {
			return SharedFormat(language, "desktop.agent.activity.statisticsFailed", map[string]string{"failed": failed})
		},
		TurnUsage: func(total, input, output string) string {
			return SharedFormat(language, "desktop.agent.activity.turnUsage", map[string]string{"total": total, "input": input, "output": output})
		},
		Quiet:    Shared(language, "desktop.agent.activity.quiet"),
		Retrying: Shared(language, "desktop.agent.activity.retrying"),
		Quota: func(name, percent string) string {
			return SharedFormat(language, "desktop.agent.activity.quota", map[string]string{"name": name, "percent": percent})
		},
		QuotaReset: func(time string) string {
			return SharedFormat(language, "desktop.agent.activity.quotaReset", map[string]string{"time": time})
		},
		QuotaRefresh: Shared(language, "desktop.agent.activity.quotaRefresh"),
		QuotaFailed: func(code string) string {
			return SharedFormat(language, "desktop.agent.activity.quotaFailed", map[string]string{"code": code})
		},
		Subagents: func(count string) string {
			return SharedFormat(language, "desktop.agent.activity.subagents", map[string]string{"count": count})
		},
		SubagentTask: func(task string) string {
			return SharedFormat(language, "desktop.agent.activity.subagentTask", map[string]string{"task": task})
		},
		SubagentState: func(value string) string {
			switch value {
			case "running":
				return Shared(language, "desktop.agent.activity.subagentState.running")
			case "completed":
				return Shared(language, "desktop.agent.activity.subagentState.completed")
			case "failed":
				return Shared(language, "desktop.agent.activity.subagentState.failed")
			case "cancelled":
				return Shared(language, "desktop.agent.activity.subagentState.cancelled")
			case "disconnected":
				return Shared(language, "desktop.agent.activity.subagentState.disconnected")
			}
			return value
		},
		SteerSend:     Shared(language, "desktop.agent.steer.send"),
		SteerPending:  Shared(language, "desktop.agent.steer.pending"),
		SteerReceived: Shared(language, "desktop.agent.steer.received"),
		SteerQueued:   Shared(language, "desktop.agent.steer.queued"),
		SteerFailed:   Shared(language, "desktop.agent.steer.failed"),
		AttachCurrent: Shared(language, "desktop.agent.files.attachCurrent"),
		RemoveFile: func(name string) string {
			return SharedFormat(language, "desktop.agent.files.remove", map[string]string{"name": name})
		},
		AttachedFile: func(name string) string {
			return SharedFormat(language, "desktop.agent.files.attached", map[string]string{"name": name})
		},
		ArchivedTitle: func(count string) string {
			return SharedFormat(language, "desktop.agent.archived.title", map[string]string{"count": count})
		},
		ArchivedRestore:    Shared(language, "desktop.agent.archived.restore"),
		ArchivedCancel:     Shared(language, "desktop.agent.archived.cancel"),
		ArchivedFailed:     Shared(language, "desktop.agent.archived.failed"),
		ArchivedListFailed: Shared(language, "desktop.agent.archived.listFailed"),
		ArchivedEmpty:      Shared(language, "desktop.agent.archived.empty"),
		ArchivedIncomplete: Shared(language, "desktop.agent.archived.incomplete"),
		ArchivedConfirm: func(title string) string {
			return SharedFormat(language, "desktop.agent.archived.confirm", map[string]string{"title": title})
		},
		SkillsLoading: Shared(language, "desktop.agent.slash.skills"),
		NoCommand:     Shared(language, "desktop.agent.slash.none"),
		CommandHint: func(name, hint string) string {
			return SharedFormat(language, "desktop.agent.activity.commandHint", map[string]string{"name": name, "hint": hint})
		},
	}
}
