package workbench

import (
	"context"
	"slices"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file is the History tab's session viewer: a recorded session read page by page through
// Core, which hands the agent's plugin only whole lines of the file. What it shows lives in
// memory only and is never logged.

const (
	// agentRecordPage is how many bytes of a session file one page reads, well below the 1 MiB
	// a plugin may answer.
	agentRecordPage = 256 << 10
	// agentRecordMaxPage is the largest page asked for when one line is longer than a page; Core
	// reads at most 16 MiB at once.
	agentRecordMaxPage = 16 << 20
	// agentRecordReadsPerLoad bounds the reads one load makes while the pages hold no message.
	agentRecordReadsPerLoad = 8
	// agentRecordMaxMessages bounds the messages the viewer keeps.
	agentRecordMaxMessages = 5000
	// agentRecordMaxText bounds the text one message row shows.
	agentRecordMaxText = agents.MaxEntryBytes
)

// agentRecord is the recorded session the History tab shows in place of its list.
type agentRecord struct {
	agent     string
	pluginID  string
	agentID   string
	sessionID string
	title     string
	// path is the session file read and size how many bytes of it the cache has read.
	path string
	size uint64
	// start is where the viewer began, past zero when a search hit opened it; whole is the
	// session the hit belongs to, read from its start by "View from the Start".
	start uint64
	whole *agents.RecordedSession
	// next is where the next page starts.
	next uint64

	loading bool
	// done is set once the pages reached size, or what follows cannot be read.
	done     bool
	changed  bool
	tooLong  bool
	limited  bool
	failure  string
	messages []agents.RecordedMessage
	// selections keeps each message's text selection, by its index.
	selections []*ui.TextSelectionState
	list       ui.ListState
	// generation discards the answer of a load a newer one replaced.
	generation uint64
}

// agentRecordPages is what one load read: the messages, where the next page starts and why
// reading stopped.
type agentRecordPages struct {
	messages []agents.RecordedMessage
	next     uint64
	changed  bool
	tooLong  bool
	err      error
}

// openRecordedSession shows a recorded session from its start.
func (a *App) openRecordedSession(p *project, session agents.RecordedSession) {
	a.performed("agents.history.view", surfaceButton)
	record := &agentRecord{
		agent: session.Agent, pluginID: session.PluginID, agentID: session.AgentID,
		sessionID: session.SessionID, title: session.Title, path: session.Path, size: session.ReadBytes,
	}
	a.agentsView.history.record = record
	a.loadRecordPages(p, record)
}

// openRecordedHit shows the session of a search hit from the hit on. The hit's session is
// listed first: its title, and how much of the file the cache has read when the hit is in the
// session's file; a hit in another file of the session is read alone.
func (a *App) openRecordedHit(p *project, hit agents.SearchHit) {
	kernel := a.agentKernel
	if kernel == nil || p == nil {
		return
	}
	a.performed("agents.history.viewHit", surfaceButton)
	record := &agentRecord{
		agent: hit.Agent, pluginID: hit.PluginID, agentID: hit.AgentID, sessionID: hit.SessionID,
		path: hit.Path, start: hit.Range.Start, next: hit.Range.Start, size: hit.Range.End, loading: true,
	}
	a.agentsView.history.record = record
	record.generation++
	generation := record.generation
	a.background(p, agentCallTimeout, func(ctx context.Context) func(*App) {
		sessions, err := kernel.List(ctx, agents.ListQuery{Agents: []string{hit.Agent}, SessionID: hit.SessionID, Limit: 1, Titles: true})
		var whole *agents.RecordedSession
		size := hit.Range.End
		if err == nil && len(sessions) > 0 {
			whole = &sessions[0]
			if whole.Path == hit.Path && whole.ReadBytes > size {
				size = whole.ReadBytes
			}
		}
		var pages agentRecordPages
		if err == nil {
			pages = readRecordPages(ctx, kernel, hit.Agent, hit.Path, hit.Range.Start, size)
		}
		return func(a *App) {
			if a.agentsView.history.record != record || record.generation != generation {
				return
			}
			if err != nil {
				record.loading = false
				a.backgroundFailed("agents_record", err)
				record.failure = a.agentFailure(err)
				return
			}
			record.whole, record.size = whole, size
			if whole != nil {
				record.title = whole.Title
			}
			a.applyRecordPages(record, pages)
		}
	})
}

// viewRecordFromStart reads the session a search hit opened from its start.
func (a *App) viewRecordFromStart(p *project, record *agentRecord) {
	if record.whole == nil {
		return
	}
	a.openRecordedSession(p, *record.whole)
}

// closeRecord goes back to the History tab's list.
func (a *App) closeRecord() {
	a.agentsView.history.record = nil
}

// loadRecordPages reads the next pages of the session shown, until they hold a message.
func (a *App) loadRecordPages(p *project, record *agentRecord) {
	kernel := a.agentKernel
	if kernel == nil || p == nil || record.loading || record.done {
		return
	}
	if record.next >= record.size {
		record.done = true
		return
	}
	record.loading, record.failure = true, ""
	record.generation++
	generation := record.generation
	agent, path, next, size := record.agent, record.path, record.next, record.size
	a.background(p, agentCallTimeout, func(ctx context.Context) func(*App) {
		pages := readRecordPages(ctx, kernel, agent, path, next, size)
		return func(a *App) {
			if a.agentsView.history.record != record || record.generation != generation {
				return
			}
			a.applyRecordPages(record, pages)
		}
	})
}

// applyRecordPages adds what a load read to the session shown, on the window thread.
func (a *App) applyRecordPages(record *agentRecord, pages agentRecordPages) {
	record.loading = false
	if pages.err != nil {
		a.backgroundFailed("agents_record", pages.err)
		record.failure = a.agentFailure(pages.err)
		return
	}
	room := agentRecordMaxMessages - len(record.messages)
	if len(pages.messages) > room {
		pages.messages = pages.messages[:room]
		record.limited = true
	}
	record.messages = append(record.messages, pages.messages...)
	record.next = pages.next
	record.changed, record.tooLong = pages.changed, pages.tooLong
	record.done = record.limited || pages.changed || pages.tooLong || record.next >= record.size
}

// readRecordPages reads a session file from next on, agentRecordPage bytes at a time; see
// readRecordSpans.
func readRecordPages(ctx context.Context, kernel *agents.Client, agent, path string, next, size uint64) agentRecordPages {
	return readRecordSpans(ctx, kernel, agent, path, next, size, agentRecordPage)
}

// readRecordSpans reads a session file from next on, span bytes at a time, until a read holds a
// message, the reads reach size or agentRecordReadsPerLoad reads were made. A read that lies
// inside one line is asked again four times larger, up to agentRecordMaxPage.
func readRecordSpans(ctx context.Context, kernel *agents.Client, agent, path string, next, size, span uint64) agentRecordPages {
	pages := agentRecordPages{next: next}
	page := span
	for range agentRecordReadsPerLoad {
		if pages.next >= size || len(pages.messages) > 0 {
			break
		}
		end := min(pages.next+page, size)
		result, err := kernel.Read(ctx, agent, path, agents.ByteRange{Start: pages.next, End: end})
		if err != nil {
			pages.err = err
			return pages
		}
		if result.Changed {
			pages.changed = true
			return pages
		}
		if result.End <= pages.next {
			if end >= size || page >= agentRecordMaxPage {
				pages.tooLong = true
				return pages
			}
			page = min(page*4, agentRecordMaxPage)
			continue
		}
		page = span
		pages.next = min(result.End, end)
		pages.messages = append(pages.messages, result.Messages...)
	}
	return pages
}

// selection is the text selection of the message at index, made when the message is first
// drawn.
func (record *agentRecord) selection(index int) *ui.TextSelectionState {
	for len(record.selections) <= index {
		record.selections = append(record.selections, nil)
	}
	if record.selections[index] == nil {
		record.selections[index] = &ui.TextSelectionState{}
	}
	return record.selections[index]
}

// agentRecordPanel declares the session viewer: its header with the way back and the resume
// button, then the messages read so far and what more there is.
func (a *App) agentRecordPanel(c ui.C, p *project, record *agentRecord) {
	lang := a.language()
	ui.Column(c).Fill().Children(func() {
		ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).PadX(8).Gap(4).Items(ui.Center).Children(func() {
			if _, hit := a.toolIconButton(c.Part("back"), i18n.Shared(lang, "desktop.agents.record.back"), icons.ChevronLeft, false, false); hit {
				c.After(a.closeRecord)
			}
			title := record.title
			if title == "" {
				title = record.sessionID
			}
			ui.Text(c, title).Color(a.colors.Text).Ellipsis().Grow(1).Shrink(1).MinWidth(0)
			if _, hit := a.toolIconButton(c.Part("resume"), i18n.Shared(lang, "desktop.agents.history.resume"), icons.Play, false, !a.canResume(record.pluginID, record.agentID)); hit {
				pluginID, agentID, id := record.pluginID, record.agentID, record.sessionID
				c.After(func() { a.resumeRecorded(p, pluginID, agentID, id) })
			}
		})
		if record.loading && len(record.messages) == 0 && record.failure == "" {
			a.panelMessage(c.Part("loading"), i18n.Shared(lang, "desktop.agents.record.loading"), a.colors.Subtle)
			return
		}
		lead := 0
		if record.start > 0 && record.whole != nil {
			lead = 1
		}
		ui.List(c, &record.list, lead+len(record.messages)+1, func(row ui.ListRow) {
			row.Element.FillWidth().PadX(10).PadY(5)
			switch index := row.Index - lead; {
			case index < 0:
				if ui.Button(row.C.Key("from-start"), i18n.Shared(lang, "desktop.agents.record.fromStart")).Outline().Clicked() {
					row.C.After(func() { a.viewRecordFromStart(p, record) })
				}
			case index < len(record.messages):
				a.agentRecordRow(row.C, lang, record.messages[index], record.selection(index))
			default:
				a.agentRecordFooter(row.C, p, lang, record)
			}
		}).Label(i18n.Shared(lang, "desktop.agents.record.messages")).Scrollbars().Grow(1).Shrink(1).MinHeight(0).FillWidth()
	})
}

