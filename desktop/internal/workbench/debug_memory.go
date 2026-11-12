package workbench

import (
	"context"
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

const (
	// debugMemoryBytes is one readMemory window. The address is opaque text, so
	// the host never asks for more than one page and never computes an address.
	debugMemoryBytes = 256
	// debugMemoryColumns is how many bytes one hex row shows.
	debugMemoryColumns = 16
)

// debugMemory is the read-only memory window of the selected frame. Core owns
// the readMemory request and capability checks; the host decodes the base64
// bytes and lays them out.
type debugMemory struct {
	bytes   []byte
	address string
	// at is the address the user asked to read, from the disassembly's menu; empty reads at the
	// selected frame's instruction pointer. Like every reference of the adapter it is opaque
	// text and holds only until the debuggee runs again.
	at         string
	unreadable int64
	loading    bool
	requested  bool
	failure    string
	// lines is the formatted hex dump; version rises with every load.
	lines   []string
	version uint64
	shown   uint64
	list    ui.ListState
}

func (m *debugMemory) reset() { *m = debugMemory{} }

// canReadDebugMemory reports whether the paused frame has an address the adapter
// can read. It mirrors Core's checks so the section never asks for a refusal.
func canReadDebugMemory(d *debugState) bool {
	return d.activeSession() != nil && d.state == "paused" && d.capabilities != nil && d.capabilities.SupportsReadMemoryRequest &&
		debugMemoryReference(d) != ""
}

// debugMemoryReference is the address the memory window reads: the one asked for, or else
// the selected frame's instruction pointer.
func debugMemoryReference(d *debugState) string {
	if d.memory.at != "" {
		return d.memory.at
	}
	if d.vars.frame >= 0 && d.vars.frame < len(d.frames) {
		return d.frames[d.vars.frame].InstructionPointerReference
	}
	return ""
}

// readDebugMemoryAt shows the memory window read at address, as the disassembly's Read Memory
// at Address does.
func (a *App) readDebugMemoryAt(p *project, address string) {
	d := &p.debug
	if d.memory.loading {
		return
	}
	d.memory.reset()
	d.memory.at = address
	d.section = debugSectionMemory
	a.loadDebugMemory(p)
}

// loadDebugMemory reads one bounded window at the selected frame's instruction
// pointer. Core rejects a request the adapter cannot serve; the failure stays in
// the section.
func (a *App) loadDebugMemory(p *project) {
	d := &p.debug
	if d.memory.loading {
		return
	}
	if !canReadDebugMemory(d) {
		// The frame changed between the paint that asked and this call; let the
		// next paint ask again instead of leaving the section waiting forever.
		d.memory.requested = false
		return
	}
	reference := debugMemoryReference(d)
	d.memory.loading, d.memory.requested, d.memory.failure = true, false, ""
	offset, count := int64(0), int64(debugMemoryBytes)
	a.debugOperation(p, "readMemory", func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error) {
		return a.kernel.InspectDebug(ctx, core.DebugInspectRequest{
			SessionID: session.id, OperationID: operationID, Kind: "readMemory",
			MemoryReference: reference, Offset: &offset, Count: &count,
		})
	}, debugOperationHandlers{done: func(a *App, result core.DebugOperationResult) {
		m := &p.debug.memory
		m.loading = false
		if result.Kind != "readMemory" {
			m.failure = a.text.Debug.NoMemory
			return
		}
		data, err := base64.StdEncoding.DecodeString(result.DataBase64)
		if err != nil {
			m.failure = err.Error()
			return
		}
		m.bytes, m.unreadable, m.failure = data, result.UnreadableBytes, ""
		m.address = result.Address
		if m.address == "" {
			m.address = reference
		}
		m.version++
	}, failed: func(a *App, message string, _ bool) {
		m := &p.debug.memory
		m.loading, m.failure = false, message
	}})
}

// debugMemoryLines lays out a byte window as offset, hex and printable ASCII.
// Empty data yields no rows.
func debugMemoryLines(data []byte) []string {
	if len(data) == 0 {
		return nil
	}
	lines := make([]string, 0, (len(data)+debugMemoryColumns-1)/debugMemoryColumns)
	for start := 0; start < len(data); start += debugMemoryColumns {
		end := start + debugMemoryColumns
		if end > len(data) {
			end = len(data)
		}
		var hex, text strings.Builder
		for index := start; index < end; index++ {
			fmt.Fprintf(&hex, "%02x ", data[index])
			if data[index] >= 0x20 && data[index] < 0x7f {
				text.WriteByte(data[index])
			} else {
				text.WriteByte('.')
			}
		}
		for index := end - start; index < debugMemoryColumns; index++ {
			hex.WriteString("   ")
		}
		lines = append(lines, fmt.Sprintf("%04x  %s %s", start, hex.String(), text.String()))
	}
	return lines
}

// debugMemoryView declares the read-only memory window of the selected frame.
func (a *App) debugMemoryView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	m := &d.memory
	if !canReadDebugMemory(d) {
		a.panelMessage(c, t.NoMemory, a.colors.Subtle)
		return
	}
	if len(m.bytes) == 0 && !m.loading && !m.requested && m.failure == "" {
		// Ask on this paint: the answer is a background operation, and a deferred
		// callback can be dropped when the next update repaints the section first.
		m.requested = true
		a.loadDebugMemory(p)
	}
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		address := m.address
		if address == "" {
			address = debugMemoryReference(d)
		}
		ui.Text(c, address).Shrink(0).FontSize(12).Color(a.colors.Subtle).Mono()
		if ui.Button(c, t.Reload).Outline().Disabled(m.loading).Clicked() {
			c.After(func() { a.loadDebugMemory(p) })
		}
		if m.unreadable > 0 {
			ui.Text(c, t.MemoryUnreadableBytes(int(m.unreadable))).Shrink(0).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning)
		}
		ui.Spacer(c)
		switch {
		case m.failure != "":
			ui.Text(c, m.failure).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger).Ellipsis()
		case m.loading:
			ui.Text(c, t.LoadingVariables).Shrink(1).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		}
	})
	if m.shown != m.version {
		m.lines = debugMemoryLines(m.bytes)
		m.shown = m.version
	}
	lines := m.lines
	if len(lines) == 0 {
		// The request is in flight or failed; the header already reports both, so
		// an empty window is not the "adapter cannot read memory" case.
		return
	}
	m.list.Label = func(i int) string { return lines[i] }
	ui.List(c, &m.list, len(lines), func(row ui.ListRow) {
		row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center)
		ui.Text(row.C, lines[row.Index]).FontSize(12.5).Color(a.colors.Text).Mono().Ellipsis()
	}).Label(t.Memory).FillWidth().Grow(1)
}
