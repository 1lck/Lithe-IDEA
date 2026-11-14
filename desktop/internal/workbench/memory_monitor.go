package workbench

import (
	"context"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The memory monitor shows what this Lithe instance holds: the main process and every process
// that belongs to it, which Core picks out of the system's process table and sums by part
// (processMemory.summarize). The window only reads the table and names the processes it
// started: the language servers and the plugin services. The status bar item shows the total;
// on macOS it is only a chip icon, as the earlier client had, with the figures in its tooltip.
// A click opens the details, which are read more often while they are shown. Reading runs in
// the background and a failure only leaves the figures out: it never holds up the window.

const (
	// memorySampleInterval is how often the processes are read while the details are shut,
	// and memoryDetailInterval while they are open. A reading only starts from a paint of the
	// status item, so a window that does not paint does not read.
	memorySampleInterval = 10 * time.Second
	memoryDetailInterval = 2 * time.Second
	memorySampleTimeout  = 5 * time.Second

	memoryPanelWidth = 340
	memoryListHeight = 220
	memoryBarHeight  = 6
	memoryBarGap     = 2
	memoryDotSize    = 8
	memoryRowHeight  = 22
	memoryHeaderGap  = 6
	memorySectionGap = 10
)

// processMemoryKernel is the Core command the memory monitor asks.
type processMemoryKernel interface {
	SummarizeProcessMemory(ctx context.Context, request core.MemoryRequest) (core.MemorySummary, error)
}

// memoryState is the last reading.
type memoryState struct {
	open      bool
	sampling  bool
	sampledAt time.Time
	// summary is the last reading Core summed; read is true once one arrived and failed while
	// the last one failed, which hides the figures rather than leaving stale ones.
	summary core.MemorySummary
	read    bool
	failed  bool
	// names are the display names of the installed plugins, read as the details open; nil
	// until then, which names a process by its plugin ID.
	names *memoryNames
}

// memoryNames are the display names the details give the processes started for plugins.
type memoryNames struct {
	// plugins maps a plugin ID to its manifest's name.
	plugins map[string]string
	// languages maps a plugin ID and a language ID to the title the plugin declares.
	languages map[[2]string]string
}

// memoryNamesOf collects the names of the installed plugins and of their language servers.
func memoryNamesOf(facts []settingswindow.PluginFacts) *memoryNames {
	names := &memoryNames{plugins: map[string]string{}, languages: map[[2]string]string{}}
	for _, item := range facts {
		names.plugins[item.ID] = pluginFactsName(item)
		for _, capability := range item.Capabilities {
			if capability.Kind == settingswindow.CapabilityLanguageServer && capability.Title != "" {
				names.languages[[2]string{item.ID, capability.ID}] = capability.Title
			}
		}
	}
	return names
}

// plugin is the name of the plugin with the ID, or the ID when its manifest was not read.
func (n *memoryNames) plugin(id string) string {
	if n != nil && n.plugins[id] != "" {
		return n.plugins[id]
	}
	return id
}

// languageServer names the language server a plugin started for a language: the plugin, then
// the language unless the plugin's name already is the language's.
func (n *memoryNames) languageServer(language i18n.Language, pluginID, languageID string) string {
	name := n.plugin(pluginID)
	if languageID == "" {
		return name
	}
	title := languageID
	if n != nil && n.languages[[2]string{pluginID, languageID}] != "" {
		title = n.languages[[2]string{pluginID, languageID}]
	}
	if strings.EqualFold(title, name) {
		return name
	}
	return i18n.SharedFormat(language, "desktop.memory.languageServer", map[string]string{"plugin": name, "language": title})
}

// toggleMemoryDetails opens or shuts the details. Opening them reads at once and reads the
// plugin names again, so a plugin installed since is named.
func (a *App) toggleMemoryDetails() {
	m := &a.memory
	m.open = !m.open
	m.sampledAt = time.Time{}
	if m.open {
		a.readMemoryNames()
	}
}

// readMemoryNames reads the installed plugins' manifests in the background for the names of
// the processes started for them, then reads the memory again with those names.
func (a *App) readMemoryNames() {
	if a.plugins == nil {
		return
	}
	a.background(nil, pluginStateTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.CurrentInstalled(ctx)
		names := memoryNamesOf(installedPluginFacts(entries, nil))
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("memory_plugin_names", err))
			}
			a.memory.names = names
			a.memory.sampledAt = time.Time{}
		}
	})
}

