package workbench

import (
	"math"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
	"github.com/vivaui/viva/ui/hovercard"
)

// The conversation view, the same in the Agent tool window and in an editor tab
// (agents_tab.go): a bar to switch or move the conversation, the transcript with a navigator of
// the user's prompts beside it, the permission requests and plan, the prompt card with the
// session's settings and usage, and a footer naming where the agent works.
//
// The transcript shows rows made from the entries each paint: a prompt is a bubble, a reply its
// Markdown, a run of tool calls one line that opens into the calls, and a completed turn folds
// the work before its last reply under a line saying how long it worked, with the files it
// changed and a copy button after the reply.

const (
	// agentChatWidth bounds the conversation's width in an editor tab, which centers it.
	agentChatWidth = 820
	// agentPillWidth bounds a conversation's pill in the tool window's bar.
	agentPillWidth = 200
	// agentNavWidth is the width of the prompt navigator.
	agentNavWidth = 14
	// agentNavDots bounds the navigator's dots; more prompts share them.
	agentNavDots = 40
	// agentSendSize is the size of the round Send and Stop buttons.
	agentSendSize = 28
	// agentRingSize is the size of the context and usage rings.
	agentRingSize = 14
	// agentPopupWidth is the width of the settings menu and the usage card.
	agentPopupWidth = 280
	// agentNavCardWidth is the width of a prompt's card in the navigator.
	agentNavCardWidth = 260
	// agentCardRadius rounds the prompt card.
	agentCardRadius = 20
	// agentChangedShown bounds the changed files a turn lists.
	agentChangedShown = 10
	// agentLocationsShown bounds the files an open tool call lists.
	agentLocationsShown = 5
	// agentRowHeadHeight is the height of the head of a tool call, a run of them, a thought
	// and a worked line.
	agentRowHeadHeight = 24
)

// agentRowKind says what a transcript row shows.
type agentRowKind uint8

const (
	// agentRowGap says the transcript is not whole.
	agentRowGap agentRowKind = iota
	agentRowUser
	agentRowReply
	agentRowThought
	agentRowNotice
	agentRowTool
	// agentRowTools is a run of tool calls on one line.
	agentRowTools
	// agentRowWorked is the line a completed turn's work folds under.
	agentRowWorked
	// agentRowActions follows a completed turn's last reply: its changed files and copy button.
	agentRowActions
	// agentRowWorking says the agent is working.
	agentRowWorking
)

// agentRow is one transcript row. entry is the index of its entry; a run of tool calls covers
// count entries from entry, and a turn's actions cover count entries from from.
type agentRow struct {
	kind         agentRowKind
	entry, count int
	from         int
	turn         uint64
	// nested is a tool call of an opened run.
	nested bool
}

// layRows makes the rows the transcript shows from its entries, and notes the rows of the
// user's prompts for the navigator.
func (conversation *agentConversation) layRows() {
	t := conversation.transcript
	rows, prompts := conversation.rows[:0], conversation.prompts[:0]
	if t.Missed || t.Dropped > 0 {
		rows = append(rows, agentRow{kind: agentRowGap})
	}
	entries := t.Entries
	for i := 0; i < len(entries); {
		entry := entries[i]
		if entry.Kind == agents.EntryUser {
			prompts = append(prompts, len(rows))
			rows = append(rows, agentRow{kind: agentRowUser, entry: i, turn: entry.Turn})
			i++
			continue
		}
		if entry.Turn == 0 {
			rows = conversation.spanRows(rows, i, i+1)
			i++
			continue
		}
		turn, j := entry.Turn, i+1
		for j < len(entries) && entries[j].Turn == turn && entries[j].Kind != agents.EntryUser {
			j++
		}
		done, final := turn != t.ActiveTurn, -1
		for k := j - 1; k >= i; k-- {
			if entries[k].Kind == agents.EntryAssistant {
				final = k
				break
			}
		}
		if done && final > i {
			rows = append(rows, agentRow{kind: agentRowWorked, entry: i, turn: turn})
			if conversation.unfolded[turn] {
				rows = conversation.spanRows(rows, i, final)
			}
			rows = append(rows, agentRow{kind: agentRowReply, entry: final, turn: turn})
			rows = conversation.spanRows(rows, final+1, j)
		} else {
			rows = conversation.spanRows(rows, i, j)
		}
		if done && final >= 0 {
			rows = append(rows, agentRow{kind: agentRowActions, entry: final, from: i, count: j - i, turn: turn})
		}
		i = j
	}
	if t.ActiveTurn != 0 || conversation.busy {
		rows = append(rows, agentRow{kind: agentRowWorking})
	}
	conversation.rows, conversation.prompts = rows, prompts
}

// spanRows appends the rows of the entries from from to to, none of them a prompt: two tool
// calls or more in a row make one line, followed by the calls when the user opened it.
func (conversation *agentConversation) spanRows(rows []agentRow, from, to int) []agentRow {
	entries := conversation.transcript.Entries
	for i := from; i < to; {
		entry := entries[i]
		switch entry.Kind {
		case agents.EntryTool:
			j := i + 1
			for j < to && entries[j].Kind == agents.EntryTool {
				j++
			}
			if j-i == 1 {
				rows = append(rows, agentRow{kind: agentRowTool, entry: i, turn: entry.Turn})
			} else {
				rows = append(rows, agentRow{kind: agentRowTools, entry: i, count: j - i, turn: entry.Turn})
				if conversation.opened[entry.Serial] {
					for k := i; k < j; k++ {
						rows = append(rows, agentRow{kind: agentRowTool, entry: k, turn: entry.Turn, nested: true})
					}
				}
			}
			i = j
			continue
		case agents.EntryAssistant:
			rows = append(rows, agentRow{kind: agentRowReply, entry: i, turn: entry.Turn})
		case agents.EntryThought:
			rows = append(rows, agentRow{kind: agentRowThought, entry: i, turn: entry.Turn})
		case agents.EntryNotice:
			rows = append(rows, agentRow{kind: agentRowNotice, entry: i, turn: entry.Turn})
		}
		i++
	}
	return rows
}

// rowKey is the list key of row i: what it shows and the serial of its entry, or its turn, so
// a row keeps its place and state while rows are added around it.
func (conversation *agentConversation) rowKey(i int) int {
	if i < 0 || i >= len(conversation.rows) {
		return (i&(1<<26-1))<<5 | 31
	}
	row := conversation.rows[i]
	var id uint64
	switch row.kind {
	case agentRowGap, agentRowWorking:
	case agentRowWorked, agentRowActions:
		id = row.turn
	default:
		id = conversation.transcript.Entries[row.entry].Serial
	}
	nested := 0
	if row.nested {
		nested = 1
	}
	return int(id%(1<<26))<<5 | int(row.kind)<<1 | nested
}

