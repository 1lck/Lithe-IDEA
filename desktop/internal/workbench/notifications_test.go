package workbench

import (
	"fmt"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logwindow"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The same notice again is one entry that counts: it moves to the top, is unread again,
// carries the last time it came, and its toast shows the count. Another notice stays apart.
func TestRepeatedNoticesAreOneEntryWithACount(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	clock := time.Date(2026, 11, 11, 9, 30, 0, 0, time.Local)
	h.app.now = func() time.Time { return clock }

	h.app.notify("Build failed")
	h.app.notify("Index ready")
	clock = clock.Add(time.Minute)
	h.app.notify("Build failed")
	// The notices came outside a frame: ask for the repaint the window would make.
	h.app.invalidator.Invalidate()
	h.settle()

	list := h.app.notifications.list
	if len(list) != 2 || list[0].text != "Build failed" || list[0].count != 2 || list[1].text != "Index ready" {
		t.Fatalf("history = %+v", list)
	}
	if !list[0].at.Equal(clock) || !list[0].unread {
		t.Fatalf("the repeated notice kept its first time or read state: %+v", list[0])
	}
	if !h.shows("Build failed (2)") {
		t.Fatal("the toast does not show the count")
	}
	// The repeated notice replaced its toast: one for it, one for the other notice.
	if n := h.app.overlay.toaster.Len(); n != 2 {
		t.Fatalf("%d toasts are up, want 2", n)
	}
}

// The bell names the unread notices; opening the history lists them and reads them, and
// Clear empties it and takes the toasts down.
func TestNotificationBellOpensReadsAndClearsTheHistory(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	h.app.notify("Plugin updated")
	h.app.notify("Index ready")
	h.app.invalidator.Invalidate()
	h.settle()

	h.clickNamed("Notifications, 2 unread")
	h.settle()
	if !h.shows("Plugin updated") || !h.shows("Index ready") {
		t.Fatal("the history does not list the notices")
	}
	if n := h.app.notifications.unread(); n != 0 {
		t.Fatalf("opening the history left %d unread", n)
	}
	h.clickNamed("Clear")
	h.settle()
	if len(h.app.notifications.list) != 0 || h.app.overlay.toaster.Len() != 0 {
		t.Fatalf("clear left %d notices and %d toasts", len(h.app.notifications.list), h.app.overlay.toaster.Len())
	}
	if !h.shows("No notifications") {
		t.Fatal("the emptied history does not say so")
	}
}

func TestNotificationsToolWindowSharesTheHistory(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	toggle := func() {
		h.click(center(h.button(itemNotifications)))
		h.settle()
	}
	notify := func() {
		h.app.notifyInfo("Plugin updated")
		h.app.invalidator.Invalidate()
		h.settle()
	}
	hideToasts := func() {
		for _, entry := range h.app.notifications.list {
			h.app.overlay.toaster.Close(entry.toast)
		}
		h.app.invalidator.Invalidate()
		h.settle()
	}
	toggle()
	if !h.showsWrapped("No notifications") {
		t.Fatal("opening the tool window with an empty history did not show its empty state")
	}
	toggle()
	notify()
	hideToasts()
	if _, ok := h.findPageHit("Notifications, 1 unread"); !ok || h.showsWrapped("Plugin updated") {
		t.Fatal("the closed tool window should leave the notice unread and out of view")
	}

	toggle()
	if !h.showsWrapped("Plugin updated") {
		t.Fatal("the tool window did not show the notice after its toast closed")
	}
	if _, ok := h.findPageHit("Notifications, 1 unread"); ok {
		t.Fatal("opening the tool window did not clear the unread badge")
	}
	notify()
	if !h.shows("2 times") {
		t.Fatal("the tool window did not update the repetition count")
	}
	if _, ok := h.findPageHit("Notifications, 1 unread"); ok {
		t.Fatal("a notice received while the tool window was open showed as unread")
	}

	h.clickNamed("Clear")
	h.settle()
	if !h.showsWrapped("No notifications") || h.app.overlay.toaster.Len() != 0 {
		t.Fatal("clearing from the tool window did not empty it")
	}
	toggle()
	h.clickNamed("Notifications")
	h.settle()
	if !h.shows("No notifications") {
		t.Fatal("the status-bar history did not reflect the clear")
	}
}

func TestNotificationsToolWindowScrollsToOlderNotices(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	for i := range notificationHistoryLimit {
		h.app.notifyInfo(fmt.Sprintf("Notification %03d", i))
	}
	for _, entry := range h.app.notifications.list {
		h.app.overlay.toaster.Close(entry.toast)
	}
	h.app.invalidator.Invalidate()
	h.settle()
	h.click(center(h.button(itemNotifications)))
	h.settle()
	if !h.showsWrapped("Notification 099") || h.showsWrapped("Notification 000") {
		t.Fatal("the history should start at its newest notifications")
	}
	row, ok := h.findPageHit("Notification 099")
	if !ok {
		t.Fatal("the notification row is missing its accessible name")
	}
	at := center(row.Bounds)
	// Continue after the virtual list has measured newly revealed rows.
	for range 4 {
		if err := h.driver.Scroll(gfx.ScrollEvent{X: at.X, Y: at.Y, DeltaY: 20000, Precise: true}); err != nil {
			t.Fatalf("scroll notification history: %v", err)
		}
		h.settle()
		if h.showsWrapped("Notification 000") {
			return
		}
	}
	first, last := h.app.notifications.toolList.Visible()
	t.Fatalf("scrolling from %v did not reveal the oldest notification (rows %d to %d)", row.Bounds, first, last)
}

// pageControls counts the controls named name that the pages declared.
func (h *harness) pageControls(name string) int {
	count := 0
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.Label == name && !hit.IsLabel && !hit.Backdrop && !hit.ID.IsZero() {
			count++
		}
	}
	return count
}