// agentRecordRow declares one recorded message: who spoke and when, which stays out of a copy,
// then its words.
func (a *App) agentRecordRow(c ui.C, lang i18n.Language, message agents.RecordedMessage, selection *ui.TextSelectionState) {
	small := a.theme.Metrics.FontSizeS
	caption, color := agentRecordRole(lang, message), a.colors.Subtle
	if message.Role == "user" {
		color = a.colors.Accent
	}
	if message.AtMs > 0 {
		caption += " · " + time.UnixMilli(message.AtMs).Local().Format("2006-01-02 15:04")
	}
	text := agents.Clip(message.Text, agentRecordMaxText)
	ui.TextSelectionArea(c, selection).FillWidth().Gap(3).Children(func() {
		ui.Column(c).Unselectable().Children(func() {
			ui.Text(c, caption).FontSize(small).Weight(gfx.WeightSemibold).Color(color).Ellipsis()
		})
		switch message.Role {
		case "thought":
			ui.Wrap(c, text).FontSize(small).Color(a.colors.Subtle)
		case "tool":
			ui.Wrap(c, text).FontSize(small).Mono().Color(a.colors.Subtle)
		default:
			ui.Wrap(c, text).Color(a.colors.Text)
		}
	})
}

// agentRecordRole is the caption of a recorded message's speaker; a tool call shows the tool's
// name as the plugin gave it.
func agentRecordRole(lang i18n.Language, message agents.RecordedMessage) string {
	switch message.Role {
	case "user":
		return i18n.Shared(lang, "desktop.agents.you")
	case "thought":
		return i18n.Shared(lang, "desktop.agents.thinking")
	case "tool":
		role := i18n.Shared(lang, "desktop.agents.record.tool")
		if message.ToolName != "" {
			role += " · " + message.ToolName
		}
		return role
	}
	return i18n.Shared(lang, "desktop.agents.record.agent")
}