// sampleMemory starts a background reading when the last one is old enough. The status item
// calls it as it is declared, so a hidden item reads nothing.
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
	roles := a.memoryRoles()
	host := int64(os.Getpid())
	kernel := a.kernel
	a.background(nil, memorySampleTimeout, func(ctx context.Context) func(*App) {
		summary, err := readProcessMemory(ctx, kernel, host, roles)
		return func(a *App) { a.memorySampled(summary, err) }
	})
}

// memorySampled keeps a reading. Only the first failure after a reading is logged, so a
// table that cannot be read is not logged every few seconds.
func (a *App) memorySampled(summary core.MemorySummary, err error) {
	m := &a.memory
	m.sampling = false
	if err != nil {
		if !m.failed {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("memory_sample", err))
		}
		m.failed = true
		return
	}
	m.summary, m.read, m.failed = summary, true, false
}

// readProcessMemory reads the process table and has Core sum what the instance of host holds.
func readProcessMemory(ctx context.Context, kernel processMemoryKernel, host int64, roles []core.MemoryRole) (core.MemorySummary, error) {
	table, err := sysinfo.Processes()
	if err != nil {
		return core.MemorySummary{}, err
	}
	processes := make([]core.MemoryProcess, 0, len(table))
	for _, row := range table {
		process := core.MemoryProcess{
			ProcessID:       int64(row.PID),
			ParentProcessID: int64(row.ParentPID),
			Name:            row.Name,
			Bytes:           row.MemoryBytes,
		}
		// A zero is a fact the system did not give, which the request leaves out.
		if row.ResponsiblePID != 0 {
			responsible := int64(row.ResponsiblePID)
			process.ResponsibleProcessID = &responsible
		}
		if row.StartTime != 0 {
			start := row.StartTime
			process.StartTime = &start
		}
		processes = append(processes, process)
	}
	return kernel.SummarizeProcessMemory(ctx, core.MemoryRequest{HostProcessID: host, Processes: processes, Roles: roles})
}

// memoryRoles names the processes this window started: each language server and each plugin
// service that runs with a process ID.
func (a *App) memoryRoles() []core.MemoryRole {
	language := a.language()
	names := a.memory.names
	var roles []core.MemoryRole
	for _, server := range a.lspServers() {
		if pid := server.session.Session.ProcessID; pid > 0 {
			roles = append(roles, core.MemoryRole{
				ProcessID: int64(pid),
				Kind:      core.MemoryRoleLanguageServer,
				Name:      names.languageServer(language, server.session.PluginID, server.session.LanguageID),
			})
		}
	}
	if a.plugins != nil && a.plugins.Host != nil {
		for _, id := range a.plugins.Host.RunningPlugins() {
			if session := a.plugins.Host.Running(id); session != nil && session.Session.ProcessID > 0 {
				roles = append(roles, core.MemoryRole{
					ProcessID: int64(session.Session.ProcessID),
					Kind:      core.MemoryRolePluginService,
					Name:      names.plugin(id),
				})
			}
		}
	}
	return roles
}

// memorySize writes bytes as the monitor shows them: whole megabytes below a gigabyte, then
// gigabytes with two decimals below ten and one above. Both are binary units, as Activity
// Monitor and Task Manager count; a process that holds less than a megabyte is not shown as 0.
func memorySize(language i18n.Language, bytes uint64) string {
	const megabyte, gigabyte = 1 << 20, 1 << 30
	if bytes > 0 && bytes < megabyte {
		return i18n.Shared(language, "desktop.memory.belowMegabyte")
	}
	if rounded := (bytes + megabyte/2) / megabyte; rounded < 1024 {
		return i18n.SharedFormat(language, "desktop.memory.megabytes", map[string]string{"value": strconv.FormatUint(rounded, 10)})
	}
	gigabytes := float64(bytes) / gigabyte
	decimals := 2
	if gigabytes >= 9.995 {
		decimals = 1
	}
	return i18n.SharedFormat(language, "desktop.memory.gigabytes", map[string]string{"value": strconv.FormatFloat(gigabytes, 'f', decimals, 64)})
}

// category is the reading's sum of one part.
func (m *memoryState) category(kind string) core.MemoryCategory {
	for _, category := range m.summary.Categories {
		if category.Kind == kind {
			return category
		}
	}
	return core.MemoryCategory{Kind: kind}
}

// shown is true when the figures of the last reading can be shown.
func (m *memoryState) shown() bool { return m.read && !m.failed }