// A failure reported during a user action refers to the action's records: its toast and its
// history entry offer View Logs, which opens the log window on them as an action of its own.
// A failure outside an action and a notice of another kind offer none.
func TestFailureNoticeOpensTheLogsOfTheActionThatFailed(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	logger := &opRecordingLog{}
	h.app.logSink = logger
	h.app.logs = logwindow.NewController(logwindow.WindowOptions{})
	var opened []string
	h.app.logWindowOpen = func(op string) error {
		opened = append(opened, op)
		return nil
	}
	viewLogs := i18n.Shared(h.app.language(), "desktop.notifications.viewLogs")

	h.app.performed("test.build", surfaceButton)
	failed := h.app.op.id
	h.app.notifyError("Build failed")
	h.app.notifySuccess("Build cached")
	h.app.endOperation()
	h.app.notifyError("Index broken")
	h.app.invalidator.Invalidate()
	h.settle()

	ops := map[string]string{}
	for _, entry := range h.app.notifications.list {
		ops[entry.text] = entry.op
	}
	if ops["Build failed"] != failed || ops["Build cached"] != "" || ops["Index broken"] != "" {
		t.Fatalf("the notices refer to %v; only the failure during action %q should", ops, failed)
	}
	if n := h.pageControls(viewLogs); n != 1 {
		t.Fatalf("%d toasts offer %s, want only the failure's", n, viewLogs)
	}

	// The failure's toast sits behind the newest one in the collapsed stack; the pointer
	// resting on the stack spreads it out, as a user's does, before the press.
	collapsed := center(h.pageHit(viewLogs).Bounds)
	if err := h.driver.Move(collapsed.X, collapsed.Y); err != nil {
		t.Fatal(err)
	}
	h.settle()
	h.clickNamed(viewLogs)
	h.settle()
	if len(opened) != 1 || opened[0] != failed {
		t.Fatalf("the toast opened the logs of %q, want %q", opened, failed)
	}
	viewed := logger.ops("app.action.performed")
	if len(viewed) != 2 || viewed[1] == "" || viewed[1] == failed {
		t.Fatalf("View Logs was recorded under %q; want an action of its own after %q", viewed, failed)
	}

	// The history offers the same once the toasts have gone.
	for _, entry := range h.app.notifications.list {
		h.app.overlay.toaster.Close(entry.toast)
	}
	h.app.invalidator.Invalidate()
	h.settle()
	h.clickNamed("Notifications, 3 unread")
	h.settle()
	if n := h.pageControls(viewLogs); n != 1 {
		t.Fatalf("%d history entries offer %s, want only the failure's", n, viewLogs)
	}
	h.clickNamed(viewLogs)
	h.settle()
	if len(opened) != 2 || opened[1] != failed {
		t.Fatalf("the history opened the logs of %q, want %q", opened, failed)
	}
	h.clickNamed("Notifications")
	h.settle()
	h.click(center(h.button(itemNotifications)))
	h.settle()
	h.clickNamed(viewLogs)
	h.settle()
	if len(opened) != 3 || opened[2] != failed {
		t.Fatalf("the tool window opened the logs of %q, want %q", opened, failed)
	}
}