// agentRecordFooter declares the row after the messages: the button that reads more, or why
// there is no more, or what failed.
func (a *App) agentRecordFooter(c ui.C, p *project, lang i18n.Language, record *agentRecord) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Gap(6).Items(ui.Start).Children(func() {
		note := func(words string, color gfx.Color) {
			ui.Wrap(c, words).FontSize(small).Color(color)
		}
		switch {
		case record.failure != "":
			ui.Wrap(c, i18n.SharedFormat(lang, "desktop.agents.record.failed", map[string]string{"reason": record.failure})).FontSize(small).Color(a.colors.Warning)
		case record.changed:
			note(i18n.Shared(lang, "desktop.agents.record.changed"), a.colors.Warning)
			if ui.Button(c.Key("sync"), i18n.Shared(lang, "desktop.agents.history.sync")).Outline().Clicked() {
				c.After(func() {
					a.performed("agents.history.sync", surfaceButton)
					a.closeRecord()
					a.loadAgentHistory(p, true)
				})
			}
			return
		case record.limited:
			ui.Wrap(c, i18n.SharedFormat(lang, "desktop.agents.record.limit", map[string]string{"count": strconv.Itoa(agentRecordMaxMessages)})).FontSize(small).Color(a.colors.Subtle)
			return
		case record.tooLong:
			note(i18n.Shared(lang, "desktop.agents.record.tooLong"), a.colors.Subtle)
			return
		case record.done && len(record.messages) == 0:
			note(i18n.Shared(lang, "desktop.agents.record.empty"), a.colors.Subtle)
			return
		case record.done:
			return
		}
		if record.loading {
			note(i18n.Shared(lang, "desktop.agents.record.loading"), a.colors.Subtle)
			return
		}
		if ui.Button(c.Key("more"), i18n.Shared(lang, "desktop.agents.record.loadMore")).Outline().Clicked() {
			c.After(func() {
				a.performed("agents.history.loadMore", surfaceButton)
				a.loadRecordPages(p, record)
			})
		}
	})
}

// recordReadable reports whether the session shown still belongs to an agent the user lets Lithe
// read; taking the consent back closes the viewer.
func (v *agentsState) recordReadable(record *agentRecord) bool {
	return slices.Contains(v.readableAgents(), record.agent)
}