// memoryStatusText is the status bar readout: the total and the main process's share, or the
// item's name while there is no reading. macOS shows the icon instead.
func (a *App) memoryStatusText() string {
	m := &a.memory
	if !m.shown() {
		return a.text.Status.Memory
	}
	language := a.language()
	return i18n.SharedFormat(language, "desktop.memory.status", map[string]string{
		"total": memorySize(language, m.summary.TotalBytes), "lithe": memorySize(language, m.category(core.MemoryHost).Bytes),
	})
}

// memoryTooltip is what the status item's tooltip and accessibility value give.
func (a *App) memoryTooltip() string {
	m := &a.memory
	if !m.shown() {
		return a.text.Status.Memory
	}
	language := a.language()
	return i18n.SharedFormat(language, "desktop.memory.tooltip", map[string]string{
		"total": memorySize(language, m.summary.TotalBytes), "lithe": memorySize(language, m.category(core.MemoryHost).Bytes),
	})
}

// memoryShowsIcon is true where the status item is the chip icon alone.
func memoryShowsIcon() bool { return runtime.GOOS == "darwin" }

// memoryStatusItem declares the status item's content, the chip icon on macOS and the readout
// elsewhere, and reads the memory when the last reading is old enough.
func (a *App) memoryStatusItem(c ui.C) {
	a.sampleMemory(a.now())
	if memoryShowsIcon() {
		ui.Icon(c, icons.Cpu).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
		return
	}
	a.chromeStatusLabel(c, a.memoryStatusText())
}

// memoryKindLabel names a part of the instance.
func memoryKindLabel(language i18n.Language, kind string) string {
	switch kind {
	case core.MemoryHost:
		return i18n.Shared(language, "desktop.memory.host")
	case core.MemoryLanguageServer:
		return i18n.Shared(language, "desktop.memory.languageServers")
	case core.MemoryPluginService:
		return i18n.Shared(language, "desktop.memory.services")
	case core.MemorySystemHelper:
		return i18n.Shared(language, "desktop.memory.systemHelpers")
	}
	return i18n.Shared(language, "desktop.memory.childProcesses")
}

// memoryColor is the color that marks a part in the bar, the legend and the list. No part
// is red, which would read as a fault; the system helpers take the purple of IDEA's expUI.
func (a *App) memoryColor(kind string) gfx.Color {
	switch kind {
	case core.MemoryHost:
		return a.colors.Accent
	case core.MemoryLanguageServer:
		return a.colors.Success
	case core.MemoryPluginService:
		return a.colors.Warning
	case core.MemorySystemHelper:
		return pick(a.colors.Dark, 0xB589EC, 0x834DF0)
	}
	return a.colors.Subtle
}

// memoryHelp is the explanation behind the details' ⓘ: what is counted, and which figure the
// system gives for each process.
func memoryHelp(language i18n.Language) string {
	help := i18n.Shared(language, "desktop.memory.help")
	switch runtime.GOOS {
	case "darwin":
		help += "\n\n" + i18n.Shared(language, "desktop.memory.helpMacOS")
	case "windows":
		help += "\n\n" + i18n.Shared(language, "desktop.memory.helpWindows")
	case "linux":
		help += "\n\n" + i18n.Shared(language, "desktop.memory.helpLinux")
	}
	return help
}

// memoryParts are the parts the details show: the main process always, the others while they
// hold something.
func (m *memoryState) parts() []core.MemoryCategory {
	parts := make([]core.MemoryCategory, 0, len(m.summary.Categories))
	for _, category := range m.summary.Categories {
		if category.Kind == core.MemoryHost || category.Bytes > 0 || category.ProcessCount > 0 {
			parts = append(parts, category)
		}
	}
	return parts
}

