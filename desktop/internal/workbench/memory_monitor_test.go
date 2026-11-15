package workbench

import (
	"context"
	"errors"
	"os"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// memoryKernel answers processMemory.summarize with the summary or the error the test chose and
// keeps the requests the window sent.
type memoryKernel struct {
	*core.Client
	mu       sync.Mutex
	requests []core.MemoryRequest
	summary  core.MemorySummary
	err      error
}

func (k *memoryKernel) SummarizeProcessMemory(_ context.Context, request core.MemoryRequest) (core.MemorySummary, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.requests = append(k.requests, request)
	return k.summary, k.err
}

// answer sets what the next requests are answered.
func (k *memoryKernel) answer(summary core.MemorySummary, err error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.summary, k.err = summary, err
}

// last is the last request the window sent, and how many it sent.
func (k *memoryKernel) last() (core.MemoryRequest, int) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if len(k.requests) == 0 {
		return core.MemoryRequest{}, 0
	}
	return k.requests[len(k.requests)-1], len(k.requests)
}

const mib = 1 << 20

func pointerTo[T any](value T) *T { return &value }

// memoryUsage is a figure set of the fixture: what is compressed or swapped out, in mebibytes,
// and the processor and graphics use.
func memoryUsage(compressed uint64, cpu, gpu float64) core.MemoryUsage {
	return core.MemoryUsage{CompressedBytes: pointerTo(compressed * mib), CPUPercent: pointerTo(cpu), GPUPercent: pointerTo(gpu)}
}

// memorySummaryFixture is an instance with a main process, two language-server processes,
// three system helpers and no plugin service, of which the list shows three entries and sums
// two more. Every part and entry has its compressed memory and its processor and graphics use,
// and the main process holds graphics memory.
func memorySummaryFixture() core.MemorySummary {
	total := memoryUsage(640, 12.5, 3)
	total.GPUMemoryBytes = pointerTo(uint64(96 * mib))
	host := memoryUsage(120, 8, 3)
	host.GPUMemoryBytes = total.GPUMemoryBytes
	return core.MemorySummary{
		TotalBytes:  1536 * mib,
		MemoryUsage: total,
		Categories: []core.MemoryCategory{
			{Kind: core.MemoryHost, Bytes: 302 * mib, ProcessCount: 1, MemoryUsage: host},
			{Kind: core.MemoryLanguageServer, Bytes: 1012 * mib, ProcessCount: 2, MemoryUsage: memoryUsage(500, 4, 0)},
			{Kind: core.MemoryPluginService, MemoryUsage: memoryUsage(0, 0, 0)},
			{Kind: core.MemorySystemHelper, Bytes: 210 * mib, ProcessCount: 3, MemoryUsage: memoryUsage(24, 0.5, 0)},
			{Kind: core.MemoryChildProcess, Bytes: 12 * mib, ProcessCount: 2, MemoryUsage: memoryUsage(0, 0, 0)},
		},
		Entries: []core.MemoryEntry{
			{Kind: core.MemoryLanguageServer, Name: "Quill Tools · Quill", ProcessID: 41, Bytes: 1012 * mib, ProcessCount: 2, MemoryUsage: memoryUsage(500, 4, 0)},
			{Kind: core.MemorySystemHelper, Name: "PageRenderer", ProcessID: 52, Bytes: 180 * mib, ProcessCount: 1, MemoryUsage: memoryUsage(15, 0.4, 0)},
			{Kind: core.MemorySystemHelper, Name: "PageNetwork", ProcessID: 53, Bytes: 30 * mib, ProcessCount: 2, MemoryUsage: memoryUsage(5, 0.1, 0)},
		},
		Omitted: core.MemoryOmitted{Count: 2, Bytes: 12 * mib},
		Baseline: &core.MemoryBaseline{SampledAt: 2_000_000, Processes: []core.BaselineProcess{
			{ProcessID: int64(os.Getpid()), StartTime: pointerTo(uint64(1_000)), CPUTime: pointerTo(uint64(250_000)),
				GPUEngines: []core.GPUEngineTime{{Engine: "accelerator-1", BusyTime: 30_000}}},
			{ProcessID: 41, StartTime: pointerTo(uint64(1_500)), CPUTime: pointerTo(uint64(90_000))},
		}},
	}
}

