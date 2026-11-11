package workbench

import (
	"fmt"
	"strings"

	"github.com/vivaui/viva/ui"
)

// Batch export writes several conversations of the connection to one Markdown file. A session
// whose transcript is kept (agentHistoryState.cache) is written from it. Any other session is
// replayed in turn with loadSession into a buffer that is not committed; afterwards the open
// session is replayed again so Core and the transcript show it as before. A cancelled or failed
// batch writes nothing, and a dropped connection ends it with nothing written.

// agentExportCacheLimit bounds how many sessions keep a transcript for export.
const agentExportCacheLimit = 16

// agentExportPart is one conversation of a batch, in list order.
type agentExportPart struct {
	title    string
	messages []agentMessage
}

// agentExportBatch is the state of the batch running on the connection.
type agentExportBatch struct {
	active, cancelled bool
	// inFlight is set while a replay is awaited; restoring marks the replay of the open session.
	inFlight, restoring bool
	// queue holds the sessions still to replay; current and token identify the replay awaited.
	queue   []string
	current string
	token   string
	// original is the open session restored at the end.
	original string
	parts    []agentExportPart
	// order keeps the session ids in the order their parts were added, for titles.
	total int
}

// agentTranscriptCache keeps transcripts of sessions that are not open, by session id.
type agentTranscriptCache struct {
	messages map[string][]agentMessage
	order    []string
}

// cacheAgentTranscript keeps the transcript of a session that is leaving the open composer.
func (a *App) cacheAgentTranscript(p *project, sessionID string, messages []agentMessage) {
	if sessionID == "" || len(messages) == 0 {
		return
	}
	c := &p.agent.history.cache
	if c.messages == nil {
		c.messages = map[string][]agentMessage{}
	}
	if _, known := c.messages[sessionID]; !known {
		c.order = append(c.order, sessionID)
	}
	c.messages[sessionID] = messages
	for len(c.order) > agentExportCacheLimit {
		delete(c.messages, c.order[0])
		c.order = c.order[1:]
	}
}

// agentBatchSessionTitle is the title a session has in the history, or the untitled label.
func (a *App) agentBatchSessionTitle(p *project, sessionID string) string {
	for _, session := range p.agent.history.sessions {
		if session.SessionID == sessionID {
			if title := a.agentSessionTitle(p, session); title != "" {
				return title
			}
		}
	}
	return a.text.Agent.Untitled
}

// agentExportableSessions lists the selected sessions in list order.
func (a *App) agentExportableSessions(p *project) []string {
	var ids []string
	for _, session := range a.agentHistoryOrdered(p) {
		if p.agent.history.selected[session.SessionID] {
			ids = append(ids, session.SessionID)
		}
	}
	return ids
}

// startBatchExport exports the selected sessions. Cached ones are written from their transcript;
// the rest are replayed one by one.
func (a *App) startBatchExport(p *project) {
	h := &p.agent.history
	if p == nil || p.agent.conn == nil || h.batch.active || p.agent.sessionID == "" || !h.canLoad ||
		p.agent.connecting || p.agent.pending != "" || h.restoring() || p.agent.permission != nil ||
		p.agent.phase == agentPhaseBusy || p.agent.phase == agentPhaseCancelling || p.agent.phase == agentPhaseStarting {
		return
	}
	ids := a.agentExportableSessions(p)
	if len(ids) == 0 {
		return
	}
	b := agentExportBatch{active: true, original: p.agent.sessionID, total: len(ids)}
	for _, id := range ids {
		if messages, ok := h.cache.messages[id]; ok {
			b.parts = append(b.parts, agentExportPart{title: a.agentBatchSessionTitle(p, id), messages: messages})
			continue
		}
		b.queue = append(b.queue, id)
	}
	h.batch = b
	a.batchAdvance(p)
}

// batchAdvance starts the next replay, or restores the open session and writes the file.
func (a *App) batchAdvance(p *project) {
	b := &p.agent.history.batch
	if !b.cancelled && len(b.queue) > 0 {
		next := b.queue[0]
		b.queue = b.queue[1:]
		if a.sendBatchLoad(p, next, false) {
			return
		}
		b.cancelled = true
	}
	if b.original != "" && p.agent.conn != nil && b.current != b.original {
		if a.sendBatchLoad(p, b.original, true) {
			return
		}
	}
	a.finishBatchExport(p)
}

