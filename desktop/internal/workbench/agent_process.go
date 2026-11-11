package workbench

import "github.com/vivaui/viva/ui"

// agentRowSpan is one row of the transcript: a single message, or a turn's process. A process
// spans the messages [from, to) that come before the turn's last thought or tool call, and
// it is collapsed by default, as the macOS transcript shows it.
type agentRowSpan struct {
	from, to int
	process  bool
}

// agentTranscriptRows groups the messages into transcript rows. A user message is always a
// row of its own. Between two user messages, the messages up to the last thought or tool call
// form one process; prose after that is the reply and stays a row of its own.
func agentTranscriptRows(messages []agentMessage) []agentRowSpan {
	rows := make([]agentRowSpan, 0, len(messages))
	for i := 0; i < len(messages); {
		if messages[i].Role == agentRoleUser {
			rows = append(rows, agentRowSpan{from: i, to: i + 1})
			i++
			continue
		}
		end := i
		for end < len(messages) && messages[end].Role != agentRoleUser {
			end++
		}
		last := -1
		for k := i; k < end; k++ {
			if messages[k].Role == agentRoleTool || messages[k].Role == agentRoleThought {
				last = k
			}
		}
		next := i
		if last >= 0 {
			rows = append(rows, agentRowSpan{from: i, to: last + 1, process: true})
			next = last + 1
		}
		for k := next; k < end; k++ {
			rows = append(rows, agentRowSpan{from: k, to: k + 1})
		}
		i = end
	}
	return rows
}

// agentProcessRow declares a turn's process: one line with its step count and a toggle, and
// the messages inside it when it is open. The open state belongs to the process's first
// message, so it survives a repaint.
func (a *App) agentProcessRow(c ui.C, p *project, span agentRowSpan) {
	messages := p.agent.messages
	t := a.text.Agent
	steps := 0
	for k := span.from; k < span.to; k++ {
		if messages[k].Role == agentRoleTool || messages[k].Role == agentRoleThought {
			steps++
		}
	}
	open := messages[span.from].ProcessOpen
	ui.Column(c).FillWidth().Gap(4).PadY(2).Children(func() {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, t.Process.Title(steps)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).Ellipsis()
			label := t.Activity.Expand
			if open {
				label = t.Activity.Collapse
			}
			if a.agentToggle(c.Key("process-toggle"), label) {
				c.After(func() {
					if span.from < len(p.agent.messages) {
						p.agent.messages[span.from].ProcessOpen = !open
					}
				})
			}
		})
		if !open {
			return
		}
		for k := span.from; k < span.to && k < len(messages); k++ {
			if messages[k].Role == agentRoleAssistant {
				a.agentReplyMarkdown(c.KeyInt(k), &messages[k])
				continue
			}
			a.agentActivityRow(c.KeyInt(k), p, k, messages[k])
		}
	})
}
