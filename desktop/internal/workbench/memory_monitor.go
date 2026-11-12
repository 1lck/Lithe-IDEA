package workbench

import (
	"context"
	"runtime"
	"sort"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The memory monitor reads what Lithe and the processes it started hold: Lithe's own resident
// memory, the language servers and the plugin backends (each with its child processes). The
// status bar item shows the total; on macOS it is only a chip icon, as the earlier client had,
// with the figures in its tooltip. A click opens the details, which are sampled more often
// while they are shown. Sampling runs in the background and a failure only leaves the figures
// out: it never holds up the window.

const (
	// memorySampleInterval is how often the processes are read while the details are shut,
	// and memoryDetailInterval while they are open.
	memorySampleInterval = 10 * time.Second
	memoryDetailInterval = 2 * time.Second
	memorySampleTimeout  = 5 * time.Second
)

// memoryProcess is one process tree Lithe started, as the details list it.
type memoryProcess struct {
	name  string
	kind  memoryKind
	bytes uint64
}

type memoryKind int

const (
	memoryLanguageServer memoryKind = iota
	memoryPluginBackend
)

// memoryState is the last reading.
type memoryState struct {
	open      bool
	sampling  bool
	sampledAt time.Time
	lithe     uint64
	processes []memoryProcess
	// read is true once a reading of the other processes arrived.
	read bool
}

// sums is the language-server and plugin-backend totals of the reading.
func (m *memoryState) sums() (servers, backends uint64) {
	for _, process := range m.processes {
		if process.kind == memoryLanguageServer {
			servers += process.bytes
		} else {
			backends += process.bytes
		}
	}
	return servers, backends
}

// total is Lithe and every process it started.
func (m *memoryState) total() uint64 {
	servers, backends := m.sums()
	return m.lithe + servers + backends
}

// memoryTarget is a process tree to read: the pid Core reported and how to name it.
type memoryTarget struct {
	pid  int
	name string
	kind memoryKind
}

// sampleMemory starts a background reading when the last one is old enough. It is called on
// every paint; the status sampling already limits paints that reach it to about one a second.
func (a *App) sampleMemory(now time.Time) {
	m := &a.memory
	interval := memorySampleInterval
	if m.open {
		interval = memoryDetailInterval
	}
	if m.sampling || (!m.sampledAt.IsZero() && now.Sub(m.sampledAt) < interval) {
		return
	}
	m.sampling, m.sampledAt = true, now
	targets := a.memoryTargets()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), memorySampleTimeout)
		defer cancel()
		lithe := sysinfo.Resident()
		pids := make([]int, 0, len(targets))
		for _, target := range targets {
			pids = append(pids, target.pid)
		}
		read := pluginservice.SampleProcessMemory(ctx, pids)
		processes := make([]memoryProcess, 0, len(targets))
		for _, target := range targets {
			if bytes, ok := read[target.pid]; ok {
				processes = append(processes, memoryProcess{name: target.name, kind: target.kind, bytes: bytes})
			}
		}
		sort.SliceStable(processes, func(i, j int) bool { return processes[i].bytes > processes[j].bytes })
		a.post(func(a *App) {
			m := &a.memory
			m.sampling = false
			m.lithe, m.processes, m.read = lithe, processes, read != nil || len(targets) == 0
		})
	}()
}

// memoryTargets lists the language servers and plugin backends that are running with a pid.
func (a *App) memoryTargets() []memoryTarget {
	var targets []memoryTarget
	for _, server := range a.lspServers() {
		if pid := server.session.Session.ProcessID; pid > 0 {
			name := server.session.PluginID
			if server.session.LanguageID != "" {
				name += " (" + server.session.LanguageID + ")"
			}
			targets = append(targets, memoryTarget{pid: pid, name: name, kind: memoryLanguageServer})
		}
	}
	if a.plugins != nil && a.plugins.Host != nil {
		for _, id := range a.plugins.Host.RunningPlugins() {
			if session := a.plugins.Host.Running(id); session != nil && session.Session.ProcessID > 0 {
				targets = append(targets, memoryTarget{pid: session.Session.ProcessID, name: id, kind: memoryPluginBackend})
			}
		}
	}
	return targets
}

