package i18n

// AgentCardMessages label the Claude Desktop cards in an Agent conversation. The
// card's own text (titles, summaries, prompts, replies, paths) is the Agent's and
// is never translated here.
type AgentCardMessages struct {
	NextStep                                          string
	TaskProposed, TaskWithdrawn                       string
	TaskStarted, TaskHandedOff, StartTask             string
	PullRequestBound, PullRequestUnbound              string
	PullRequestMonitored, PullRequestMonitoredAutoFix string
	PullRequestAutoMergeOn, PullRequestAutoMergeOff   string
	OpenPullRequest                                   string
	OpenPullRequestFailed                             func(reason string) string
	DirectoryChanged, DirectoryRequested              string
	Widget, WidgetNotRendered                         string
}

func agentCardMessages(language Language) AgentCardMessages {
	return AgentCardMessages{
		NextStep:                    Shared(language, "desktop.agent.card.nextStep"),
		TaskProposed:                Shared(language, "desktop.agent.card.taskProposed"),
		TaskWithdrawn:               Shared(language, "desktop.agent.card.taskWithdrawn"),
		TaskStarted:                 Shared(language, "desktop.agent.card.taskStarted"),
		TaskHandedOff:               Shared(language, "desktop.agent.card.taskHandedOff"),
		StartTask:                   Shared(language, "desktop.agent.card.startTask"),
		PullRequestBound:            Shared(language, "desktop.agent.card.pullRequestBound"),
		PullRequestUnbound:          Shared(language, "desktop.agent.card.pullRequestUnbound"),
		PullRequestMonitored:        Shared(language, "desktop.agent.card.pullRequestMonitored"),
		PullRequestMonitoredAutoFix: Shared(language, "desktop.agent.card.pullRequestMonitoredAutoFix"),
		PullRequestAutoMergeOn:      Shared(language, "desktop.agent.card.pullRequestAutoMergeOn"),
		PullRequestAutoMergeOff:     Shared(language, "desktop.agent.card.pullRequestAutoMergeOff"),
		OpenPullRequest:             Shared(language, "desktop.agent.card.openPullRequest"),
		OpenPullRequestFailed: func(reason string) string {
			return SharedFormat(language, "desktop.agent.card.openPullRequestFailed", map[string]string{"reason": reason})
		},
		DirectoryChanged:   Shared(language, "desktop.agent.card.directoryChanged"),
		DirectoryRequested: Shared(language, "desktop.agent.card.directoryRequested"),
		Widget:             Shared(language, "desktop.agent.card.widget"),
		WidgetNotRendered:  Shared(language, "desktop.agent.card.widgetNotRendered"),
	}
}
