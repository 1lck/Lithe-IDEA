package workbench

import (
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The notification center keeps what the toasts said, so a notice that went by while the
// user looked elsewhere can be read again in the tool window or from the status bar.
const (
	// notificationHistoryLimit is how many notices the history keeps; the oldest go first.
	notificationHistoryLimit = 100
	// notificationPanelWidth and notificationPanelHeight bound the history panel.
	notificationPanelWidth  = 360
	notificationPanelHeight = 360
)

// notification is one notice of the history. Notices with the same text and kind are one
// entry that counts how often it came.
type notification struct {
	id     int
	text   string
	detail string
	kind   ui.ToastKind
	count  int
	// at is when it came last.
	at time.Time
	// unread says it came after the history was last looked at.
	unread bool
	// merge allows a later identical notice to replace this notice's action.
	merge bool
	// toast is the toast that shows it, which may have gone by itself already.
	toast ui.ToastID
	// op is the user action the failure was last reported under, empty when it never came
	// during one. The toast and the history offer View Logs for it, which opens the log window
	// on that action's records.
	op string
	// act is what the notice's own button does, labeled actLabel, nil for a notice without
	// one; it runs on the workbench the notice is on. A notice with an action offers no View Logs.
	act               func(*App)
	actLabel          string
	secondaryAct      func(*App)
	secondaryActLabel string
}

// notificationCenter owns the history shared by the tool window and the status popover.
type notificationCenter struct {
	list     []*notification
	open     bool // status-bar popover
	toolList ui.ListState
}

// Unread entries form a prefix: arrivals move to the front, and the open history
// marks all its entries read.
func (n *notificationCenter) unread() int {
	for i, entry := range n.list {
		if !entry.unread {
			return i
		}
	}
	return len(n.list)
}

func (n *notificationCenter) markRead() {
	for _, entry := range n.list {
		if !entry.unread {
			return
		}
		entry.unread = false
	}
}

// notify shows message in a toast and keeps it in the notification history. It is the
// warning style: something the user should look at that did not fail. notifyError,
// notifySuccess and notifyInfo are the other kinds, each with its own color and icon in the
// toast and in the history.
func (a *App) notify(message string) { a.notifyKind(message, ui.ToastWarning) }

// notifyError reports an operation that failed.
func (a *App) notifyError(message string) { a.notifyKind(message, ui.ToastError) }

// notifySuccess reports an operation that finished as asked.
func (a *App) notifySuccess(message string) { a.notifyKind(message, ui.ToastSuccess) }

// notifyInfo reports a state, such as nothing to do.
func (a *App) notifyInfo(message string) { a.notifyKind(message, ui.ToastInfo) }

// notificationColor is the mark of a kind in the history.
func (a *App) notificationColor(kind ui.ToastKind) gfx.Color {
	switch kind {
	case ui.ToastError:
		return a.colors.Deleted
	case ui.ToastSuccess:
		return a.colors.Success
	case ui.ToastWarning:
		return a.colors.Warning
	}
	return a.colors.Subtle
}

// notifyKind shows message as a toast of kind and records it. The same message of the same
// kind again is not a second entry: its entry counts it, moves to the top, is unread again
// and its toast shows the count, replacing the toast it had. A failure reported during a user
// action refers to the action's records: its toast has a View Logs button.
func (a *App) notifyKind(message string, kind ui.ToastKind) {
	a.notifyAction(message, kind, "", nil)
}

// notifyAction is notifyKind with a button of the notice's own, label, which runs act. A
// repeat of the notice keeps the latest button.
func (a *App) notifyAction(message string, kind ui.ToastKind, label string, act func(*App)) {
	a.notifyActions(message, "", kind, label, act, "", nil)
}

// notifyActions is notifyKind with optional wrapped detail text and up to two notice-specific
// buttons. The floating toast shows the primary button while the notification history shows both.
func (a *App) notifyActions(title, detail string, kind ui.ToastKind, label string, act func(*App), secondaryLabel string, secondaryAct func(*App)) {
	a.recordNotification(title, detail, kind, label, act, secondaryLabel, secondaryAct, true)
}

// notifyOperationAction keeps a separate history entry for every operation. Identical
// summaries can reopen different results and must keep their own callbacks.
func (a *App) notifyOperationAction(title, detail, label string, act func(*App)) {
	a.recordNotification(title, detail, ui.ToastError, label, act, "", nil, false)
}

func (a *App) recordNotification(title, detail string, kind ui.ToastKind, label string, act func(*App), secondaryLabel string, secondaryAct func(*App), merge bool) {
	if detail != "" {
		a.notice = detail
	} else {
		a.notice = title
	}
	center := &a.notifications
	var entry *notification
	for i, existing := range center.list {
		if merge && existing.text == title && existing.detail == detail && existing.kind == kind && existing.merge {
			entry = existing
			center.list = append(center.list[:i], center.list[i+1:]...)
			a.overlay.toaster.Close(existing.toast)
			break
		}
	}
	if entry == nil {
		entry = &notification{text: title, detail: detail, kind: kind, merge: merge}
	}
	entry.count++
	entry.at = a.now()
	entry.act, entry.actLabel = act, label
	entry.secondaryAct, entry.secondaryActLabel = secondaryAct, secondaryLabel
	entry.unread = !center.open
	if kind == ui.ToastError && a.op.id != "" {
		entry.op = a.op.id
	}
	center.list = append([]*notification{entry}, center.list...)
	if len(center.list) > notificationHistoryLimit {
		center.list = center.list[:notificationHistoryLimit]
	}
	action := ""
	switch {
	case entry.act != nil:
		action = entry.actLabel
	case a.viewsLogs(entry):
		action = i18n.Shared(a.language(), "desktop.notifications.viewLogs")
	}
	entry.toast = a.overlay.toaster.ShowAction(a.notificationText(entry), entry.detail, kind, action)
	if entry.id == 0 {
		// Keep the first toast's identity when a repeat replaces the current toast.
		entry.id = int(entry.toast)
	}
}

// viewsLogs says the notice offers View Logs: it refers to an action's records and there is a
// log window to show them in.
func (a *App) viewsLogs(entry *notification) bool {
	return entry.act == nil && entry.secondaryAct == nil && entry.op != "" && a.logs != nil
}

// notificationActed runs the button of the notice whose toast this paint delivered a press on:
// its own, or View Logs, which opens its records. Call it after ui.Toasts.
func (a *App) notificationActed(c ui.C) {
	id, ok := a.overlay.toaster.Acted()
	if !ok {
		return
	}
	for _, entry := range a.notifications.list {
		if entry.toast == id && entry.act != nil {
			act := entry.act
			c.After(func() { a.notificationAct(act) })
			return
		}
		if entry.toast == id && entry.op != "" {
			op := entry.op
			c.After(func() { a.viewNotificationLogs(op) })
			return
		}
	}
}

// viewNotificationLogs is View Logs on a notice: the log window on the records of op, the
// action the notice reported a failure of.
func (a *App) viewNotificationLogs(op string) {
	a.performed("logs.openOperation", surfaceNotification)
	a.showLogs(op)
}

// notificationAct runs a notice's own button, which closes the history it may be pressed in.
func (a *App) notificationAct(act func(*App)) {
	a.notifications.open = false
	act(a)
}

// notificationText is a notice's words, with how often it came when that is more than once.
func (a *App) notificationText(entry *notification) string {
	if entry.count < 2 {
		return entry.text
	}
	return i18n.SharedFormat(a.language(), "desktop.notifications.repeated", map[string]string{
		"message": entry.text, "count": strconv.Itoa(entry.count),
	})
}

// clearNotifications forgets the history and takes down the toasts that still show it.
func (a *App) clearNotifications() {
	for _, entry := range a.notifications.list {
		a.overlay.toaster.Close(entry.toast)
	}
	a.notifications.list = nil
}

func (a *App) notificationClearButton(c ui.C) {
	if len(a.notifications.list) == 0 {
		return
	}
	label := i18n.Shared(a.language(), "desktop.notifications.clear")
	if ui.Button(c.Part("clear"), label).Ghost().Small().Shrink(0).Clicked() {
		c.After(a.clearNotifications)
	}
}

// notificationsToolBody declares the docked history in the available panel space.
func (a *App) notificationsToolBody(c ui.C) {
	center := &a.notifications
	center.markRead()
	if len(center.list) == 0 {
		a.panelMessage(c, i18n.Shared(a.language(), "desktop.notifications.empty"), a.colors.Subtle)
		return
	}
	list := &center.toolList
	if list.Key == nil {
		list.Key = func(i int) int { return center.list[i].id }
		list.Label = func(i int) string {
			entry := center.list[i]
			if entry.detail != "" {
				return entry.text + " — " + entry.detail
			}
			return entry.text
		}
	}
	label := i18n.Shared(a.language(), "desktop.notifications.title")
	ui.List(c, list, len(center.list), func(row ui.ListRow) {
		a.notificationRow(row.C, row.Element.PadX(shellContentPad).PadY(4), center.list[row.Index])
	}).Scrollbars().Label(label).FillWidth().Grow(1).MinHeight(0)
}

// notificationBell declares the status bar's bell: it names the unread notices, and a
// press opens the history, which marks them read.
func (a *App) notificationBell(c ui.C) {
	center := &a.notifications
	language := a.language()
	k := c.Part("notifications")
	unread := center.unread()
	label := i18n.Shared(language, "desktop.notifications.title")
	if unread > 0 {
		label = i18n.SharedFormat(language, "desktop.notifications.unread", map[string]string{"count": strconv.Itoa(unread)})
	}
	bell := ui.Row(k).Height(chromeStatusItem).Shrink(0).Items(ui.Center).Gap(4).PadX(chromeStatusPad).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
		Hover(ui.Look{}.Background(a.colors.Hover))
	bell.Children(func() {
		color := a.colors.Subtle
		if unread > 0 {
			color = a.colors.Text
		}
		ui.Icon(c, icons.Bell).Size(chromeMarkSize, chromeMarkSize).Color(color)
		if unread > 0 {
			a.chromeStatusLabel(k, strconv.Itoa(unread))
		}
	})
	if bell.Clicked() {
		center.open = !center.open
	}
	if center.open {
		center.markRead()
	}
	a.notificationPanel(c, bell)
}

// notificationPanel declares the open history above the bell: a Clear button, then each
// notice with when it came last and how often, newest first.
func (a *App) notificationPanel(c ui.C, anchor ui.Box) {
	center := &a.notifications
	language := a.language()
	align := ui.End
	if a.project == nil {
		// On the welcome page the bell is at the left edge of the window.
		align = ui.Start
	}
	spec := ui.PopoverSpec{Side: components.PopoverTop, Align: align, Offset: chromeMenuOffset, Width: notificationPanelWidth, ConsumeOutsidePress: true}
	ui.Popover(c, anchor, &center.open, spec, func() {
		ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.notifications.title")).Weight(gfx.WeightSemibold).Grow(1).Ellipsis()
			a.notificationClearButton(c)
		})
		if len(center.list) == 0 {
			ui.Text(c, i18n.Shared(language, "desktop.notifications.empty")).Color(a.colors.Subtle)
			return
		}
		ui.Scroll(c.Part("list")).Scrollbars().FillWidth().MaxHeight(notificationPanelHeight).Gap(8).Children(func() {
			for i, entry := range center.list {
				k := c.KeyInt(i)
				a.notificationRow(k, ui.Row(k), entry)
			}
		})
	})
}

