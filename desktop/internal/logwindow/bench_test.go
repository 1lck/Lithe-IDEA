package logwindow

import (
	"strconv"
	"sync/atomic"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/logstore"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// fillRecords loads n synthetic records into the model the way a finished query does, so
// the window paints a full table without reading a log directory.
func fillRecords(m *Model, n int) {
	records := make([]core.LogRecord, n)
	channels := map[string]core.LogChannelCount{}
	levels := []core.LogLevel{core.LevelInfo, core.LevelInfo, core.LevelWarn, core.LevelError, core.LevelDebug}
	for i := range records {
		channel := []string{"app", "lsp/java", "vcs/git", "plugins/db/host"}[i%4]
		records[i] = core.LogRecord{
			Line: "{}", Channel: channel, RelativePath: "sessions/2026-11-08/" + channel + ".jsonl", LineNumber: i + 1,
			FoldKey: "k" + strconv.Itoa(i/7), EpochMs: 1_700_000_000_000 + int64(i)*25, Ts: strconv.Itoa(i),
			Level: levels[i%len(levels)], Seq: uint64(i), Event: "app.bench.event", Op: "op" + strconv.Itoa(i/40),
			Msg:    "record " + strconv.Itoa(i) + " 工作区打开失败 with a message long enough to need clipping in the narrowest column",
			Fields: map[string]string{"path": "/Users/alice/work/" + strconv.Itoa(i), "count": strconv.Itoa(i), "ok": "true"},
		}
		count := channels[channel]
		count.Total++
		channels[channel] = count
	}
	m.applyCollection(logstore.Query{}, logstore.Collection{
		Directory: "/tmp/logs", CurrentSessionPath: "sessions/2026-11-08",
		Result: core.LogQueryResult{Records: records, Channels: channels, FoldMinimumRun: 3},
	})
	m.started = true
}

// openTestWindow opens a headless window over model, in English and the light palette.
func openTestWindow(tb testing.TB, model *Model) (*window, *app.Driver) {
	tb.Helper()
	var current atomic.Pointer[i18n.Messages]
	current.Store(i18n.For(i18n.English))
	controller := NewController(WindowOptions{Text: current.Load})
	w := newWindow(controller, model)
	controller.current = w
	driver, err := app.NewDriver(w.config(), nil)
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(driver.Close)
	return w, driver
}

func BenchmarkTableScroll(b *testing.B) {
	fixture := newExportFixture(b)
	fillRecords(fixture.model, maxRecords)
	_, driver := openTestWindow(b, fixture.model)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		delta := float32(66)
		if i%2 == 1 {
			delta = -66
		}
		if err := driver.Scroll(gfx.ScrollEvent{X: 600, Y: 350, DeltaY: delta, Viewport: gfx.Size{Width: 1100, Height: 720}}); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkTableKeyDown(b *testing.B) {
	fixture := newExportFixture(b)
	fillRecords(fixture.model, maxRecords)
	_, driver := openTestWindow(b, fixture.model)
	if err := driver.Click(600, 300); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := driver.Key(gfx.KeyDown, 0); err != nil {
			b.Fatal(err)
		}
	}
}
