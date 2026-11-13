package workbench

import (
	"context"
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

const (
	// debugMemoryBytes is one readMemory window. The host never asks for more than one window.
	debugMemoryBytes = 1024
	// debugMemoryAlign is the multiple a window starts on when the address read at is a number,
	// so the rows of every bytes-per-row choice start on a multiple of their width.
	debugMemoryAlign = 64
	// debugMemoryDefaultColumns is how many bytes one row shows until the user chooses.
	debugMemoryDefaultColumns = 16
	// debugMemoryAddressWidth is the width of the address field and debugMemoryPickerWidth
	// that of each layout picker.
	debugMemoryAddressWidth = 200
	debugMemoryPickerWidth  = 130
	// debugMemoryMarkAlpha is how strongly the byte read at is tinted with the accent color.
	debugMemoryMarkAlpha = 0.35
)

// debugMemoryColumnChoices are the bytes-per-row choices and debugMemoryRadixChoices the
// bases a byte can be written in, as the memory views of IntelliJ IDEA and CLion offer them.
var (
	debugMemoryColumnChoices = []int{8, 16, 32, 64}
	debugMemoryRadixChoices  = []int{16, 10, 8, 2}
)

// debugMemory is the read-only memory window of the selected frame. Core owns
// the readMemory request and capability checks; the host decodes the base64
// bytes and lays them out.
type debugMemory struct {
	bytes   []byte
	address string
	// at is the address the user asked to read, typed in the field or from the disassembly's
	// menu; empty reads at the selected frame's instruction pointer. Like every reference of
	// the adapter it holds only until the debuggee runs again.
	at string
	// input is the address field's text: the address read at once a window arrives, then
	// whatever the user types until Enter reads there.
	input string
	// mark is the index in bytes of the byte at the address read, highlighted; -1 for none.
	mark       int
	unreadable int64
	loading    bool
	requested  bool
	failure    string
	// columns is how many bytes one row shows and radix the base each byte is written in;
	// zero is the default. Both outlive the window, which every stop resets.
	columns, radix int
	// lines is the laid-out window; version rises with every load and with every layout
	// choice.
	lines   []debugMemoryLine
	version uint64
	shown   uint64
	list    ui.ListState
}

func (m *debugMemory) reset() { *m = debugMemory{columns: m.columns, radix: m.radix} }

// layout is the bytes per row and the base the window is laid out in.
func (m *debugMemory) layout() (columns, radix int) {
	columns, radix = m.columns, m.radix
	if columns == 0 {
		columns = debugMemoryDefaultColumns
	}
	if radix == 0 {
		radix = 16
	}
	return columns, radix
}

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
// at Address and the window's address field do. An empty address reads at the selected frame's
// instruction pointer.
func (a *App) readDebugMemoryAt(p *project, address string) {
	d := &p.debug
	if d.memory.loading {
		return
	}
	d.memory.reset()
	d.memory.at = strings.TrimSpace(address)
	if value, ok := parseDebugAddress(d.memory.at); ok {
		// A number is sent as the protocol writes addresses, so a decimal one reads as typed.
		d.memory.at = fmt.Sprintf("0x%x", value)
	}
	d.section = debugSectionMemory
	a.loadDebugMemory(p)
}

// loadDebugMemory reads one bounded window at the address asked for. When that address is a
// number the window starts a little before it, on a multiple of debugMemoryAlign, so the
// address sits in its row as it would in a full dump; an opaque reference is read from where
// it points. Core rejects a request the adapter cannot serve; the failure stays in the section.
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
	target, numeric := parseDebugAddress(reference)
	lead := int64(0)
	if numeric {
		lead = int64(target % debugMemoryAlign)
	}
	d.memory.loading, d.memory.requested, d.memory.failure = true, false, ""
	offset, count := -lead, int64(debugMemoryBytes)
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
		// The adapter says where the bytes start; without a number for it, the bytes start
		// where they were asked from.
		m.mark = int(lead)
		if base, ok := parseDebugAddress(result.Address); ok && numeric {
			m.mark = -1
			if target >= base && target-base < uint64(len(data)) {
				m.mark = int(target - base)
			}
		}
		if m.mark >= len(data) {
			m.mark = -1
		}
		if m.input == "" {
			m.input = reference
		}
		m.version++
		if m.mark >= 0 {
			columns, _ := m.layout()
			m.list.ScrollTo(m.mark/columns, ui.ListCenter)
		}
	}, failed: func(a *App, message string, _ bool) {
		m := &p.debug.memory
		m.loading, m.failure = false, message
	}})
}