func (a *App) notificationRow(c ui.C, row ui.Box, entry *notification) {
	row.FillWidth().Shrink(0).Gap(8).Items(ui.Start).Children(func() {
		ui.Row(c).Size(8, 8).Shrink(0).MarginTop(5).Radius(4).Background(a.notificationColor(entry.kind))
		ui.Column(c).Grow(1).MinWidth(0).Gap(2).Children(func() {
			a.notificationEntry(c, entry)
		})
	})
}

// notificationEntry declares a notice of the history: its words, when it came last and how
// often, and View Logs when it refers to an action's records.
func (a *App) notificationEntry(c ui.C, entry *notification) {
	language := a.language()
	if entry.detail != "" {
		ui.Wrap(c, entry.text).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightMedium)
		ui.Wrap(c, entry.detail).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	} else {
		ui.Wrap(c, entry.text).FontSize(a.theme.Metrics.FontSizeS)
	}
	meta := entry.at.Format("15:04:05")
	if entry.count > 1 {
		meta = i18n.SharedFormat(language, "desktop.notifications.meta", map[string]string{"time": meta, "count": strconv.Itoa(entry.count)})
	}
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		ui.Text(c, meta).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).Ellipsis()
		if entry.act != nil && ui.Button(c.Part("act"), entry.actLabel).Ghost().Small().Shrink(0).Clicked() {
			act := entry.act
			c.After(func() { a.notificationAct(act) })
		}
		if entry.secondaryAct != nil && ui.Button(c.Part("secondary"), entry.secondaryActLabel).Ghost().Small().Shrink(0).Clicked() {
			act := entry.secondaryAct
			c.After(func() { a.notificationAct(act) })
		}
		if a.viewsLogs(entry) && ui.Button(c.Part("logs"), i18n.Shared(language, "desktop.notifications.viewLogs")).Ghost().Small().Shrink(0).Clicked() {
			op := entry.op
			c.After(func() { a.viewNotificationLogs(op) })
		}
	})
}