// agentChatBody declares the conversation: in the Agent tool window, or in an editor tab, which
// centers it at a readable width.
func (a *App) agentChatBody(c ui.C, p *project, conversation *agentConversation, inEditor bool) {
	conversation.pruneSelections()
	conversation.layRows()
	if conversation.list.Key == nil {
		conversation.list.Key = conversation.rowKey
	}
	ui.Column(c).Fill().Children(func() {
		a.agentChatBar(c.Part("bar"), p, conversation, inEditor)
		ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Items(ui.Center).Children(func() {
			body := ui.Column(c).FillWidth().Grow(1).Shrink(1).MinHeight(0)
			if inEditor {
				body = body.MaxWidth(agentChatWidth)
			}
			body.Children(func() {
				ui.Row(c).FillWidth().Grow(1).Shrink(1).MinHeight(0).Children(func() {
					a.agentPromptNavigator(c.Part("navigator"), conversation)
					a.agentTranscriptView(c.Part("transcript"), p, conversation)
				})
				a.agentPending(c.Part("pending"), p, conversation)
				a.agentPlan(c.Part("plan"), conversation)
				a.agentPromptCard(c.Part("prompt"), p, conversation)
				a.agentChatFooter(c.Part("footer"), p)
			})
		})
	})
}

// agentChatBar declares the conversation's bar. In the tool window it has a pill for each
// conversation it shows and moves the shown one into an editor tab; in an editor tab it names
// the conversation and moves it back. Both close the conversation, ending its session.
func (a *App) agentChatBar(c ui.C, p *project, conversation *agentConversation, inEditor bool) {
	v := &a.agentsView
	lang := a.language()
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).PadX(8).Gap(4).Items(ui.Center).Children(func() {
		if inEditor {
			ui.Icon(c, a.agentIcon(conversation.agent.Key())).Size(14, 14).Color(a.colors.Subtle).Shrink(0)
			ui.Text(c, agentConversationTitle(conversation)).FontSize(a.theme.Metrics.FontSizeM).Color(a.colors.Text).
				Ellipsis().Shrink(1).MinWidth(0)
			ui.Spacer(c)
			if _, hit := a.toolIconButton(c.Part("dock"), i18n.Shared(lang, "desktop.agents.moveToSidebar"), icons.ArrowDownLeft, false, false); hit {
				c.After(func() { a.dockAgentTab(p, conversation) })
			}
		} else {
			ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(4).Items(ui.Center).Clip().Children(func() {
				for i, each := range v.conversations {
					if each.tab == 0 {
						a.agentPill(c.KeyInt(i), each, each == conversation)
					}
				}
			})
			if _, hit := a.toolIconButton(c.Part("open"), i18n.Shared(lang, "desktop.agents.openInEditor"), icons.ArrowUpRight, false, p == nil); hit {
				c.After(func() { a.openAgentTab(p, conversation) })
			}
		}
		if _, hit := a.toolIconButton(c.Part("close"), i18n.Shared(lang, "desktop.agents.closeSession"), icons.X, false, conversation.busy); hit {
			c.After(func() { a.closeConversation(p, conversation) })
		}
	})
}

// agentPill declares a conversation's pill in the tool window's bar: its agent's icon and
// title, and a spinner while it works. A click shows the conversation.
func (a *App) agentPill(c ui.C, conversation *agentConversation, current bool) {
	title := agentConversationTitle(conversation)
	color := a.colors.Subtle
	if current {
		color = a.colors.Text
	}
	focused := components.ButtonRecipe(a.theme, components.ButtonGhost, gfx.State{FocusVisible: true})
	pill := ui.ButtonBase(c, title).Height(agentRowHeadHeight).Shrink(1).MinWidth(40).MaxWidth(agentPillWidth).
		PadX(8).Gap(5).Radius(12).Items(ui.Center).Tooltip(title).
		Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active)).
		Focus(ui.Look{}.Ring(focused.RingWidth, focused.Ring))
	if current {
		pill = pill.Background(a.colors.Active)
	}
	pill.Children(func() {
		ui.Icon(c, a.agentIcon(conversation.agent.Key())).Size(13, 13).Color(color).Shrink(0)
		ui.Text(c, title).FontSize(a.theme.Metrics.FontSizeS).Color(color).Ellipsis().Shrink(1).MinWidth(0)
		if conversation.transcript.ActiveTurn != 0 {
			ui.Spinner(c).Size(10, 10)
		}
	})
	if pill.Clicked() {
		c.After(func() { a.selectConversation(conversation) })
	}
}

// agentTranscriptView declares the transcript's rows, newest at the bottom. It opens at the end
// and follows new rows while it shows the last one; scrolled up, a button takes it back down.
func (a *App) agentTranscriptView(c ui.C, p *project, conversation *agentConversation) {
	lang := a.language()
	list := &conversation.list
	// The list follows its end while it shows it, and a list not laid out yet opens there. The
	// navigator's jump to a prompt is asked for at the end, which the list must stop following
	// for the jump to land: it follows again once the list has left the end, or rows came in.
	first, last := list.Visible()
	end := list.AtEnd()
	follow := end || last < first
	if conversation.jump != 0 {
		if end && conversation.jump == len(conversation.rows)+1 {
			follow = false
		} else {
			conversation.jump = 0
		}
	}
	conversation.shownRows = conversation.shownRows[:0]
	ui.Column(c).Grow(1).Shrink(1).MinWidth(0).FillHeight().Children(func() {
		area := ui.List(c, list, len(conversation.rows), func(row ui.ListRow) {
			shown := conversation.rows[row.Index]
			pad := float32(12)
			switch shown.kind {
			case agentRowTool, agentRowTools, agentRowThought, agentRowWorked:
				// Their heads pad their own text, which lines up with the replies'.
				pad = 6
			}
			row.Element.FillWidth().PadX(pad).PadY(3)
			conversation.shownRows = append(conversation.shownRows, agentShownRow{index: row.Index, box: row.Element})
			a.agentRowView(row.C, p, conversation, shown)
		}).Label(i18n.Shared(lang, "desktop.agents.transcript")).Scrollbars().Grow(1).Shrink(1).MinHeight(0).FillWidth().Follow(follow)
		conversation.transcriptBox = area
		// Where this paint puts the list, not where the last one left it: a list on its way to
		// the end shows no button.
		if !area.ScrollState().Pinned() {
			a.agentScrollDown(c.Part("down"), conversation)
		}
	})
}

// agentScrollDown declares the round button over the transcript that scrolls it to the end.
func (a *App) agentScrollDown(c ui.C, conversation *agentConversation) {
	label := i18n.Shared(a.language(), "desktop.agents.scrollToEnd")
	focused := components.ButtonRecipe(a.theme, components.ButtonGhost, gfx.State{FocusVisible: true})
	button := ui.ButtonBase(c, label).Absolute().Right(16).Bottom(10).Size(agentSendSize, agentSendSize).Radius(agentSendSize/2).
		Background(a.colors.Editor).Border(1, a.colors.Line).Shadow(gfx.ShadowSM).Items(ui.Center).Justify(ui.Center).
		Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active)).
		Focus(ui.Look{}.Ring(focused.RingWidth, focused.Ring)).Tooltip(label)
	button.Children(func() {
		ui.Icon(c, icons.ArrowDown).Size(14, 14).Color(a.colors.Text)
	})
	if button.Clicked() {
		c.After(func() { conversation.list.ScrollToEnd() })
	}
}