// parseDebugAddress reads an address as the Debug Adapter Protocol writes one: hexadecimal
// after 0x, decimal otherwise. Anything else is an opaque reference and reports false.
func parseDebugAddress(text string) (uint64, bool) {
	text = strings.TrimSpace(text)
	base := 10
	if len(text) > 2 && (text[:2] == "0x" || text[:2] == "0X") {
		text, base = text[2:], 16
	}
	value, err := strconv.ParseUint(text, base, 64)
	return value, err == nil
}

// debugMemoryLine is one row of the memory window: its text, and the byte ranges of the
// marked byte's cell and character in it, both empty when the row does not hold that byte.
type debugMemoryLine struct {
	text       string
	cell, char [2]int
}

// debugMemoryLines lays out a byte window as rows of columns bytes: the address of the row,
// each byte written in radix, and the bytes as printable ASCII. Rows are labelled with the
// address from base on when absolute, else with their offset in the window. mark is the
// index of the byte to highlight, -1 for none. Empty data yields no rows.
func debugMemoryLines(data []byte, base uint64, absolute bool, columns, radix, mark int) []debugMemoryLine {
	if len(data) == 0 || columns <= 0 {
		return nil
	}
	format, width := debugMemoryCellFormat(radix)
	label := "%04x"
	if absolute {
		digits := max(8, len(strconv.FormatUint(base+uint64(len(data)), 16)))
		label = "0x%0" + strconv.Itoa(digits) + "x"
	}
	lines := make([]debugMemoryLine, 0, (len(data)+columns-1)/columns)
	var row strings.Builder
	for start := 0; start < len(data); start += columns {
		end := min(start+columns, len(data))
		row.Reset()
		line := debugMemoryLine{}
		address := uint64(start)
		if absolute {
			address += base
		}
		fmt.Fprintf(&row, label+"  ", address)
		for index := start; index < start+columns; index++ {
			if index >= end {
				row.WriteString(strings.Repeat(" ", width+1))
				continue
			}
			if index == mark {
				line.cell = [2]int{row.Len(), row.Len() + width}
			}
			fmt.Fprintf(&row, format+" ", data[index])
		}
		row.WriteByte(' ')
		for index := start; index < end; index++ {
			if index == mark {
				line.char = [2]int{row.Len(), row.Len() + 1}
			}
			if data[index] >= 0x20 && data[index] < 0x7f {
				row.WriteByte(data[index])
			} else {
				row.WriteByte('.')
			}
		}
		line.text = row.String()
		lines = append(lines, line)
	}
	return lines
}

// debugMemoryCellFormat is the format of one byte in radix and the width it takes.
func debugMemoryCellFormat(radix int) (format string, width int) {
	switch radix {
	case 2:
		return "%08b", 8
	case 8:
		return "%03o", 3
	case 10:
		return "%3d", 3
	}
	return "%02x", 2
}

// debugMemoryView declares the read-only memory window of the selected frame: an address field
// to read anywhere, the way back to the current instruction, the bytes-per-row and base
// pickers, then the rows with the byte at the address read highlighted.
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
	a.debugMemoryToolbar(c, p)
	columns, radix := m.layout()
	if m.shown != m.version {
		base, absolute := parseDebugAddress(m.address)
		m.lines = debugMemoryLines(m.bytes, base, absolute, columns, radix, m.mark)
		m.shown = m.version
	}
	lines := m.lines
	if len(lines) == 0 {
		// The request is in flight or failed; the header already reports both, so
		// an empty window is not the "adapter cannot read memory" case.
		return
	}
	marked := a.colors.Accent
	marked.Alpha *= debugMemoryMarkAlpha
	m.list.Label = func(i int) string { return lines[i].text }
	ui.List(c, &m.list, len(lines), func(row ui.ListRow) {
		row.Element.Height(debugRowHeight).PadX(10).Items(ui.Center)
		line := lines[row.Index]
		if line.cell[1] == 0 {
			ui.Text(row.C, line.text).FontSize(12.5).Color(a.colors.Text).Mono().Ellipsis()
			return
		}
		// The row of the byte read at is written in pieces so that byte's cell and character
		// can be highlighted; monospace keeps the pieces in their columns.
		segment := func(text string, mark bool) {
			piece := ui.Text(row.C, text).Shrink(0).FontSize(12.5).Color(a.colors.Text).Mono()
			if mark {
				piece.Background(marked).Radius(2)
			}
		}
		segment(line.text[:line.cell[0]], false)
		segment(line.text[line.cell[0]:line.cell[1]], true)
		segment(line.text[line.cell[1]:line.char[0]], false)
		segment(line.text[line.char[0]:line.char[1]], true)
		ui.Text(row.C, line.text[line.char[1]:]).Shrink(1).FontSize(12.5).Color(a.colors.Text).Mono().Ellipsis()
	}).Label(t.Memory).FillWidth().Grow(1)
}