// openMemoryDetails clicks the status item and waits until the details show want.
func openMemoryDetails(h *harness, want string) {
	h.t.Helper()
	item := center(h.button(itemMemory))
	if err := h.driver.Click(item.X, item.Y); err != nil {
		h.t.Fatal(err)
	}
	h.await("the memory details", func() bool { return h.app.memory.open && h.shows(want) })
}

// TestMemoryDetailsShowTheSummaryOfTheWholeInstance checks that the window sends Core the
// process table with itself as the host, timed and with the host's processor time, and sends
// back the baseline of the reading before; and that the details show Core's sums: the total
// with the instance's other figures, every part that holds something with its process count,
// the largest entries and the rest summed, each with its use and compressed memory.
func TestMemoryDetailsShowTheSummaryOfTheWholeInstance(t *testing.T) {
	fixture := memorySummaryFixture()
	kernel := &memoryKernel{Client: core.NewClient(), summary: fixture}
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	h.await("the first reading", func() bool { return h.app.memory.read })

	request, sent := kernel.last()
	if sent == 0 {
		t.Fatal("the status item did not read the memory")
	}
	if request.HostProcessID != int64(os.Getpid()) {
		t.Fatalf("host = %d, want this process %d", request.HostProcessID, os.Getpid())
	}
	if request.SampledAt == nil {
		t.Fatal("the request does not say when the table was read")
	}
	if sent == 1 && request.Previous != nil {
		t.Fatalf("the first request sends a baseline %+v though there was no reading before", request.Previous)
	}
	host := false
	for _, process := range request.Processes {
		if process.ProcessID == request.HostProcessID {
			host = process.Bytes > 0 && process.Name != "" && process.CPUTime != nil
		}
	}
	if !host {
		t.Fatalf("the table of %d processes has no named row with memory and processor time for the host", len(request.Processes))
	}
	if got, want := h.app.memoryTooltip(), "内存：共 1.50 GB，其中 Lithe 主进程 302 MB。"; got != want {
		t.Fatalf("tooltip = %q, want %q", got, want)
	}

	openMemoryDetails(h, "Quill Tools · Quill")
	for _, want := range []string{
		"1.50 GB", "压缩/换出 640 MB · 显存 96 MB · CPU 12.5% · GPU 3.0%",
		"内存中", "压缩/换出", "CPU", "GPU",
		"Lithe 主进程", "302 MB", "8.0%", "120 MB", "语言服务器", "1012 MB", "4.0%", "500 MB",
		"系统辅助进程", "3 个进程", "210 MB", "0.5%", "24 MB",
		"其他子进程", "PageRenderer", "180 MB", "0.4%", "15 MB", "PageNetwork", "0.1%", "另有 2 项，共 12 MB",
	} {
		if !h.shows(want) {
			t.Errorf("the details do not show %q", want)
		}
	}
	if h.shows("插件服务") {
		t.Error("the details show the plugin services, which hold nothing")
	}
	// The popover can display the previous summary while the fresh sample runs.
	h.await("the memory reading requested by the details", func() bool {
		_, after := kernel.last()
		return after > sent
	})
	request, _ = kernel.last()
	if !reflect.DeepEqual(request.Previous, fixture.Baseline) {
		t.Fatalf("the request after a reading sends baseline %+v, want the one Core returned %+v", request.Previous, fixture.Baseline)
	}
}

// TestMemoryPercentWritesATenth checks that a use is written with its tenth and that a use the
// reading does not have is left blank.
func TestMemoryPercentWritesATenth(t *testing.T) {
	for _, test := range []struct {
		value *float64
		want  string
	}{
		{nil, ""},
		{pointerTo(0.0), "0.0%"},
		{pointerTo(12.345), "12.3%"},
		{pointerTo(100.0), "100.0%"},
	} {
		if got := memoryPercent(i18n.English, test.value); got != test.want {
			t.Errorf("memoryPercent(%v) = %q, want %q", test.value, got, test.want)
		}
	}
}