// agentRowView declares one transcript row.
func (a *App) agentRowView(c ui.C, p *project, conversation *agentConversation, row agentRow) {
	t := conversation.transcript
	lang := a.language()
	switch row.kind {
	case agentRowGap:
		a.agentGapRow(c, lang, t)
	case agentRowWorking:
		ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
			ui.Spinner(c).Size(12, 12)
			ui.Text(c, i18n.Shared(lang, "desktop.agents.working")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		})
	case agentRowWorked:
		a.agentWorkedRow(c, lang, conversation, row.turn)
	case agentRowActions:
		a.agentActionsRow(c, p, lang, conversation, row)
	case agentRowTools:
		a.agentToolsRow(c, lang, conversation, row)
	default:
		entry := t.Entries[row.entry]
		switch row.kind {
		case agentRowUser:
			a.agentUserRow(c, conversation, entry)
		case agentRowReply:
			complete := entry.Turn == 0 || entry.Turn != t.ActiveTurn
			a.agentMarkdownBlock(c, a.agentMarkdownOf(conversation, entry.Serial, entry.Text), complete)
		case agentRowThought:
			a.agentThoughtRow(c, lang, conversation, entry)
		case agentRowNotice:
			a.agentNoticeRow(c, lang, entry)
		case agentRowTool:
			a.agentToolView(c, p, lang, conversation, entry, row.nested)
		}
	}
}

// agentUserRow declares a prompt the user sent, a bubble at the right whose words can be
// selected.
func (a *App) agentUserRow(c ui.C, conversation *agentConversation, entry agents.Entry) {
	ui.Row(c).FillWidth().Justify(ui.End).PadSides(4, 0, 4, 48).Children(func() {
		ui.TextSelectionArea(c, conversation.selection(entry.Serial)).Shrink(1).MinWidth(0).Radius(14).
			Background(a.colors.Hover).PadX(12).PadY(8).Children(func() {
			ui.Wrap(c, entry.Text).FontSize(a.theme.Metrics.FontSizeM + 1).Color(a.colors.Text)
		})
	})
}

// agentRowHead is the button that heads a row which opens and folds: a tool call, a run of
// them, a thought or a completed turn's work. Its children follow.
func (a *App) agentRowHead(c ui.C, label string) ui.Box {
	focused := components.ButtonRecipe(a.theme, components.ButtonGhost, gfx.State{FocusVisible: true})
	return ui.ButtonBase(c, label).Height(agentRowHeadHeight).Shrink(1).MinWidth(0).PadX(6).Gap(6).Radius(6).Items(ui.Center).
		Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active)).
		Focus(ui.Look{}.Ring(focused.RingWidth, focused.Ring))
}

// agentChevron declares the chevron of a head that opens, pointing down while open.
func (a *App) agentChevron(c ui.C, open bool) {
	chevron := icons.ChevronRight
	if open {
		chevron = icons.ChevronDown
	}
	ui.Icon(c, chevron).Size(12, 12).Color(a.colors.Subtle).Shrink(0)
}

// agentThoughtRow declares the agent's reasoning: a head with its first line, opening into the
// text.
func (a *App) agentThoughtRow(c ui.C, lang i18n.Language, conversation *agentConversation, entry agents.Entry) {
	small := a.theme.Metrics.FontSizeS
	open := conversation.expanded[entry.Serial]
	label := i18n.Shared(lang, "desktop.agents.thinking")
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		ui.Row(c).FillWidth().Children(func() {
			head := a.agentRowHead(c.Part("head"), label)
			head.Children(func() {
				ui.Icon(c, icons.Sparkles).Size(13, 13).Color(a.colors.Subtle).Shrink(0)
				ui.Text(c, label).FontSize(small).Color(a.colors.Subtle).Shrink(0)
				if !open {
					ui.Text(c, agentFirstLine(entry.Text)).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				}
				a.agentChevron(c, open)
			})
			if head.Clicked() {
				serial := entry.Serial
				c.After(func() { conversation.toggleExpanded(serial) })
			}
		})
		if open {
			ui.TextSelectionArea(c, conversation.selection(entry.Serial)).FillWidth().PadSides(0, 6, 0, 25).Children(func() {
				ui.Wrap(c, entry.Text).FontSize(small).Color(a.colors.Subtle)
			})
		}
	})
}

// agentNoticeRow declares a notice: the backend's text, or why a turn did not complete.
func (a *App) agentNoticeRow(c ui.C, lang i18n.Language, entry agents.Entry) {
	color := a.colors.Subtle
	if entry.Level == "warning" || entry.Level == "error" {
		color = a.colors.Warning
	}
	text := entry.Text
	if text == "" {
		text = agentNoticeText(lang, entry.Code)
	}
	ui.Row(c).FillWidth().Gap(6).Items(ui.Start).Children(func() {
		ui.Icon(c, icons.CircleAlert).Size(13, 13).Color(color).Shrink(0)
		ui.Wrap(c, text).FontSize(a.theme.Metrics.FontSizeS).Color(color).Grow(1).Shrink(1)
	})
}

// agentToolIcon is the icon of a tool call of kind, as the Agent Client Protocol names kinds.
func agentToolIcon(kind string) gfx.Icon {
	switch kind {
	case "read":
		return icons.FileText
	case "edit":
		return icons.Pencil
	case "delete":
		return icons.Trash2
	case "move":
		return icons.ArrowUpRight
	case "search":
		return icons.Search
	case "execute":
		return icons.SquareTerminal
	case "think":
		return icons.Sparkles
	case "fetch":
		return icons.ExternalLink
	}
	return icons.Wrench
}

// agentToolState declares the state of a tool call after its title: a spinner while it runs, a
// mark when it failed, nothing once it completed.
func (a *App) agentToolState(c ui.C, status string) {
	switch status {
	case "pending", "inProgress":
		ui.Spinner(c).Size(11, 11)
	case "failed":
		ui.Icon(c, icons.CircleX).Size(12, 12).Color(a.colors.Warning).Shrink(0)
	}
}

