package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

type logGraphArrowTip struct {
	lastSeen              uint64
	language              i18n.Language
	subject, author, date string
	text                  string
	keys                  [4]string
}

// logGraphArrowTips keeps the labels and keys declared in the current viewport.
type logGraphArrowTips struct {
	byCommit map[logCommitIdentity]*logGraphArrowTip
	frame    uint64
}

func (tips *logGraphArrowTips) beginFrame() {
	tips.frame++
}

func (tips *logGraphArrowTips) endFrame() {
	for commit, entry := range tips.byCommit {
		if entry.lastSeen != tips.frame {
			delete(tips.byCommit, commit)
		}
	}
	if len(tips.byCommit) == 0 {
		tips.byCommit = nil
	}
}

func (a *App) logGraphArrowTip(p *project, commit core.GitCommit, edge core.GraphElement) (key, text string) {
	view := &a.logView
	return view.arrowTips.label(p.logCommitIdentity(edge.TargetHash), a.language(), commit, view.date(commit), logGraphArrowVariant(edge))
}

func (tips *logGraphArrowTips) label(id logCommitIdentity, language i18n.Language, commit core.GitCommit, date string, variant int) (key, text string) {
	entry := tips.byCommit[id]
	fresh := entry == nil
	if fresh {
		// Crowded frames can draw every arrow even when the cache is full.
		if len(tips.byCommit) >= logRowSlots {
			return logGraphArrowKey(id, variant), formatLogGraphArrowTip(language, commit, date)
		}
		if tips.byCommit == nil {
			tips.byCommit = make(map[logCommitIdentity]*logGraphArrowTip)
		}
		entry = new(logGraphArrowTip)
		tips.byCommit[id] = entry
	}
	entry.lastSeen = tips.frame
	if entry.keys[variant] == "" {
		entry.keys[variant] = logGraphArrowKey(id, variant)
	}
	if fresh || entry.language != language || entry.subject != commit.Subject || entry.author != commit.AuthorName || entry.date != date {
		entry.language, entry.subject, entry.author, entry.date = language, commit.Subject, commit.AuthorName, date
		entry.text = formatLogGraphArrowTip(language, commit, date)
	}
	return entry.keys[variant], entry.text
}

func logGraphArrowKey(id logCommitIdentity, variant int) string {
	prefixes := [...]string{"graph-arrow/down/", "graph-arrow/down-end/", "graph-arrow/up/", "graph-arrow/up-end/"}
	return prefixes[variant] + id.repository + "/" + id.hash
}

func formatLogGraphArrowTip(language i18n.Language, commit core.GitCommit, date string) string {
	return i18n.SharedFormat(language, "desktop.git.graph.jumpToCommit", map[string]string{
		"subject": commit.Subject,
		"author":  commit.AuthorName,
		"date":    date,
	})
}
