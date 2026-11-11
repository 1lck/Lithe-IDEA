package workbench

import (
	"encoding/json"
	"fmt"
	"net/url"

	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// Claude Desktop injects MCP tools (chapters, suggested replies, tasks, pull
// requests, working folders, visualizations) into a Claude session. Core names
// them and attaches a card in _meta.lithe.claudeDesktop of tool_call and
// tool_call_update (shared/contracts/application-boundary.md, "Claude Desktop
// 机制卡片"); this file decodes the card and draws it in place of the plain tool
// row. A card that is unknown or incomplete leaves the plain row, a later card
// replaces an earlier one, and an update without a card keeps it. Card actions only
// fill the composer: nothing is sent for the user.
const (
	// agentCardTextLimit is Core's limit on a card's text fields, applied again
	// so a malformed event cannot grow a row past it.
	agentCardTextLimit = 16 << 10
	// agentCardWidgetLimit is Core's limit on a visualization's source.
	agentCardWidgetLimit = 256 << 10
	// agentCardActionLimit is the most suggested replies one card carries.
	agentCardActionLimit = 4
)

type agentCardKind string

const (
	agentCardChapter     agentCardKind = "chapter"
	agentCardNextStep    agentCardKind = "nextStep"
	agentCardTask        agentCardKind = "task"
	agentCardPullRequest agentCardKind = "pullRequest"
	agentCardDirectory   agentCardKind = "directory"
	agentCardWidget      agentCardKind = "widget"
)

// agentCardAction is one suggested reply: the label on its button and the message
// it puts in the composer.
type agentCardAction struct {
	Label   string `json:"label"`
	Message string `json:"message"`
}

// agentCard is one decoded card. Which fields are meaningful depends on Kind; the
// text is the Agent's own words and is shown untranslated.
type agentCard struct {
	Kind    agentCardKind     `json:"card"`
	Title   string            `json:"title"`
	Summary string            `json:"summary"`
	Prompt  string            `json:"prompt"`
	State   string            `json:"state"`
	Actions []agentCardAction `json:"actions"`
	Action  string            `json:"action"`
	URL     string            `json:"url"`
	Number  int               `json:"number"`
	AutoFix *bool             `json:"autoFix"`
	Enabled *bool             `json:"enabled"`
	Path    string            `json:"path"`
	Code    string            `json:"code"`
}

// decodeAgentCard reads the card in an update's _meta. It returns nil when there
// is none, or when it is of an unknown kind or misses a field its kind needs.
func decodeAgentCard(meta json.RawMessage) *agentCard {
	if len(meta) == 0 {
		return nil
	}
	var wire struct {
		Lithe struct {
			ClaudeDesktop json.RawMessage `json:"claudeDesktop"`
		} `json:"lithe"`
	}
	if json.Unmarshal(meta, &wire) != nil || len(wire.Lithe.ClaudeDesktop) == 0 {
		return nil
	}
	var card agentCard
	if json.Unmarshal(wire.Lithe.ClaudeDesktop, &card) != nil {
		return nil
	}
	for _, field := range []*string{&card.Title, &card.Summary, &card.Prompt, &card.Path} {
		*field = agentDisplayPrefix(*field, agentCardTextLimit)
	}
	if len(card.Code) > agentCardWidgetLimit {
		card.Code = ""
	}
	if !card.valid() {
		return nil
	}
	return &card
}

// valid reports that the card has what its kind needs to be drawn.
func (card *agentCard) valid() bool {
	switch card.Kind {
	case agentCardChapter, agentCardWidget:
		return card.Title != ""
	case agentCardNextStep:
		if len(card.Actions) == 0 || len(card.Actions) > agentCardActionLimit {
			return false
		}
		for i := range card.Actions {
			action := &card.Actions[i]
			action.Label = agentDisplayPrefix(action.Label, agentCardTextLimit)
			action.Message = agentDisplayPrefix(action.Message, agentCardTextLimit)
			if action.Label == "" || action.Message == "" {
				return false
			}
		}
		return true
	case agentCardTask:
		switch card.State {
		case "proposed", "withdrawn", "started", "handedOff":
			return card.Title != ""
		}
	case agentCardPullRequest:
		if !agentCardWebURL(card.URL) {
			return false
		}
		switch card.Action {
		case "bound", "unbound", "monitored":
			return true
		case "autoMerge":
			return card.Enabled != nil
		}
	case agentCardDirectory:
		return (card.Action == "changed" || card.Action == "requested") && card.Path != ""
	}
	return false
}

// agentCardWebURL reports an absolute http(s) address, the only kind a pull
// request card opens.
func agentCardWebURL(address string) bool {
	parsed, err := url.Parse(address)
	return err == nil && (parsed.Scheme == "https" || parsed.Scheme == "http") && parsed.Host != ""
}

// size is what the card adds to the transcript's byte budget.
func (card *agentCard) size() int {
	if card == nil {
		return 0
	}
	size := len(card.Title) + len(card.Summary) + len(card.Prompt) + len(card.URL) + len(card.Path) + len(card.Code)
	for _, action := range card.Actions {
		size += len(action.Label) + len(action.Message)
	}
	return size
}

// fillAgentComposer replaces the composer's draft with a card's message, as one
// edit the user can undo. It does not send.
func (a *App) fillAgentComposer(p *project, message string) {
	if p == nil || p.agent.editor == nil {
		return
	}
	editor := p.agent.editor
	editor.ReplaceRange(text.Range{Start: 0, End: editor.RuneCount()}, message)
	a.performed("agent.card.fill", surfaceButton)
}

// startAgentTask starts a new conversation and puts a suggested task's prompt in
// its composer, which a new session keeps. The user sends it.
func (a *App) startAgentTask(p *project, prompt string) {
	if !a.agentCanStartConversation(p) {
		return
	}
	a.newAgentConversation(p)
	a.fillAgentComposer(p, prompt)
}

// agentRepliesCurrent reports that suggested replies at index still answer the
// conversation: no turn of the user's follows them and no reply is streaming.
func agentRepliesCurrent(p *project, index int) bool {
	if p.agent.phase == agentPhaseBusy || p.agent.phase == agentPhaseCancelling {
		return false
	}
	for _, m := range p.agent.messages[min(index+1, len(p.agent.messages)):] {
		if m.Role == agentRoleUser {
			return false
		}
	}
	return true
}

// agentCardRow draws a completed tool call's card at index of the transcript. The
// caller has checked that the call completed and carries a card.
func (a *App) agentCardRow(c ui.C, p *project, index int, tool *agentToolCall) {
	t := a.text.Agent.Card
	card := tool.Card
	if card.Kind == agentCardNextStep && !agentRepliesCurrent(p, index) {
		return
	}
	small := a.theme.Metrics.FontSizeS
	header := func(label string) {
		ui.Text(c.Key("header"), label).FontSize(small).Color(a.colors.Subtle).Ellipsis()
	}
	ui.Column(c).FillWidth().Gap(4).PadY(4).Children(func() {
		switch card.Kind {
		case agentCardChapter:
			ui.Divider(c.Key("rule"))
			ui.Text(c.Key("title"), card.Title).Bold().Color(a.colors.Text).Ellipsis()
			if card.Summary != "" {
				ui.Wrap(c.Key("summary"), card.Summary).FontSize(small).Color(a.colors.Subtle)
			}
		case agentCardNextStep:
			header(t.NextStep)
			ui.Flow(c.Key("actions")).Gap(6).Children(func() {
				for i, action := range card.Actions {
					if ui.Button(c.KeyInt(i), action.Label).Clicked() {
						message := action.Message
						c.After(func() { a.fillAgentComposer(p, message) })
					}
				}
			})
		case agentCardTask:
			header(a.agentTaskState(card.State))
			ui.Text(c.Key("title"), card.Title).Color(a.colors.Text).Ellipsis()
			if card.Summary != "" {
				ui.Wrap(c.Key("summary"), card.Summary).FontSize(small).Color(a.colors.Subtle)
			}
			if card.Prompt != "" && card.State != "withdrawn" {
				start := ui.Button(c.Key("start"), t.StartTask).Ghost().Disabled(!a.agentCanStartConversation(p))
				if start.Clicked() {
					prompt := card.Prompt
					c.After(func() { a.startAgentTask(p, prompt) })
				}
			}
		case agentCardPullRequest:
			header(a.agentPullRequestState(card))
			label := card.URL
			if card.Number > 0 {
				label = fmt.Sprintf("#%d", card.Number)
			}
			ui.Row(c.Key("link")).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, label).Color(a.colors.Text).Ellipsis().Grow(1)
				if ui.Button(c.Key("open"), t.OpenPullRequest).Ghost().Clicked() {
					address := card.URL
					c.After(func() {
						if err := openURL(address); err != nil {
							a.notifyError(t.OpenPullRequestFailed(err.Error()))
						}
					})
				}
			})
		case agentCardDirectory:
			label := t.DirectoryChanged
			if card.Action == "requested" {
				label = t.DirectoryRequested
			}
			header(label)
			ui.Text(c.Key("path"), card.Path).Color(a.colors.Text).Ellipsis()
		case agentCardWidget:
			header(t.Widget)
			ui.Row(c.Key("title")).FillWidth().Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, card.Title).Color(a.colors.Text).Ellipsis().Grow(1)
				if card.Code != "" {
					label := a.text.Agent.Activity.Expand
					if tool.Expanded {
						label = a.text.Agent.Activity.Collapse
					}
					if a.agentToggle(c.Key("toggle"), label) {
						c.After(func() { tool.Expanded = !tool.Expanded })
					}
				}
			})
			ui.Wrap(c.Key("note"), t.WidgetNotRendered).FontSize(small).Color(a.colors.Subtle)
			if tool.Expanded && card.Code != "" {
				ui.Wrap(c.Key("code"), agentDisplayPrefix(card.Code, agentToolOutputLimit)).FontSize(small).Color(a.colors.Subtle)
			}
		}
	})
}

// agentTaskState labels where a suggested task is.
func (a *App) agentTaskState(state string) string {
	t := a.text.Agent.Card
	switch state {
	case "withdrawn":
		return t.TaskWithdrawn
	case "started":
		return t.TaskStarted
	case "handedOff":
		return t.TaskHandedOff
	}
	return t.TaskProposed
}

// agentPullRequestState labels what the Agent did with a pull request.
func (a *App) agentPullRequestState(card *agentCard) string {
	t := a.text.Agent.Card
	switch card.Action {
	case "unbound":
		return t.PullRequestUnbound
	case "monitored":
		if card.AutoFix != nil && *card.AutoFix {
			return t.PullRequestMonitoredAutoFix
		}
		return t.PullRequestMonitored
	case "autoMerge":
		if *card.Enabled {
			return t.PullRequestAutoMergeOn
		}
		return t.PullRequestAutoMergeOff
	}
	return t.PullRequestBound
}

// agentCardShown reports that a tool row draws its card: only a completed call
// shows one, so a pending or failed call keeps the plain row.
func agentCardShown(tool *agentToolCall) bool {
	return tool != nil && tool.Card != nil && tool.Status == "completed"
}