// memoryDetails is the popover the status item opens: the total, a bar of the parts and their
// sums, then the largest processes of the instance other than the main one.
func (a *App) memoryDetails(c ui.C, anchor ui.Box) {
	m := &a.memory
	if !m.open {
		return
	}
	// The details refresh on their own: the next paint takes the next reading.
	c.Canvas().RequestFrameIn(memoryDetailInterval)
	language := a.language()
	spec := ui.PopoverSpec{Side: components.PopoverTop, Align: ui.End, Offset: chromeMenuOffset, Width: memoryPanelWidth, ConsumeOutsidePress: true}
	ui.PopoverWith(c.Key("memoryDetails"), anchor, spec, &m.open, func() {
		ui.Column(c).FillWidth().Gap(memorySectionGap).Children(func() {
			a.memoryHeader(c, language)
			switch {
			case m.failed:
				ui.Text(c, i18n.Shared(language, "desktop.memory.unavailable")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			case !m.read:
				ui.Text(c, i18n.Shared(language, "desktop.memory.reading")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			default:
				parts := m.parts()
				a.memoryBar(c.Part("bar"), parts)
				a.memoryLegend(c.Part("legend"), language, parts)
				ui.Divider(c)
				a.memoryEntries(c.Part("entries"), language)
			}
		})
	})
}

// memoryHeader declares the details' title, the ⓘ with what is counted, and the total.
func (a *App) memoryHeader(c ui.C, language i18n.Language) {
	m := &a.memory
	ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(memoryHeaderGap).Children(func() {
		ui.Text(c, i18n.Shared(language, "desktop.memory.title")).Weight(gfx.WeightSemibold).Shrink(0)
		ui.Button(c.Part("help"), i18n.Shared(language, "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().Size(18, 18).
			Tooltip(memoryHelp(language))
		ui.Row(c).Grow(1)
		if m.shown() {
			ui.Text(c, memorySize(language, m.summary.TotalBytes)).Weight(gfx.WeightSemibold).Shrink(0)
		}
	})
}

// memoryBar declares the parts side by side, each as wide as its share of the total.
func (a *App) memoryBar(c ui.C, parts []core.MemoryCategory) {
	total := a.memory.summary.TotalBytes
	ui.Row(c).FillWidth().Height(memoryBarHeight).Gap(memoryBarGap).Children(func() {
		for i, part := range parts {
			if part.Bytes == 0 || total == 0 {
				continue
			}
			ui.Row(c.KeyInt(i)).Basis(0).Grow(float32(float64(part.Bytes) / float64(total))).MinWidth(memoryBarHeight).
				Height(memoryBarHeight).Radius(memoryBarHeight / 2).Background(a.memoryColor(part.Kind))
		}
	})
}

// memoryLegend declares one row per part: its color, name, process count and sum.
func (a *App) memoryLegend(c ui.C, language i18n.Language, parts []core.MemoryCategory) {
	ui.Column(c).FillWidth().Children(func() {
		for i, part := range parts {
			a.memoryRow(c.KeyInt(i), language, part.Kind, memoryKindLabel(language, part.Kind), part.ProcessCount, part.Bytes)
		}
	})
}

// memoryEntries declares the largest processes of the instance other than the main one, each
// with what Core counts under it, and the sum of the ones past the list.
func (a *App) memoryEntries(c ui.C, language i18n.Language) {
	summary := &a.memory.summary
	ui.Text(c, i18n.Shared(language, "desktop.memory.processes")).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle)
	if len(summary.Entries) == 0 {
		ui.Text(c, i18n.Shared(language, "desktop.memory.noOtherProcesses")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		return
	}
	ui.Scroll(c.Part("list")).FillWidth().MaxHeight(memoryListHeight).Children(func() {
		for i, entry := range summary.Entries {
			a.memoryRow(c.KeyInt(i), language, entry.Kind, entry.Name, entry.ProcessCount, entry.Bytes)
		}
	})
	if summary.Omitted.Count > 0 {
		ui.Text(c, i18n.SharedFormat(language, "desktop.memory.omitted", map[string]string{
			"count": strconv.Itoa(summary.Omitted.Count), "value": memorySize(language, summary.Omitted.Bytes),
		})).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	}
}

// memoryRow declares a row of the legend or the list: the part's dot, the name, how many
// processes it sums when more than one, and the size at the end.
func (a *App) memoryRow(k ui.C, language i18n.Language, kind, name string, processes int, bytes uint64) {
	small := a.theme.Metrics.FontSizeS
	ui.Row(k).FillWidth().Height(memoryRowHeight).Shrink(0).Items(ui.Center).Gap(8).Children(func() {
		ui.Row(k).Size(memoryDotSize, memoryDotSize).Shrink(0).Radius(memoryDotSize / 2).Background(a.memoryColor(kind))
		ui.Text(k, name).FontSize(small).Shrink(1).MinWidth(0).Ellipsis()
		if processes > 1 {
			ui.Text(k, i18n.SharedFormat(language, "desktop.memory.processCount", map[string]string{"count": strconv.Itoa(processes)})).
				FontSize(small).Color(a.colors.Subtle).Shrink(0)
		}
		ui.Row(k).Grow(1)
		ui.Text(k, memorySize(language, bytes)).FontSize(small).Shrink(0)
	})
}
