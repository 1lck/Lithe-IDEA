package workbench

import (
	"context"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// agentMentionPageSize bounds the file candidates an @ mention offers.
const agentMentionPageSize = 8

// agentMentionState is the file list for the @ mention being typed. It is replaced for each
// query, and a late answer for another query is dropped.
type agentMentionState struct {
	query   string
	matches []core.WorkspaceSearchMatch
	loading bool
}

// agentMentionQuery is the text after an @ (or the full-width ＠) that starts the draft's last
// word, and false when the draft does not end in a mention. "user@host" is not a mention.
func agentMentionQuery(draft string) (string, bool) {
	if draft == "" {
		return "", false
	}
	if last := []rune(draft)[len([]rune(draft))-1]; unicode.IsSpace(last) {
		return "", false
	}
	word := draft[agentMentionStart(draft):]
	if !strings.HasPrefix(word, "@") && !strings.HasPrefix(word, "＠") {
		return "", false
	}
	return strings.TrimPrefix(strings.TrimPrefix(word, "@"), "＠"), true
}

// ensureAgentMentions searches the workspace for the current @ query, off the window thread.
// A result is kept only while the same query is still typed.
func (a *App) ensureAgentMentions(p *project) {
	query, ok := agentMentionQuery(p.agent.editor.CommittedString())
	if !ok {
		return
	}
	s := &p.agent.mention
	if s.query == query && (s.loading || s.matches != nil) {
		return
	}
	s.query, s.matches, s.loading = query, nil, true
	if strings.TrimSpace(query) == "" {
		s.loading = false
		return
	}
	full := !p.search.indexUsed
	p.search.indexUsed = true
	kernel, root := a.kernel, p.root
	request := core.EverywhereSearchRequest{Root: root, Query: query, PageSize: agentMentionPageSize, ResultKinds: []string{"file"}}
	a.background(p, agentLoadTimeout, func(ctx context.Context) func(*App) {
		err := synchronizeSearchIndex(ctx, kernel, root, full, nil)
		var page core.EverywhereSearchPage
		if err == nil {
			page, err = kernel.SearchEverywherePage(ctx, request)
		}
		return func(a *App) {
			if a.project != p || p.agent.mention.query != query {
				return
			}
			p.agent.mention.loading = false
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_mention", err))
				return
			}
			p.agent.mention.matches = page.Matches
			if p.agent.mention.matches == nil {
				p.agent.mention.matches = []core.WorkspaceSearchMatch{}
			}
		}
	})
}

// agentMentionCandidates offers the matching files as completion rows. Choosing one attaches
// it, as the macOS composer does, rather than inserting text.
func (a *App) agentMentionCandidates(p *project) []agentSlashCandidate {
	s := p.agent.mention
	out := make([]agentSlashCandidate, 0, len(s.matches))
	for _, match := range s.matches {
		if match.Kind != "file" || match.Path == "" {
			continue
		}
		out = append(out, agentSlashCandidate{
			Name:        filepath.Base(filepath.FromSlash(match.Path)),
			Description: match.Path,
			File:        filepath.Join(p.root, filepath.FromSlash(match.Path)),
		})
	}
	return out
}

// chooseAgentMention attaches a file picked from an @ mention and removes the typed mention
// from the draft. It does not send.
func (a *App) chooseAgentMention(p *project, file string) {
	if p == nil {
		return
	}
	draft := p.agent.editor.CommittedString()
	a.setAgentDraft(p, draft[:agentMentionStart(draft)])
	a.addAgentFiles(p, []string{file})
	a.performed("agent.mention.choose", surfaceMenu)
}

// agentMentionStart is the byte offset where the draft's last word starts.
func agentMentionStart(draft string) int {
	i := strings.LastIndexFunc(draft, unicode.IsSpace)
	if i < 0 {
		return 0
	}
	_, size := utf8.DecodeRuneInString(draft[i:])
	return i + size
}