// sendBatchLoad asks Core to replay one session. The replay is staged in the history buffer and
// reaches the transcript only when it is the open session being restored.
func (a *App) sendBatchLoad(p *project, sessionID string, restore bool) bool {
	h := &p.agent.history
	token := a.agentCommandToken(p, "load")
	if err := a.sendAgentCommand(p, map[string]any{"kind": "loadSession", "token": token, "sessionId": sessionID}); err != nil {
		h.listErr = a.text.Agent.HistoryRestoreFailed
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("agent_export_load", err))
		return false
	}
	b := &h.batch
	b.token, b.current, b.inFlight, b.restoring = token, sessionID, true, restore
	h.loadToken = token
	h.restoreSession = sessionID
	h.replaySession = ""
	h.replayMessages = nil
	h.replayBytes = 0
	if restore {
		p.agent.phase = agentPhaseStarting
	}
	return true
}

// batchPartLoaded takes the replay of one batch session and continues with the next step.
func (a *App) batchPartLoaded(p *project, sessionID string) {
	h := &p.agent.history
	b := &h.batch
	messages := h.replayMessages
	h.replayMessages, h.replayBytes = nil, 0
	h.restoreSession, h.loadToken = "", ""
	b.inFlight = false
	if sessionID == b.current && len(messages) > 0 {
		b.parts = append(b.parts, agentExportPart{title: a.agentBatchSessionTitle(p, sessionID), messages: messages})
		a.cacheAgentTranscript(p, sessionID, messages)
	}
	a.batchAdvance(p)
}

// batchRestored ends the batch when the open session is back; the file is written from what the
// batch collected, unless it was cancelled.
func (a *App) batchRestored(p *project) {
	b := p.agent.history.batch
	p.agent.history.batch = agentExportBatch{}
	p.agent.history.selected = nil
	p.agent.history.selecting = false
	if b.cancelled || len(b.parts) == 0 {
		return
	}
	var markdown strings.Builder
	for i, part := range b.parts {
		if i > 0 {
			markdown.WriteString("\n---\n\n")
		}
		markdown.WriteString(a.agentMessagesMarkdown(part.messages, part.title))
	}
	a.writeAgentMarkdown(p, markdown.String(), "agent-conversations.md", "agent.export.batch")
}

// finishBatchExport ends a batch that has nothing left to replay.
func (a *App) finishBatchExport(p *project) {
	b := &p.agent.history.batch
	if b.inFlight {
		return
	}
	a.batchRestored(p)
}

// cancelBatchExport stops the batch after the replay in flight: nothing more is replayed, the open
// session is restored and no file is written.
func (a *App) cancelBatchExport(p *project) {
	b := &p.agent.history.batch
	if !b.active {
		return
	}
	b.cancelled = true
	b.queue = nil
	if !b.inFlight {
		a.batchAdvance(p)
	}
}

// batchReplayFailed ends a batch whose replay Core rejected; the open session is still restored.
func (a *App) batchReplayFailed(p *project) {
	b := &p.agent.history.batch
	b.cancelled = true
	b.queue = nil
	b.inFlight = false
	if b.restoring {
		p.agent.history.batch = agentExportBatch{}
		p.agent.err = a.text.Agent.HistoryRestoreFailed
		p.agent.phase = agentPhaseReady
		return
	}
	a.batchAdvance(p)
}

// toggleExportSelection selects or clears one session of the history for export.
func (h *agentHistoryState) toggleExportSelection(sessionID string) {
	if h.selected == nil {
		h.selected = map[string]bool{}
	}
	if h.selected[sessionID] {
		delete(h.selected, sessionID)
		return
	}
	h.selected[sessionID] = true
}

// agentExportBar declares the batch export controls of the history: the selection switch, the
// export of the picks, and the progress and cancel of a batch running.
func (a *App) agentExportBar(c ui.C, p *project) {
	t := a.text.Agent.Export
	h := &p.agent.history
	ui.Row(c.Key("export-bar")).FillWidth().Shrink(0).Items(ui.Center).Gap(4).PadX(shellContentPad).Children(func() {
		if h.batch.active {
			ui.Text(c, t.BatchProgress(fmt.Sprint(len(h.batch.parts)+1), fmt.Sprint(h.batch.total))).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).Ellipsis()
			if !h.batch.cancelled && ui.Button(c.Key("export-cancel"), t.BatchCancel).Ghost().Clicked() {
				c.After(func() { a.cancelBatchExport(p) })
			}
			return
		}
		if !h.selecting {
			if ui.Button(c.Key("export-select"), t.BatchSelect).Ghost().Disabled(len(h.sessions) == 0).Clicked() {
				c.After(func() { h.selecting = true })
			}
			return
		}
		count := len(a.agentExportableSessions(p))
		if ui.Button(c.Key("export-run"), t.BatchExport(fmt.Sprint(count))).Outline().Disabled(count == 0 || p.agent.sessionID == "").Clicked() {
			c.After(func() { a.startBatchExport(p) })
		}
		if ui.Button(c.Key("export-done"), t.BatchDone).Ghost().Clicked() {
			c.After(func() {
				h.selecting = false
				h.selected = nil
			})
		}
	})
}