// agentToolView declares a tool call on one line, opening into the files it touches and the
// end of its output. A call of an opened run is indented under it.
func (a *App) agentToolView(c ui.C, p *project, lang i18n.Language, conversation *agentConversation, entry agents.Entry, nested bool) {
	small := a.theme.Metrics.FontSizeS
	title := entry.Title
	if title == "" {
		title = entry.ToolKind
	}
	if title == "" {
		title = agentToolCount(lang, agentToolGroupOf(""), 1)
	}
	output := strings.TrimRight(entry.Output, "\n")
	details := len(entry.Locations) > 0 || output != ""
	open := details && conversation.expanded[entry.Serial]
	indent := float32(0)
	if nested {
		indent = 20
	}
	ui.Column(c).FillWidth().Gap(4).PadSides(0, 0, 0, indent).Children(func() {
		ui.Row(c).FillWidth().Children(func() {
			head := a.agentRowHead(c.Part("head"), title)
			if entry.Status != "" {
				head = head.Tooltip(agentToolStatus(lang, entry.Status))
			}
			head.Children(func() {
				ui.Icon(c, agentToolIcon(entry.ToolKind)).Size(13, 13).Color(a.colors.Subtle).Shrink(0)
				ui.Text(c, title).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				a.agentToolState(c, entry.Status)
				if details {
					a.agentChevron(c, open)
				}
			})
			if head.Clicked() && details {
				serial := entry.Serial
				c.After(func() { conversation.toggleExpanded(serial) })
			}
		})
		if !open {
			return
		}
		ui.Column(c).FillWidth().Gap(4).PadSides(0, 6, 0, 25).Children(func() {
			for i, location := range entry.Locations {
				if i == agentLocationsShown {
					break
				}
				place := agentShownPath(p, location.Path)
				if location.Line > 0 {
					place += ":" + strconv.FormatUint(location.Line, 10)
				}
				link := ui.ButtonBase(c.KeyInt(i), place).Height(20).Shrink(1).MinWidth(0).PadX(4).Radius(4).Items(ui.Center).
					Hover(ui.Look{}.Background(a.colors.Hover)).Tooltip(location.Path)
				link.Children(func() {
					ui.Text(c, place).FontSize(small).Mono().Color(a.colors.Accent).Ellipsis().Shrink(1).MinWidth(0)
				})
				if link.Clicked() {
					path, line := location.Path, int(location.Line)
					c.After(func() { a.openAgentFile(p, path, line) })
				}
			}
			if output != "" {
				ui.TextSelectionArea(c, conversation.selection(entry.Serial)).FillWidth().Radius(8).Background(a.colors.Hover).
					PadX(10).PadY(6).Children(func() {
					ui.Paragraph(c, strings.ReplaceAll(lastLines(output, agentToolOutputLines), "\t", "    "), agentToolOutputLines).
						FontSize(small).Mono().Color(a.colors.Subtle).FillWidth()
				})
			}
		})
	})
}

// agentShownPath is how a file a tool call touches is named: relative to the folder when it is
// below it.
func agentShownPath(p *project, path string) string {
	if p != nil && p.root != "" {
		if relative, err := filepath.Rel(p.root, path); err == nil && relative != "." && !strings.HasPrefix(relative, "..") {
			return relative
		}
	}
	return path
}

// agentToolGroup is the kind of work a tool call does, as a run of them counts it.
type agentToolGroup int

const (
	agentToolRead agentToolGroup = iota
	agentToolChanged
	agentToolSearched
	agentToolRan
	agentToolFetched
	agentToolUsed
	agentToolGroups
)

// agentToolGroupOf is the group of a tool call of kind.
func agentToolGroupOf(kind string) agentToolGroup {
	switch kind {
	case "read":
		return agentToolRead
	case "edit", "delete", "move":
		return agentToolChanged
	case "search":
		return agentToolSearched
	case "execute":
		return agentToolRan
	case "fetch":
		return agentToolFetched
	}
	return agentToolUsed
}

// agentToolCount says how many tool calls of group a run made: "2 files read".
func agentToolCount(lang i18n.Language, group agentToolGroup, n int) string {
	count := strconv.Itoa(n)
	one := n == 1
	switch group {
	case agentToolRead:
		if one {
			return i18n.SharedFormat(lang, "desktop.agents.tools.readOne", map[string]string{"count": count})
		}
		return i18n.SharedFormat(lang, "desktop.agents.tools.read", map[string]string{"count": count})
	case agentToolChanged:
		if one {
			return i18n.SharedFormat(lang, "desktop.agents.tools.changedOne", map[string]string{"count": count})
		}
		return i18n.SharedFormat(lang, "desktop.agents.tools.changed", map[string]string{"count": count})
	case agentToolSearched:
		if one {
			return i18n.SharedFormat(lang, "desktop.agents.tools.searchedOne", map[string]string{"count": count})
		}
		return i18n.SharedFormat(lang, "desktop.agents.tools.searched", map[string]string{"count": count})
	case agentToolRan:
		if one {
			return i18n.SharedFormat(lang, "desktop.agents.tools.ranOne", map[string]string{"count": count})
		}
		return i18n.SharedFormat(lang, "desktop.agents.tools.ran", map[string]string{"count": count})
	case agentToolFetched:
		if one {
			return i18n.SharedFormat(lang, "desktop.agents.tools.fetchedOne", map[string]string{"count": count})
		}
		return i18n.SharedFormat(lang, "desktop.agents.tools.fetched", map[string]string{"count": count})
	}
	if one {
		return i18n.SharedFormat(lang, "desktop.agents.tools.usedOne", map[string]string{"count": count})
	}
	return i18n.SharedFormat(lang, "desktop.agents.tools.used", map[string]string{"count": count})
}

// agentToolsSummary says what a run of tool calls did: "1 file read and 2 commands run".
func agentToolsSummary(lang i18n.Language, entries []agents.Entry) string {
	var counts [agentToolGroups]int
	for _, entry := range entries {
		counts[agentToolGroupOf(entry.ToolKind)]++
	}
	var parts []string
	for group, n := range counts {
		if n > 0 {
			parts = append(parts, agentToolCount(lang, agentToolGroup(group), n))
		}
	}
	return agentJoinList(lang, parts)
}

// agentJoinList joins parts as a sentence lists them: "a, b and c".
func agentJoinList(lang i18n.Language, parts []string) string {
	if len(parts) == 0 {
		return ""
	}
	list := parts[0]
	for i := 1; i < len(parts)-1; i++ {
		list = i18n.SharedFormat(lang, "desktop.agents.tools.list", map[string]string{"list": list, "item": parts[i]})
	}
	if len(parts) > 1 {
		list = i18n.SharedFormat(lang, "desktop.agents.tools.and", map[string]string{"list": list, "item": parts[len(parts)-1]})
	}
	return list
}

// agentToolsRow declares a run of tool calls on one line: what they did and their state. It
// opens into the calls.
func (a *App) agentToolsRow(c ui.C, lang i18n.Language, conversation *agentConversation, row agentRow) {
	entries := conversation.transcript.Entries[row.entry : row.entry+row.count]
	first := entries[0].Serial
	open := conversation.opened[first]
	label := agentToolsSummary(lang, entries)
	running, failed := false, false
	for _, entry := range entries {
		running = running || entry.Status == "pending" || entry.Status == "inProgress"
		failed = failed || entry.Status == "failed"
	}
	ui.Row(c).FillWidth().Children(func() {
		head := a.agentRowHead(c.Part("head"), label)
		head.Children(func() {
			ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
			switch {
			case failed:
				ui.Icon(c, icons.CircleX).Size(12, 12).Color(a.colors.Warning).Shrink(0)
			case running:
				ui.Spinner(c).Size(11, 11)
			default:
				ui.Icon(c, icons.Check).Size(12, 12).Color(a.colors.Success).Shrink(0)
			}
			a.agentChevron(c, open)
		})
		if head.Clicked() {
			c.After(func() { conversation.toggleOpened(first) })
		}
	})
}

