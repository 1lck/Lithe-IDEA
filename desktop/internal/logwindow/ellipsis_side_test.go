package logwindow

import (
	"maps"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// longChannel is a plugin's channel whose name is too long for the sidebar.
const longChannel = "plugins/dev.example.synthetic-language-support/language-server/backend"

// addChannel adds channel, with a count of three, to what the model's last query found.
func addChannel(m *Model, channel string) {
	channels := maps.Clone(m.channels)
	if channels == nil {
		channels = map[string]core.LogChannelCount{}
	}
	channels[channel] = core.LogChannelCount{Total: 3}
	m.applyCollection(logstore.Query{}, logstore.Collection{
		Directory: "/tmp/logs", CurrentSessionPath: "sessions/2026-11-08",
		Result: core.LogQueryResult{Records: slices.Clone(m.records), Channels: channels, FoldMinimumRun: 3},
	})
}

// cutSidebarChannel is where the sidebar shows the start of full followed by "…".
func cutSidebarChannel(t testing.TB, driver *app.Driver, full string) gfx.Rect {
	t.Helper()
	for _, label := range driver.Snapshot().Labels {
		head, cut := strings.CutSuffix(label.Value, "…")
		if cut && head != "" && strings.HasPrefix(full, head) && label.Bounds.X < sidebarWidth {
			return label.Bounds
		}
	}
	t.Fatalf("the sidebar does not cut %q short", full)
	return gfx.Rect{}
}

// A channel name the sidebar cuts short shows in full to its right, over the table, rather than
// below it over the next channels of the list.
func TestSidebarChannelEllipsisTooltipOpensToTheRight(t *testing.T) {
	fixture, w, driver := bigFixture(t, 40)
	addChannel(fixture.model, longChannel)
	w.inv.Invalidate()
	settleWindow(t, driver)

	full := "■ " + sidebarTitle(longChannel)
	text := cutSidebarChannel(t, driver, full)
	if err := driver.Move(text.X+text.Width/2, text.Y+text.Height/2); err != nil {
		t.Fatal(err)
	}
	if err := driver.Advance(time.Second); err != nil {
		t.Fatal(err)
	}
	if got := tableTooltipText(driver); got != full {
		t.Fatalf("the tooltip of the channel shows %q, want %q", got, full)
	}
	for _, label := range driver.Snapshot().Labels {
		if label.Layer == ui.TooltipLayer && label.Bounds.X < text.X+text.Width {
			t.Fatalf("the tooltip line at %+v starts left of the end of the channel name at %+v", label.Bounds, text)
		}
	}
}