// memoryStatusText is the status bar readout: the total and Lithe's share, or Lithe alone before
// the first reading. macOS shows the icon instead.
func (a *App) memoryStatusText() string {
	m := &a.memory
	lithe := m.lithe
	if lithe == 0 {
		lithe = a.status.memory
	}
	if !m.read {
		return a.text.Status.MemoryValue(int(lithe >> 20))
	}
	return i18n.SharedFormat(a.language(), "desktop.memory.status", map[string]string{
		"total": megabytes(m.total()), "lithe": megabytes(lithe),
	})
}

// memoryTooltip is the breakdown the status item's tooltip and accessibility value give.
func (a *App) memoryTooltip() string {
	m := &a.memory
	servers, backends := m.sums()
	return i18n.SharedFormat(a.language(), "desktop.memory.tooltip", map[string]string{
		"total": megabytes(m.total()), "lithe": megabytes(m.lithe), "lsp": megabytes(servers), "services": megabytes(backends),
	})
}

// memoryShowsIcon is true where the status item is the chip icon alone.
func memoryShowsIcon() bool { return runtime.GOOS == "darwin" }

func megabytes(bytes uint64) string { return strconv.FormatUint(bytes>>20, 10) }

// memoryStatusItem declares the status item's content: the chip icon on macOS, the readout elsewhere.
func (a *App) memoryStatusItem(c ui.C) {
	if memoryShowsIcon() {
		ui.Icon(c, icons.Cpu).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
		return
	}
	a.chromeStatusLabel(c, a.memoryStatusText())
}

// memoryDetails is the popover the status item opens: the totals and every process Lithe started.
func (a *App) memoryDetails(c ui.C, anchor ui.Box) {
	m := &a.memory
	if !m.open {
		return
	}
	// The details refresh on their own: the next paint takes the next reading.
	c.Canvas().RequestFrameIn(memoryDetailInterval)
	language := a.language()
	ui.Popover(c.Key("memoryDetails"), anchor, &m.open, func() {
		ui.Column(c).Gap(6).MinWidth(300).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.memory.title")).FontSize(13).Weight(gfx.WeightSemibold)
			servers, backends := m.sums()
			row := func(label string, bytes uint64, strong bool) {
				ui.Row(c).FillWidth().Items(ui.Center).Gap(12).Children(func() {
					text := ui.Text(c, label).Grow(1).Shrink(1).MinWidth(0).FontSize(12).Ellipsis()
					value := ui.Text(c, i18n.SharedFormat(language, "desktop.memory.value", map[string]string{"value": megabytes(bytes)})).FontSize(12).Shrink(0)
					if strong {
						text.Weight(gfx.WeightSemibold)
						value.Weight(gfx.WeightSemibold)
					} else {
						text.Color(a.colors.Subtle)
					}
				})
			}
			row(i18n.Shared(language, "desktop.memory.total"), m.total(), true)
			row(i18n.Shared(language, "desktop.memory.lithe"), m.lithe, false)
			row(i18n.Shared(language, "desktop.memory.languageServers"), servers, false)
			row(i18n.Shared(language, "desktop.memory.services"), backends, false)
			if len(m.processes) == 0 {
				ui.Text(c, i18n.Shared(language, "desktop.memory.noProcesses")).FontSize(12).Color(a.colors.Subtle)
				return
			}
			ui.Row(c).FillWidth().Height(1).Background(a.colors.Line)
			for _, process := range m.processes {
				kind := i18n.Shared(language, "desktop.memory.kindServer")
				if process.kind == memoryPluginBackend {
					kind = i18n.Shared(language, "desktop.memory.kindService")
				}
				row(process.name+" · "+kind, process.bytes, false)
			}
		})
	})
}