// agentWorkedRow declares the line a completed turn's work folds under: how long the turn
// worked, then a rule.
func (a *App) agentWorkedRow(c ui.C, lang i18n.Language, conversation *agentConversation, turn uint64) {
	open := conversation.unfolded[turn]
	label := i18n.Shared(lang, "desktop.agents.workedUnknown")
	if took, ok := conversation.worked(turn); ok {
		label = i18n.SharedFormat(lang, "desktop.agents.worked", map[string]string{"duration": agentDuration(lang, took)})
	}
	ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
		head := a.agentRowHead(c.Part("head"), label)
		head.Children(func() {
			ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
			a.agentChevron(c, open)
		})
		if head.Clicked() {
			c.After(func() { conversation.toggleUnfolded(turn) })
		}
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Height(1).Background(a.colors.Line)
	})
}

// agentDuration writes how long a turn took: "42s", "17m 7s" or "1h 5m".
func agentDuration(lang i18n.Language, took time.Duration) string {
	seconds := int(took.Round(time.Second) / time.Second)
	switch {
	case seconds < 60:
		return i18n.SharedFormat(lang, "desktop.agents.duration.seconds", map[string]string{"seconds": strconv.Itoa(seconds)})
	case seconds < 3600:
		return i18n.SharedFormat(lang, "desktop.agents.duration.minutes", map[string]string{
			"minutes": strconv.Itoa(seconds / 60), "seconds": strconv.Itoa(seconds % 60),
		})
	}
	return i18n.SharedFormat(lang, "desktop.agents.duration.hours", map[string]string{
		"hours": strconv.Itoa(seconds / 3600), "minutes": strconv.Itoa(seconds % 3600 / 60),
	})
}

// agentChangedFiles lists the files the tool calls among entries changed, each once, in the
// order they were first changed.
func agentChangedFiles(entries []agents.Entry) []string {
	var files []string
	seen := map[string]bool{}
	for _, entry := range entries {
		if entry.Kind != agents.EntryTool || agentToolGroupOf(entry.ToolKind) != agentToolChanged {
			continue
		}
		for _, location := range entry.Locations {
			if location.Path != "" && !seen[location.Path] {
				seen[location.Path] = true
				files = append(files, location.Path)
			}
		}
	}
	return files
}

// agentActionsRow declares what follows a completed turn's last reply: the files the turn
// changed, each opening the file, and the button that copies the reply.
func (a *App) agentActionsRow(c ui.C, p *project, lang i18n.Language, conversation *agentConversation, row agentRow) {
	t := conversation.transcript
	files := agentChangedFiles(t.Entries[row.from : row.from+row.count])
	reply := t.Entries[row.entry].Text
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Gap(6).Children(func() {
		if len(files) > 0 {
			ui.Column(c.Part("changed")).FillWidth().Radius(10).Border(1, a.colors.Line).Clip().Children(func() {
				ui.Row(c).FillWidth().Height(30).PadX(10).Gap(6).Items(ui.Center).Children(func() {
					ui.Icon(c, icons.Pencil).Size(13, 13).Color(a.colors.Subtle).Shrink(0)
					ui.Text(c, agentToolCount(lang, agentToolChanged, len(files))).FontSize(small).Weight(gfx.WeightMedium).Color(a.colors.Text)
				})
				for i, path := range files {
					if i == agentChangedShown {
						break
					}
					shown := agentShownPath(p, path)
					file := ui.ButtonBase(c.KeyInt(i), shown).FillWidth().Height(26).PadX(10).Gap(6).Items(ui.Center).Justify(ui.Start).
						Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active)).Tooltip(path)
					file.Children(func() {
						ui.Icon(c, icons.FileCode).Size(13, 13).Color(a.colors.Subtle).Shrink(0)
						ui.Text(c, shown).FontSize(small).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
					})
					if file.Clicked() {
						c.After(func() { a.openAgentFile(p, path, 0) })
					}
				}
			})
		}
		ui.Row(c).FillWidth().Gap(2).Items(ui.Center).Children(func() {
			if _, hit := a.toolIconButton(c.Part("copy"), i18n.Shared(lang, "desktop.agents.copyReply"), icons.Copy, false, reply == ""); hit {
				c.After(func() { a.copyAgentText(reply) })
			}
		})
	})
}

// agentPromptCard declares the prompt card: the prompt field over the session's settings, its
// usage and the Send or Stop button. ⌘↩ sends. An ended session says so instead.
func (a *App) agentPromptCard(c ui.C, p *project, conversation *agentConversation) {
	t := conversation.transcript
	lang := a.language()
	if !t.Live() {
		ui.Text(c, i18n.Shared(lang, "desktop.agents.ended")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).
			FillWidth().TextCenter().PadY(10).Shrink(0)
		return
	}
	ui.Column(c).FillWidth().Shrink(0).PadSides(4, 12, 4, 12).Children(func() {
		ui.Column(c).FillWidth().Radius(agentCardRadius).Border(1, a.colors.Line).Background(a.colors.Editor).
			PadX(12).PadY(8).Gap(6).Children(func() {
			field := ui.TextArea(c.Key("prompt"), &conversation.prompt, i18n.Shared(lang, "desktop.agents.promptLabel"),
				i18n.SharedFormat(lang, "desktop.agents.promptPlaceholder", map[string]string{"agent": conversation.agent.DisplayName})).
				FillWidth().AutoGrow(8).Border(0, gfx.Color{}).Background(gfx.Color{})
			if field.Shortcut(ui.Primary, "enter") && conversation.canSendPrompt() {
				c.After(func() { a.sendPrompt(p, conversation, surfaceShortcut) })
			}
			ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(func() {
				a.agentSettingsChip(c.Part("settings"), p, conversation)
				ui.Spacer(c)
				a.agentMeters(c.Part("meters"), conversation)
				a.agentSendButton(c.Part("send"), p, conversation)
			})
		})
	})
}

// agentSettingsChip declares the chip of the session's settings, its model and reasoning
// effort, opening the menu that changes them. A backend that reports no settings shows the
// model and effort it started with, which cannot be changed here.
func (a *App) agentSettingsChip(c ui.C, p *project, conversation *agentConversation) {
	t := conversation.transcript
	if len(t.ConfigOptions) == 0 {
		model := t.Model
		if t.Usage != nil && t.Usage.Model != "" {
			model = t.Usage.Model
		}
		if label := strings.TrimSpace(model + " " + t.Effort); label != "" {
			ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
		}
		return
	}
	// In a narrow window the chip gives way, so the usage and the Send button stay in the card.
	chip := a.agentHistoryChip(c, agentSettingsLabel(conversation), &icons.Sparkles, true, conversation.settingsOpen).
		Shrink(1).MinWidth(0).Tooltip(i18n.Shared(a.language(), "desktop.agents.session.menu"))
	if chip.Clicked() {
		c.After(func() { conversation.settingsOpen = true })
	}
	a.agentSettingsMenu(c.Part("menu"), p, conversation, chip)
}

