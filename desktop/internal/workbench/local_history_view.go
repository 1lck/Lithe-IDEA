package workbench

import (
	"strconv"
	"strings"
	"time"

	"github.com/vivaui/viva/ui"
)

// localHistoryPreviewLines caps the lines the preview declares; Restore still uses
// the whole snapshot.
const localHistoryPreviewLines = 2000

// drawLocalHistory declares the Local History dialog: the file's snapshots newest
// first, the selected one's text, its label, and Restore and Delete.
func (a *App) drawLocalHistory(c ui.C, p *project) {
	h := &p.history
	if p == nil || !h.open {
		return
	}
	t := a.text.History
	open := true
	closed := ui.ModalWith(c, &open, t.Title, ui.ModalSpec{Width: 760, Description: h.rel}, func() {
		ui.Column(c.Part("local-history")).FillWidth().Gap(8).Children(func() {
			if h.failure != "" {
				ui.Paragraph(c, h.failure, 4).Color(a.theme.Danger)
			}
			switch {
			case h.loading:
				ui.Text(c, t.Loading).Muted()
				return
			case len(h.entries) == 0:
				ui.Text(c, t.Empty).Muted()
				return
			}
			ui.Row(c).FillWidth().Height(380).Gap(8).Children(func() {
				a.localHistoryList(c, p)
				ui.Column(c.Part("preview")).Grow(1).MinWidth(0).FillHeight().Gap(6).Children(func() {
					ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
						ui.TextField(c.Key("label"), &h.label, t.Rename, t.LabelPlaceholder).Grow(1).MinWidth(0)
						if ui.Button(c.Key("rename"), t.Rename).Small().Disabled(h.busy || h.selected < 0).Clicked() {
							c.After(func() { a.renameLocalHistory(p) })
						}
					})
					ui.Scroll(c.Part("preview-text")).Grow(1).MinHeight(0).FillWidth().Children(func() {
						if !h.previewReady {
							ui.Text(c, t.PreviewLoading).Muted()
							return
						}
						for i, line := range strings.SplitN(h.preview, "\n", localHistoryPreviewLines+1) {
							if i == localHistoryPreviewLines {
								ui.Text(c.KeyInt(i), "…").Muted()
								break
							}
							ui.Text(c.KeyInt(i), line).Mono().FontSize(12).Color(a.colors.Text)
						}
					})
				})
			})
		})
	}, func() {
		ready := !h.busy && h.selected >= 0 && h.selected < len(h.entries)
		if ui.Button(c, t.Delete).Outline().Disabled(!ready).Clicked() {
			c.After(func() { a.deleteLocalHistory(p) })
		}
		ui.Spacer(c)
		if ui.Button(c, t.Close).Outline().Clicked() {
			c.After(func() { h.open = false })
		}
		if ui.Button(c, t.Restore).Disabled(!ready || !h.previewReady).Clicked() {
			c.After(func() { a.restoreLocalHistory(p) })
		}
	})
	if closed {
		c.After(func() { h.open = false })
	}
}

// localHistoryList is the snapshot list: time, reason and label of each.
func (a *App) localHistoryList(c ui.C, p *project) {
	h := &p.history
	t := a.text.History
	entries := h.entries
	h.list.Label = func(i int) string { return localHistoryTime(entries[i].Timestamp) }
	if h.selected >= 0 && h.selected != h.list.Selected() {
		h.list.Select(h.selected)
	}
	pick := -1
	ui.List(c.Part("entries"), &h.list, len(entries), func(row ui.ListRow) {
		entry := entries[row.Index]
		row.Element.FillWidth().PadX(8).PadY(4).Children(func() {
			ui.Column(row.C).FillWidth().Gap(2).Children(func() {
				ui.Text(row.C, localHistoryTime(entry.Timestamp)).FontSize(13).Color(a.colors.Text)
				detail := t.Reason(entry.Reason) + " · " + strconv.Itoa(entry.ByteCount) + " B"
				ui.Text(row.C, detail).FontSize(12).Color(a.colors.Subtle).Ellipsis()
				if entry.Label != "" {
					ui.Text(row.C, entry.Label).FontSize(12).Color(a.colors.Text).Ellipsis()
				}
			})
		})
		if row.Element.Clicked() {
			pick = row.Index
		}
	}).Label(t.Title).Width(240).FillHeight()
	if h.list.Changed() && h.list.Selected() >= 0 {
		pick = h.list.Selected()
	}
	if pick >= 0 && pick != h.selected {
		c.After(func() { a.selectLocalHistory(p, pick) })
	}
}

// localHistoryTime shows a snapshot's time (Core's Unix seconds) in local time.
func localHistoryTime(seconds int64) string {
	return time.Unix(seconds, 0).Local().Format("2006-01-02 15:04:05")
}
