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

// agentTranscriptMarkdown renders the open conversation as Markdown: each message under its
// role, with a turn's process reduced to its step count. The Agent's words are kept as they
// were written; only the labels are translated.
func (a *App) agentTranscriptMarkdown(p *project) string {
	t := a.text.Agent
	var b strings.Builder
	b.WriteString("# " + a.agentCurrentTitle(p) + "\n\n")
	for _, span := range agentTranscriptRows(p.agent.messages) {
		if span.process {
			steps := 0
			for k := span.from; k < span.to; k++ {
				if role := p.agent.messages[k].Role; role == agentRoleTool || role == agentRoleThought {
					steps++
				}
			}
			b.WriteString("_" + t.Export.ProcessSteps + ": " + strconv.Itoa(steps) + "_\n\n")
			for k := span.from; k < span.to; k++ {
				if p.agent.messages[k].Role == agentRoleAssistant && p.agent.messages[k].Text != "" {
					b.WriteString(p.agent.messages[k].Text + "\n\n")
				}
			}
			continue
		}
		message := p.agent.messages[span.from]
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

// exportAgentConversation asks where to save the open conversation, then writes it as
// Markdown. The dialog and the write run off the window thread; a cancelled dialog does
// nothing.
func (a *App) exportAgentConversation(p *project) {
	if p == nil || len(p.agent.messages) == 0 {
		return
	}
	markdown := a.agentTranscriptMarkdown(p)
	title := a.text.Agent.Export.DialogTitle
	a.background(p, agentLoadTimeout, func(context.Context) func(*App) {
		path, err := app.SaveFile(app.SaveFileOptions{
			Title:         title,
			SuggestedName: agentExportSuggestedName,
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
				a.notifyError(a.text.Agent.Export.Failed(err.Error()))
				return
			}
			a.performed("agent.export", surfaceMenu)
		}
	})
}