// agentSettingsLabel names the values shown of the session's model and reasoning effort, or of
// all its settings when it reports neither.
func agentSettingsLabel(conversation *agentConversation) string {
	t := conversation.transcript
	var parts []string
	for _, category := range [...]string{"model", "thoughtLevel"} {
		if setting := t.Setting(category); setting != nil {
			parts = append(parts, agentShownName(conversation, setting))
		}
	}
	if len(parts) == 0 {
		for i := range t.ConfigOptions {
			parts = append(parts, agentShownName(conversation, &t.ConfigOptions[i]))
		}
	}
	return strings.Join(parts, " ")
}

// agentShownName is the name of the value shown for setting.
func agentShownName(conversation *agentConversation, setting *agents.ConfigOption) string {
	if at := conversation.shownIndex(setting); at >= 0 {
		return agentValueName(setting.Options[at])
	}
	return conversation.shownValue(setting)
}

// agentValueName is the name of a setting's value, the value itself when it has none.
func agentValueName(value agents.ConfigValue) string {
	if value.Name != "" {
		return value.Name
	}
	return value.Value
}

// agentSettingHeading is the heading of a setting in the menu.
func agentSettingHeading(lang i18n.Language, setting *agents.ConfigOption) string {
	switch setting.Category {
	case "model":
		return i18n.Shared(lang, "desktop.agents.session.model")
	case "thoughtLevel":
		return i18n.Shared(lang, "desktop.agents.session.effort")
	case "mode":
		return i18n.Shared(lang, "desktop.agents.session.mode")
	}
	if setting.Name != "" {
		return setting.Name
	}
	return setting.ID
}

// agentSettingsMenu declares the menu over the settings chip: each setting the backend
// reports, the reasoning effort on a slider and every other one as a list to pick from.
func (a *App) agentSettingsMenu(c ui.C, p *project, conversation *agentConversation, anchor ui.Box) {
	if !conversation.settingsOpen {
		return
	}
	t := conversation.transcript
	lang := a.language()
	effort := t.Setting("thoughtLevel")
	open := true
	spec := ui.PopoverSpec{
		Side: components.PopoverTop, Align: ui.Start, Offset: chromeMenuOffset, Width: agentPopupWidth, ConsumeOutsidePress: true,
		Title: i18n.Shared(lang, "desktop.agents.session.menu"),
	}
	ui.Popover(c, anchor, &open, spec, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			for i := range t.ConfigOptions {
				setting := &t.ConfigOptions[i]
				k := c.KeyInt(i)
				if i > 0 {
					ui.Divider(k.Part("rule"))
				}
				ui.Column(k).FillWidth().Gap(2).Children(func() {
					if setting == effort && len(setting.Options) >= 2 {
						a.agentEffortSlider(k, p, lang, conversation, setting)
					} else {
						a.agentSettingChoices(k, p, lang, conversation, setting)
					}
				})
			}
		})
	})
	if !open {
		conversation.settingsOpen = false
	}
}

// agentSettingChoices declares a setting's values, the one shown checked; a click picks one.
func (a *App) agentSettingChoices(c ui.C, p *project, lang i18n.Language, conversation *agentConversation, setting *agents.ConfigOption) {
	focused := components.ButtonRecipe(a.theme, components.ButtonGhost, gfx.State{FocusVisible: true})
	ui.Text(c, agentSettingHeading(lang, setting)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).PadX(6).PadY(2)
	shown := conversation.shownValue(setting)
	for j, value := range setting.Options {
		name := agentValueName(value)
		chosen := value.Value == shown
		choice := ui.ButtonBase(c.KeyInt(j), name).FillWidth().Height(26).PadX(6).Gap(6).Radius(6).Items(ui.Center).
			Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active)).
			Focus(ui.Look{}.Ring(focused.RingWidth, focused.Ring))
		if value.Description != "" {
			choice = choice.Tooltip(value.Description)
		}
		choice.Children(func() {
			ui.Text(c, name).FontSize(a.theme.Metrics.FontSizeM).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
			ui.Spacer(c)
			if chosen {
				ui.Icon(c, icons.Check).Size(14, 14).Color(a.colors.Text).Shrink(0)
			}
		})
		if choice.Clicked() && !chosen {
			id, picked := setting.ID, value.Value
			c.After(func() { a.setAgentOption(p, conversation, id, picked) })
		}
	}
}

// agentEffortSlider declares the reasoning effort as a slider over its values, least to most.
// The value under the thumb shows while it is dragged; letting go picks it.
func (a *App) agentEffortSlider(c ui.C, p *project, lang i18n.Language, conversation *agentConversation, setting *agents.ConfigOption) {
	small := a.theme.Metrics.FontSizeS
	n := len(setting.Options)
	state := &conversation.effort
	shown := conversation.shownIndex(setting)
	values := setting.ID
	for _, value := range setting.Options {
		values += "\x00" + value.Value
	}
	if conversation.effortFor != values {
		conversation.effortFor = values
		conversation.effortMarks = make([]ui.SliderMark, n)
		for i := range conversation.effortMarks {
			conversation.effortMarks[i] = ui.SliderMark{Value: float32(i)}
		}
		conversation.effortMoved = false
		state.Value = float32(max(shown, 0))
	}
	under := func() int { return min(max(int(math.Round(float64(state.Value))), 0), n-1) }
	ui.Row(c).FillWidth().Gap(6).Items(ui.Center).PadX(6).PadY(2).Children(func() {
		ui.Text(c, agentSettingHeading(lang, setting)).FontSize(small).Color(a.colors.Subtle)
		ui.Spacer(c)
		ui.Text(c, agentValueName(setting.Options[under()])).FontSize(small).Weight(gfx.WeightMedium).Color(a.colors.Text)
	})
	ui.Row(c).FillWidth().PadX(6).Children(func() {
		if ui.Slider(c.Key("effort"), state).Range(0, float32(n-1)).Step(1).Marks(conversation.effortMarks).FillWidth().
			Label(agentSettingHeading(lang, setting)).Changed() {
			conversation.effortMoved = true
		}
	})
	if !state.Dragging() {
		if conversation.effortMoved {
			conversation.effortMoved = false
			at := under()
			state.Value = float32(at)
			if at != shown {
				id, picked := setting.ID, setting.Options[at].Value
				c.After(func() { a.setAgentOption(p, conversation, id, picked) })
			}
		} else {
			state.Value = float32(max(shown, 0))
		}
	}
	ui.Row(c).FillWidth().PadX(6).Children(func() {
		ui.Text(c, agentValueName(setting.Options[0])).FontSize(small).Color(a.colors.Subtle)
		ui.Spacer(c)
		ui.Text(c, agentValueName(setting.Options[n-1])).FontSize(small).Color(a.colors.Subtle)
	})
}

// agentContextFraction is how much of the context window the session uses, false when it
// reported no window.
func agentContextFraction(usage *agents.Usage) (float32, bool) {
	if usage == nil || usage.ContextWindow == 0 {
		return 0, false
	}
	return float32(min(float64(usage.ContextUsed)/float64(usage.ContextWindow), 1)), true
}

// agentRateFraction is how much of a usage window is used.
func agentRateFraction(window agents.RateWindow) float32 {
	return float32(min(max(window.UsedPercent/100, 0), 1))
}

// agentPercent writes a fraction as a whole percentage.
func agentPercent(fraction float32) string {
	return strconv.Itoa(int(math.Round(float64(fraction) * 100)))
}