// debugMemoryToolbar declares the memory window's controls. Enter in the address field or the
// search button reads at the typed address; the locate button reads at the selected frame's
// instruction pointer again. The pickers lay the same bytes out again without reading.
func (a *App) debugMemoryToolbar(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	m := &d.memory
	lang := a.language()
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(8).Children(func() {
		placeholder := i18n.Shared(lang, "desktop.debug.memoryAddressPlaceholder")
		field := ui.TextField(c.Key("memoryAddress"), &m.input, i18n.Shared(lang, "desktop.debug.memoryAddress"), placeholder).
			Width(debugMemoryAddressWidth).Shrink(1).Mono()
		goTo := field.Submitted()
		if _, clicked := a.toolIconButton(c.Part("memoryGo"), i18n.Shared(lang, "desktop.debug.memoryGoToAddress"), icons.Search, false, m.loading || strings.TrimSpace(m.input) == ""); clicked {
			goTo = true
		}
		if goTo && strings.TrimSpace(m.input) != "" {
			address := m.input
			c.After(func() {
				a.performed("debug.memory.goToAddress", surfaceButton)
				a.readDebugMemoryAt(p, address)
				p.debug.memory.input = p.debug.memory.at
			})
		}
		if _, clicked := a.toolIconButton(c.Part("memoryCurrent"), t.Reload, icons.Locate, false, m.loading); clicked {
			c.After(func() {
				a.performed("debug.memory.currentInstruction", surfaceButton)
				a.readDebugMemoryAt(p, "")
			})
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
		columns, radix := m.layout()
		if ui.Select(c.Key("memoryColumns"), &columns, debugMemoryColumnChoices, func(count int) string {
			return i18n.SharedFormat(lang, "desktop.debug.memoryRowBytes", map[string]string{"bytes": strconv.Itoa(count)})
		}).Label(i18n.Shared(lang, "desktop.debug.memoryBytesPerRow")).Width(debugMemoryPickerWidth).Height(24).Shrink(1); columns != m.columns && (m.columns != 0 || columns != debugMemoryDefaultColumns) {
			value := columns
			c.After(func() { a.setDebugMemoryLayout(p, value, 0) })
		}
		if ui.Select(c.Key("memoryRadix"), &radix, debugMemoryRadixChoices, func(radix int) string {
			return debugMemoryRadixName(lang, radix)
		}).Label(i18n.Shared(lang, "desktop.debug.memoryRadix")).Width(debugMemoryPickerWidth).Height(24).Shrink(1); radix != m.radix && (m.radix != 0 || radix != 16) {
			value := radix
			c.After(func() { a.setDebugMemoryLayout(p, 0, value) })
		}
	})
}

// setDebugMemoryLayout changes the bytes per row or the base, zero leaving one as it is, and
// keeps the byte read at in view.
func (a *App) setDebugMemoryLayout(p *project, columns, radix int) {
	m := &p.debug.memory
	if columns != 0 {
		m.columns = columns
	}
	if radix != 0 {
		m.radix = radix
	}
	m.version++
	if m.mark >= 0 {
		columns, _ := m.layout()
		m.list.ScrollTo(m.mark/columns, ui.ListCenter)
	}
}

// debugMemoryRadixName names one base in the base picker.
func debugMemoryRadixName(lang i18n.Language, radix int) string {
	switch radix {
	case 2:
		return i18n.Shared(lang, "desktop.debug.memoryRadixBinary")
	case 8:
		return i18n.Shared(lang, "desktop.debug.memoryRadixOctal")
	case 10:
		return i18n.Shared(lang, "desktop.debug.memoryRadixDecimal")
	}
	return i18n.Shared(lang, "desktop.debug.memoryRadixHex")
}