// The history keeps the newest notices up to its limit.
func TestNotificationHistoryKeepsTheNewest(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	for i := range notificationHistoryLimit + 5 {
		h.app.notify(fmt.Sprintf("notice %d", i))
	}
	list := h.app.notifications.list
	if len(list) != notificationHistoryLimit || list[0].text != fmt.Sprintf("notice %d", notificationHistoryLimit+4) ||
		list[len(list)-1].text != "notice 5" {
		t.Fatalf("history holds %d, newest %q, oldest %q", len(list), list[0].text, list[len(list)-1].text)
	}
}

// A notice keeps its kind: the same words as an error and as a success are two entries.
// At most three toasts are up at once, the oldest going first, while the history keeps all.
// The welcome page, which has no status bar, still has the bell.
func TestNoticesKeepTheirKindAndShowAtMostThreeToasts(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.app.notifyError("Sync")
	h.app.notifySuccess("Sync")
	h.app.notifyInfo("Index ready")
	h.app.notify("Disk almost full")
	h.app.invalidator.Invalidate()
	h.settle()

	list := h.app.notifications.list
	if len(list) != 4 {
		t.Fatalf("history = %+v, want four entries", list)
	}
	kinds := map[ui.ToastKind]int{}
	for _, entry := range list {
		kinds[entry.kind]++
	}
	if kinds[ui.ToastError] != 1 || kinds[ui.ToastSuccess] != 1 || kinds[ui.ToastInfo] != 1 || kinds[ui.ToastWarning] != 1 {
		t.Fatalf("the kinds are %v", kinds)
	}
	if n := h.app.overlay.toaster.Len(); n != 3 {
		t.Fatalf("%d toasts are up, want three", n)
	}
	if !h.shows("Disk almost full") || !h.shows("Index ready") {
		t.Fatal("the newest toasts are not up")
	}
	if _, ok := h.findPageHit("Notifications, 4 unread"); !ok {
		t.Fatal("the welcome page has no bell")
	}
}

func TestNotificationSupportsPrimaryAndSecondaryActions(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.open(t.TempDir())
	clock := time.Date(2026, 11, 11, 10, 0, 0, 0, time.Local)
	h.app.now = func() time.Time { return clock }

	var primaryCalls, secondaryCalls int
	h.app.notifyActions(
		"Recommended plugins",
		"Suggested for this project: Demo Lang",
		ui.ToastInfo,
		"View Plugins", func(*App) { primaryCalls++ },
		"Don't Show Again", func(*App) { secondaryCalls++ },
	)
	h.app.invalidator.Invalidate()
	h.settle()

	if len(h.app.notifications.list) != 1 {
		t.Fatalf("notifications = %d, want 1", len(h.app.notifications.list))
	}
	if h.pageControls("View Plugins") != 1 {
		t.Fatalf("floating toast View Plugins count = %d, want 1", h.pageControls("View Plugins"))
	}
	h.clickNamed("View Plugins")
	h.settle()
	if primaryCalls != 1 {
		t.Fatalf("primaryCalls = %d, want 1", primaryCalls)
	}

	// Open the notification bell history where both primary and secondary actions appear.
	for _, entry := range h.app.notifications.list {
		h.app.overlay.toaster.Close(entry.toast)
	}
	h.app.invalidator.Invalidate()
	h.settle()
	h.clickNamed("Notifications, 1 unread")
	h.settle()
	if n := h.pageControls("View Plugins"); n != 1 {
		t.Fatalf("history View Plugins count = %d, want 1", n)
	}
	if n := h.pageControls("Don't Show Again"); n != 1 {
		t.Fatalf("history Don't Show Again count = %d, want 1", n)
	}
	h.clickNamed("Don't Show Again")
	h.settle()
	if secondaryCalls != 1 || h.app.notifications.open {
		t.Fatalf("secondaryCalls = %d, open = %v; want 1, false", secondaryCalls, h.app.notifications.open)
	}
}