// agentMeters declares the rings of the context the session uses and of its first usage
// window, with the card that details them on hover.
func (a *App) agentMeters(c ui.C, conversation *agentConversation) {
	t := conversation.transcript
	context, hasContext := agentContextFraction(t.Usage)
	if !hasContext && len(t.RateLimits) == 0 {
		return
	}
	lang := a.language()
	small := a.theme.Metrics.FontSizeS
	anchor := ui.Row(c).Shrink(0).Height(agentRowHeadHeight).PadX(4).Gap(6).Items(ui.Center).Radius(6)
	anchor.Children(func() {
		if hasContext {
			ui.Progress(c.Part("context"), context).Circle().Size(agentRingSize, agentRingSize)
			ui.Text(c, agentPercent(context)+"%").FontSize(small).Color(a.colors.Subtle)
		}
		if len(t.RateLimits) > 0 {
			rate := agentRateFraction(t.RateLimits[0])
			ui.Progress(c.Part("rate"), rate).Circle().Size(agentRingSize, agentRingSize)
			ui.Text(c, agentPercent(rate)+"%").FontSize(small).Color(a.colors.Subtle)
		}
	})
	card := c.Part("card")
	hovercard.View(card, i18n.Shared(lang, "desktop.agents.context.title"), (&hovercard.Card{
		Anchor: anchor, Open: &conversation.contextOpen,
		Body: func() { a.agentUsageCard(card, lang, t) },
	}).Side(hovercard.Top).Align(hovercard.End).Width(agentPopupWidth).Delays(250*time.Millisecond, 200*time.Millisecond))
}

// agentUsageCard declares the usage card: the context window used and left, its tokens and the
// model, then each usage window with when it resets.
func (a *App) agentUsageCard(c ui.C, lang i18n.Language, t *agents.Transcript) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Gap(6).Children(func() {
		context, hasContext := agentContextFraction(t.Usage)
		if hasContext {
			usage := t.Usage
			used := agentPercent(context)
			left := strconv.Itoa(100 - int(math.Round(float64(context)*100)))
			ui.Text(c, i18n.Shared(lang, "desktop.agents.context.title")).FontSize(small).Weight(gfx.WeightSemibold).Color(a.colors.Text)
			ui.Row(c.Part("context")).FillWidth().Children(func() {
				ui.Text(c, i18n.SharedFormat(lang, "desktop.agents.usedPercent", map[string]string{"percent": used})).FontSize(small).Color(a.colors.Text)
				ui.Spacer(c)
				ui.Text(c, i18n.SharedFormat(lang, "desktop.agents.leftPercent", map[string]string{"percent": left})).FontSize(small).Color(a.colors.Subtle)
			})
			ui.Progress(c.Part("context-bar"), context).FillWidth()
			ui.Text(c, i18n.SharedFormat(lang, "desktop.agents.context.tokens", map[string]string{
				"used": compactCount(usage.ContextUsed), "window": compactCount(usage.ContextWindow),
			})).FontSize(small).Color(a.colors.Subtle)
			model := t.Model
			if usage.Model != "" {
				model = usage.Model
			}
			if model != "" {
				ui.Row(c.Part("model")).FillWidth().Gap(6).Items(ui.Center).Children(func() {
					ui.Icon(c, icons.Sparkles).Size(12, 12).Color(a.colors.Subtle).Shrink(0)
					ui.Text(c, model).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
				})
			}
		}
		if len(t.RateLimits) == 0 {
			return
		}
		if hasContext {
			ui.Divider(c.Part("rule"))
		}
		ui.Text(c, i18n.Shared(lang, "desktop.agents.rate.title")).FontSize(small).Weight(gfx.WeightSemibold).Color(a.colors.Text)
		now := time.Now()
		for i, window := range t.RateLimits {
			k := c.KeyInt(i)
			rate := agentRateFraction(window)
			ui.Column(k).FillWidth().Gap(3).Children(func() {
				ui.Row(k).FillWidth().Children(func() {
					ui.Text(k, agentRateLabel(lang, window)).FontSize(small).Color(a.colors.Text)
					ui.Spacer(k)
					ui.Text(k, i18n.SharedFormat(lang, "desktop.agents.usedPercent", map[string]string{"percent": agentPercent(rate)})).
						FontSize(small).Color(a.colors.Subtle)
				})
				ui.Progress(k.Part("bar"), rate).FillWidth()
				if window.ResetsAtMs > 0 {
					ui.Text(k, i18n.SharedFormat(lang, "desktop.agents.rate.resets", map[string]string{
						"time": agentResetTime(now, time.UnixMilli(window.ResetsAtMs)),
					})).FontSize(small).Color(a.colors.Subtle)
				}
			})
		}
	})
}

// agentRateLabel names a usage window by its length: "5h", "Weekly", or the backend's label.
func agentRateLabel(lang i18n.Language, window agents.RateWindow) string {
	minutes := window.WindowMinutes
	switch {
	case minutes == 7*24*60:
		return i18n.Shared(lang, "desktop.agents.rate.weekly")
	case minutes >= 24*60 && minutes%(24*60) == 0:
		return i18n.SharedFormat(lang, "desktop.agents.rate.days", map[string]string{"count": strconv.FormatUint(minutes/(24*60), 10)})
	case minutes >= 60 && minutes%60 == 0:
		return i18n.SharedFormat(lang, "desktop.agents.rate.hours", map[string]string{"count": strconv.FormatUint(minutes/60, 10)})
	}
	if window.Label != "" {
		return window.Label
	}
	return window.ID
}

// agentResetTime writes when a usage window resets: the time of day within a day of now, else
// the date as well.
func agentResetTime(now, at time.Time) string {
	at = at.Local()
	if at.Sub(now) < 24*time.Hour {
		return at.Format("15:04")
	}
	return at.Format("01-02 15:04")
}

// agentSendButton declares the round Send button, or Stop while a turn runs.
func (a *App) agentSendButton(c ui.C, p *project, conversation *agentConversation) {
	lang := a.language()
	if conversation.transcript.ActiveTurn != 0 {
		if a.agentRoundButton(c.Key("stop"), i18n.Shared(lang, "desktop.agents.stop"), icons.Square, conversation.busy) {
			c.After(func() { a.cancelTurn(p, conversation) })
		}
		return
	}
	if a.agentRoundButton(c.Key("send"), i18n.Shared(lang, "desktop.agents.send"), icons.ArrowUp, !conversation.canSendPrompt()) {
		c.After(func() { a.sendPrompt(p, conversation, surfaceButton) })
	}
}

// agentRoundButton declares a round button filled with the text color, greyed while disabled,
// and reports a click on it.
func (a *App) agentRoundButton(c ui.C, label string, icon gfx.Icon, disabled bool) bool {
	background, color := a.colors.Text, a.colors.Ground
	if disabled {
		background, color = a.colors.Active, a.colors.Subtle
	}
	focused := components.ButtonRecipe(a.theme, components.ButtonGhost, gfx.State{FocusVisible: true})
	button := ui.ButtonBase(c, label).Size(agentSendSize, agentSendSize).Radius(agentSendSize / 2).Shrink(0).
		Items(ui.Center).Justify(ui.Center).Background(background).Tooltip(label).Disabled(disabled).
		Focus(ui.Look{}.Ring(focused.RingWidth, focused.Ring))
	button.Children(func() {
		ui.Icon(c, icon).Size(14, 14).Color(color)
	})
	return !disabled && button.Clicked()
}