// TestMemoryDetailsHideTheFiguresWhileTheReadingFails checks that a failed reading hides the
// figures instead of keeping stale ones, and that the next reading shows them again, with only
// the columns it has figures for.
func TestMemoryDetailsHideTheFiguresWhileTheReadingFails(t *testing.T) {
	kernel := &memoryKernel{Client: core.NewClient(), err: errors.New("the table could not be read")}
	h := newHarness(t, kernel)
	h.open(t.TempDir())

	openMemoryDetails(h, "无法读取进程内存。")
	if h.shows("1.50 GB") || h.app.memoryStatusText() != h.app.text.Status.Memory {
		t.Fatalf("a failed reading shows figures: status %q", h.app.memoryStatusText())
	}

	kernel.answer(core.MemorySummary{
		TotalBytes: 302 * mib,
		Categories: []core.MemoryCategory{{Kind: core.MemoryHost, Bytes: 302 * mib, ProcessCount: 1}},
	}, nil)
	// The next paint reads again without waiting for the interval.
	h.app.post(func(a *App) { a.memory.sampledAt = time.Time{} })
	h.await("a reading after the failure", func() bool { return h.shows("Lithe 目前没有启动其他进程。") })
	if h.shows("无法读取进程内存。") || !h.shows("302 MB") || !h.shows("内存中") {
		t.Fatal("the details do not show the reading that followed the failure")
	}
	if h.shows("压缩/换出") || h.shows("%") {
		t.Fatal("the details show a column the reading has no figures for")
	}
}

// TestMemorySizeWritesWholeMegabytesThenGigabytes checks the units: a process that holds a little
// is not 0 MB, megabytes round, and a gigabyte or more has two decimals below ten.
func TestMemorySizeWritesWholeMegabytesThenGigabytes(t *testing.T) {
	for _, test := range []struct {
		bytes uint64
		want  string
	}{
		{0, "0 MB"},
		{1, "< 1 MB"},
		{mib - 1, "< 1 MB"},
		{mib, "1 MB"},
		{302*mib + mib/2, "303 MB"},
		{1023 * mib, "1023 MB"},
		{1024*mib - mib/2, "1.00 GB"},
		{1536 * mib, "1.50 GB"},
		{10189 * mib, "9.95 GB"},
		{10240 * mib, "10.0 GB"},
		{30 * 1024 * mib, "30.0 GB"},
	} {
		if got := memorySize(i18n.English, test.bytes); got != test.want {
			t.Errorf("memorySize(%d) = %q, want %q", test.bytes, got, test.want)
		}
	}
}

// TestMemoryNamesNameTheProcessesStartedForPlugins checks that a language server is named by its
// plugin and its language, once when they are the same, and by the IDs before the manifests are read.
func TestMemoryNamesNameTheProcessesStartedForPlugins(t *testing.T) {
	names := memoryNamesOf([]settingswindow.PluginFacts{
		{ID: "io.example.quill", Name: "Quill Tools", Capabilities: []settingswindow.PluginCapability{
			{Kind: settingswindow.CapabilityLanguageServer, ID: "quill", Title: "Quill"},
			{Kind: settingswindow.CapabilityBuildSystem, ID: "quill-build", Title: "Quill Build"},
		}},
		{ID: "io.example.ink", Name: "Ink", Capabilities: []settingswindow.PluginCapability{
			{Kind: settingswindow.CapabilityLanguageServer, ID: "ink", Title: "Ink"},
		}},
		{ID: "io.example.unread"},
	})
	for _, test := range []struct {
		names              *memoryNames
		plugin, language   string
		wantServer, wantID string
	}{
		{names, "io.example.quill", "quill", "Quill Tools · Quill", "Quill Tools"},
		{names, "io.example.ink", "ink", "Ink", "Ink"},
		{names, "io.example.quill", "", "Quill Tools", "Quill Tools"},
		{names, "io.example.unread", "paper", "io.example.unread · paper", "io.example.unread"},
		{nil, "io.example.quill", "quill", "io.example.quill · quill", "io.example.quill"},
	} {
		if got := test.names.languageServer(i18n.English, test.plugin, test.language); got != test.wantServer {
			t.Errorf("languageServer(%s, %s) = %q, want %q", test.plugin, test.language, got, test.wantServer)
		}
		if got := test.names.plugin(test.plugin); got != test.wantID {
			t.Errorf("plugin(%s) = %q, want %q", test.plugin, got, test.wantID)
		}
	}
}
