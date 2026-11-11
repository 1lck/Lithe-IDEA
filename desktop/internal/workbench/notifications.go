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
// user looked elsewhere can be read again from the bell in the status bar.
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
	text  string
	kind  ui.ToastKind
	count int
	// at is when it came last.
	at time.Time
	// unread says it came after the history was last looked at.
	unread bool
	// toast is the toast that shows it, which may have gone by itself already.
	toast ui.ToastID
}

// notificationCenter is the history, newest first, and whether its panel is open.
type notificationCenter struct {
	list []*notification
	open bool
}

// unread counts the notices that came since the history was last looked at.
func (n *notificationCenter) unread() int {
	count := 0
	for _, entry := range n.list {
		if entry.unread {
			count++
		}
	}
	return count
}

// notify shows message in a toast and keeps it in the notification history.
func (a *App) notify(message string) { a.notifyKind(message, ui.ToastWarning) }

// notifyKind shows message as a toast of kind and records it. The same message of the same
// kind again is not a second entry: its entry counts it, moves to the top, is unread again
// and its toast shows the count, replacing the toast it had.
func (a *App) notifyKind(message string, kind ui.ToastKind) {
	a.notice = message
	center := &a.notifications
	var entry *notification
	for i, existing := range center.list {
		if existing.text == message && existing.kind == kind {
			entry = existing
			center.list = append(center.list[:i], center.list[i+1:]...)
			a.overlay.toaster.Close(existing.toast)
			break
		}
	}
	if entry == nil {
		entry = &notification{text: message, kind: kind}
	}
	entry.count++
	entry.at = a.now()
	entry.unread = !center.open
	center.list = append([]*notification{entry}, center.list...)
	if len(center.list) > notificationHistoryLimit {
		center.list = center.list[:notificationHistoryLimit]
	}
	entry.toast = a.overlay.toaster.Show(a.notificationText(entry), "", kind)
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
	bell := ui.Row(k).Height(chromeStatusItem).Shrink(0).Items(ui.Center).Gap(4).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
		Hover(ui.Look{}.Background(a.colors.Hover))
	bell.Children(func() {
		color := a.colors.Subtle
		if unread > 0 {
			color = a.colors.Text
		}
		ui.Icon(k, icons.Bell).Size(chromeMarkSize, chromeMarkSize).Color(color)
		if unread > 0 {
			a.chromeStatusLabel(k, strconv.Itoa(unread))
		}
	})
	if bell.Clicked() {
		center.open = !center.open
	}
	if center.open {
		// Looking at the history reads it.
		for _, entry := range center.list {
			entry.unread = false
		}
	}
	a.notificationPanel(c, bell)
}

// notificationPanel declares the open history above the bell: a Clear button, then each
// notice with when it came last and how often, newest first.
func (a *App) notificationPanel(c ui.C, anchor ui.Box) {
	center := &a.notifications
	language := a.language()
	cleared := false
	spec := ui.PopoverSpec{Side: components.PopoverTop, Align: ui.End, Offset: chromeMenuOffset, Width: notificationPanelWidth, ConsumeOutsidePress: true}
	ui.PopoverWith(c, anchor, spec, &center.open, func() {
		ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.notifications.title")).Weight(gfx.WeightSemibold).Grow(1).Ellipsis()
			if len(center.list) > 0 && ui.Button(c.Part("clear"), i18n.Shared(language, "desktop.notifications.clear")).Ghost().Clicked() {
				cleared = true
			}
		})
		if len(center.list) == 0 {
			ui.Text(c, i18n.Shared(language, "desktop.notifications.empty")).Color(a.colors.Subtle)
			return
		}
		ui.Scroll(c.Part("list")).FillWidth().MaxHeight(notificationPanelHeight).Gap(8).Children(func() {
			for i, entry := range center.list {
				k := c.KeyInt(i)
				ui.Column(k).FillWidth().Shrink(0).Gap(2).Children(func() {
					ui.Wrap(k, entry.text).FontSize(a.theme.Metrics.FontSizeS)
					meta := entry.at.Format("15:04:05")
					if entry.count > 1 {
						meta = i18n.SharedFormat(language, "desktop.notifications.meta", map[string]string{"time": meta, "count": strconv.Itoa(entry.count)})
					}
					ui.Text(k, meta).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
				})
			}
		})
	})
	if cleared {
		c.After(a.clearNotifications)
	}
}
