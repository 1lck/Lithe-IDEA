package workbench

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"

	"github.com/vivaui/viva/app"
)

// agentExportSuggestedName is the file name the export dialog starts with.
const agentExportSuggestedName = "agent-conversation.md"

// agentTranscriptMarkdown renders the open conversation as Markdown.
func (a *App) agentTranscriptMarkdown(p *project) string {
	return a.agentMessagesMarkdown(p.agent.messages, a.agentCurrentTitle(p))
}

// agentMessagesMarkdown renders one conversation under its title: each message under its role,
// with a turn's process reduced to its step count. The Agent's words are kept as they were
// written; only the labels are translated. Batch exports use it for every session.
func (a *App) agentMessagesMarkdown(messages []agentMessage, title string) string {
	t := a.text.Agent
	var b strings.Builder
	b.WriteString("# " + title + "\n\n")
	for _, span := range agentTranscriptRows(messages) {
		if span.process {
			steps := 0
			for k := span.from; k < span.to; k++ {
				if role := messages[k].Role; role == agentRoleTool || role == agentRoleThought {
					steps++
				}
			}
			b.WriteString("_" + t.Export.ProcessSteps + ": " + strconv.Itoa(steps) + "_\n\n")
			for k := span.from; k < span.to; k++ {
				if messages[k].Role == agentRoleAssistant && messages[k].Text != "" {
					b.WriteString(messages[k].Text + "\n\n")
				}
			}
			continue
		}
		message := messages[span.from]
		role := t.RoleUser
		if message.Role == agentRoleAssistant {
			role = t.RoleAssistant
		}
		if message.Role == agentRoleTool || message.Role == agentRoleThought {
			continue
		}
		b.WriteString("## " + role + "\n\n" + message.Text + "\n\n")
	}
	return b.String()
}

// exportAgentConversation asks where to save the open conversation, then writes it as Markdown.
func (a *App) exportAgentConversation(p *project) {
	if p == nil || len(p.agent.messages) == 0 {
		return
	}
	a.writeAgentMarkdown(p, a.agentTranscriptMarkdown(p), agentExportSuggestedName, "agent.export")
}

// writeAgentMarkdown asks where to save markdown, then writes it. The dialog and the write run
// off the window thread; a cancelled dialog does nothing.
func (a *App) writeAgentMarkdown(p *project, markdown, suggested, action string) {
	title := a.text.Agent.Export.DialogTitle
	a.background(p, agentLoadTimeout, func(context.Context) func(*App) {
		path, err := app.SaveFile(app.SaveFileOptions{
			Title:         title,
			SuggestedName: suggested,
			Filters:       []app.FileFilter{{Name: "Markdown", Pattern: "*.md"}},
		})
		if errors.Is(err, app.ErrCanceled) {
			return func(*App) {}
		}
		if err == nil && path != "" {
			err = os.WriteFile(path, []byte(markdown), 0o600)
		}
		return func(a *App) {
			if err != nil {
				a.notify(a.text.Agent.Export.Failed(err.Error()))
				return
			}
			a.performed(action, surfaceMenu)
		}
	})
}