// agentChatFooter declares the footer naming where the agent works: this computer, the folder
// and its branch.
func (a *App) agentChatFooter(c ui.C, p *project) {
	if p == nil {
		return
	}
	small := a.theme.Metrics.FontSizeS
	item := func(c ui.C, icon gfx.Icon, text string) {
		ui.Row(c).Shrink(1).MinWidth(0).Gap(4).Items(ui.Center).Children(func() {
			ui.Icon(c, icon).Size(12, 12).Color(a.colors.Subtle).Shrink(0)
			ui.Text(c, text).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
		})
	}
	ui.Row(c).FillWidth().Height(agentRowHeadHeight).Shrink(0).PadX(16).Gap(10).Items(ui.Center).Clip().Children(func() {
		item(c.Part("host"), icons.Monitor, agentHostLabel(a.language()))
		item(c.Part("folder"), icons.Folder, filepath.Base(p.root))
		if branch := p.git.branch(); branch != "" {
			item(c.Part("branch"), icons.GitBranch, branch)
		}
	})
}

// agentPromptNavigator declares the column of dots beside the transcript, one for each prompt
// the user sent (prompts share them past agentNavDots). The dot of the prompt at the top of the
// transcript is dark; hovering a dot shows its prompt, and a click scrolls to it.
func (a *App) agentPromptNavigator(c ui.C, conversation *agentConversation) {
	n := len(conversation.prompts)
	if n < 2 {
		return
	}
	dots := min(n, agentNavDots)
	// Which row is at the top is known once the transcript, declared after the navigator, has
	// been laid out: the column finds it as it paints, before the dots paint themselves.
	ui.Column(c).Width(agentNavWidth).FillHeight().Shrink(0).Justify(ui.Center).Items(ui.Center).
		Draw(func(*ui.DrawContext) { conversation.readRow = conversation.transcriptRead() }).
		Children(func() {
			for d := range dots {
				a.agentNavDot(c.KeyInt(d), conversation, agentDotPrompt(d, dots, n), agentDotPrompt(d+1, dots, n))
			}
		})
}

// agentDotPrompt is the first of the n prompts that dot d of the navigator's dots stands for,
// n past the last dot.
func agentDotPrompt(d, dots, n int) int {
	switch {
	case d >= dots:
		return n
	case n <= agentNavDots:
		return d
	}
	return d * (n - 1) / (agentNavDots - 1)
}

// transcriptRead is one more than the row being read as this paint laid the transcript out: the
// last declared row that starts at or above a quarter of the way down the list, so the end of a
// turn scrolled almost out of sight does not count. It is zero when the list shows no row.
func (conversation *agentConversation) transcriptRead() int {
	if len(conversation.shownRows) == 0 {
		return 0
	}
	area := conversation.transcriptBox.Rect()
	line := area.Y + area.Height/4
	at := conversation.shownRows[0].index
	for _, row := range conversation.shownRows {
		if row.box.Rect().Y > line {
			break
		}
		at = row.index
	}
	return at + 1
}

// currentPrompt is the prompt at the top of the transcript as the last paint laid it out: the
// last one sent at or above its top row, -1 when none is.
func (conversation *agentConversation) currentPrompt() int {
	current := -1
	if conversation.readRow == 0 {
		return current
	}
	for i, row := range conversation.prompts {
		if row >= conversation.readRow {
			break
		}
		current = i
	}
	return current
}

// agentNavDot declares the navigator's dot of prompts [i, next) and the card of prompt i. The
// dot is dark while one of them is the current prompt, which is known as it paints.
func (a *App) agentNavDot(c ui.C, conversation *agentConversation, i, next int) {
	lang := a.language()
	row := conversation.prompts[i]
	entry := conversation.transcript.Entries[conversation.rows[row].entry]
	title := agentFirstLine(entry.Text)
	dot := ui.ButtonBase(c, title).Size(agentNavWidth, 10).Items(ui.Center).Justify(ui.Center)
	dot.Children(func() {
		ui.Column(c).Size(6, 6).Draw(func(dc *ui.DrawContext) {
			color := a.colors.Line
			if current := conversation.currentPrompt(); current >= i && current < next {
				color = a.colors.Text
			}
			dc.Canvas.Rounded(dc.Rect, 3, dc.Fade(color))
		})
	})
	if dot.Clicked() {
		c.After(func() {
			conversation.list.ScrollTo(row, ui.ListStart)
			conversation.jump = len(conversation.rows) + 1
		})
	}
	open := conversation.navCard == i+1
	card := c.Part("card")
	hovercard.View(card, title, (&hovercard.Card{
		Anchor: dot, Open: &open,
		Body: func() { a.agentPromptPreview(card, lang, conversation, i, entry) },
	}).Side(hovercard.Right).Align(hovercard.Center).Width(agentNavCardWidth).Delays(150*time.Millisecond, 100*time.Millisecond))
	if open {
		conversation.navCard = i + 1
	} else if conversation.navCard == i+1 {
		conversation.navCard = 0
	}
}

// agentPromptPreview declares the card of prompt i: its first line, the start of the rest,
// which prompt it is and when it was sent.
func (a *App) agentPromptPreview(c ui.C, lang i18n.Language, conversation *agentConversation, i int, entry agents.Entry) {
	small := a.theme.Metrics.FontSizeS
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		ui.Paragraph(c, agentFirstLine(entry.Text), 2).FontSize(a.theme.Metrics.FontSizeM).Weight(gfx.WeightSemibold).Color(a.colors.Text).FillWidth()
		if rest := agentPromptRest(entry.Text); rest != "" {
			ui.Paragraph(c, rest, 3).FontSize(small).Color(a.colors.Subtle).FillWidth()
		}
		ui.Row(c).FillWidth().Gap(6).Children(func() {
			ui.Text(c, i18n.SharedFormat(lang, "desktop.agents.prompts.position", map[string]string{
				"number": strconv.Itoa(i + 1), "total": strconv.Itoa(len(conversation.prompts)),
			})).FontSize(small).Color(a.colors.Subtle)
			ui.Spacer(c)
			sent := conversation.sentAt
			if entry.Turn != 0 {
				sent = conversation.turnTimes[entry.Turn].started
			}
			if !sent.IsZero() {
				ui.Text(c, sent.Local().Format("01-02 15:04")).FontSize(small).Color(a.colors.Subtle)
			}
		})
	})
}

// agentPromptRest is a prompt after its first line with text, its spaces collapsed.
func agentPromptRest(text string) string {
	text = strings.TrimLeft(text, " \t\r\n")
	_, rest, _ := strings.Cut(text, "\n")
	return strings.Join(strings.Fields(rest), " ")
}
