package workbench

import (
	"fmt"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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
