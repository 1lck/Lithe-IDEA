package logwindow

import (
	"hash/fnv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// palette is the log window's own colors. The window keeps them apart from the workbench
// theme because a log reads best in the dense, high-contrast look of a terminal, and the
// macOS client's log window uses exactly these values, so both clients look the same.
type palette struct {
	bg, bg2, bg3   ui.Color
	hl, line, bd   ui.Color
	tx, tx2, tx3   ui.Color
	red, org, yel  ui.Color
	grn, cyn, blu  ui.Color
	pur, pnk       ui.Color
	errRow, errSel ui.Color
	opRow, menu    ui.Color
	foot, white    ui.Color
	pulse          ui.Color
	dark           bool
}

func lightPalette() palette {
	return palette{
		bg: ui.RGB24(0xffffff), bg2: ui.RGB24(0xf6f8fa), bg3: ui.RGB24(0xeef1f4),
		hl: ui.RGB24(0xddf4ff), line: ui.RGB24(0xe4e8ec), bd: ui.RGB24(0xd0d7de),
		tx: ui.RGB24(0x1f2328), tx2: ui.RGB24(0x59636e), tx3: ui.RGB24(0x8c959f),
		red: ui.RGB24(0xcf222e), org: ui.RGB24(0xbc4c00), yel: ui.RGB24(0x9a6700),
		grn: ui.RGB24(0x1a7f37), cyn: ui.RGB24(0x0550ae), blu: ui.RGB24(0x0969da),
		pur: ui.RGB24(0x8250df), pnk: ui.RGB24(0xbf3989),
		errRow: ui.RGB24(0xffebe9), errSel: ui.RGB24(0xffd8d3),
		opRow: ui.RGB24(0xfbefff), menu: ui.RGB24(0xffffff),
		foot: ui.RGB24(0x0969da), white: ui.RGB24(0xffffff), pulse: ui.RGB24(0x7ee787),
	}
}

func darkPalette() palette {
	return palette{
		bg: ui.RGB24(0x0d1117), bg2: ui.RGB24(0x010409), bg3: ui.RGB24(0x161b22),
		hl: ui.RGB24(0x1f2a3a), line: ui.RGB24(0x21262d), bd: ui.RGB24(0x30363d),
		tx: ui.RGB24(0xc9d1d9), tx2: ui.RGB24(0x8b949e), tx3: ui.RGB24(0x6e7681),
		red: ui.RGB24(0xff7b72), org: ui.RGB24(0xffa657), yel: ui.RGB24(0xe3b341),
		grn: ui.RGB24(0x7ee787), cyn: ui.RGB24(0x79c0ff), blu: ui.RGB24(0x58a6ff),
		pur: ui.RGB24(0xd2a8ff), pnk: ui.RGB24(0xff9bce),
		errRow: ui.RGB24(0xf85149).WithAlpha(0.102), errSel: ui.RGB24(0x3b1d22),
		opRow: ui.RGB24(0x2a1f3d), menu: ui.RGB24(0x161b22),
		foot: ui.RGB24(0x1f6feb), white: ui.RGB24(0xffffff), pulse: ui.RGB24(0x7ee787),
		dark: true,
	}
}

// channelColors are the colors a channel other than app is told apart by. The index is a
// stable hash of the channel's name, so a channel keeps its color across sessions and in
// both clients.
var channelColors = [...]ui.Color{
	ui.RGB24(0x2f81f7), ui.RGB24(0xe16f24), ui.RGB24(0xcf222e),
	ui.RGB24(0xf78166), ui.RGB24(0x2da44e), ui.RGB24(0xa371f7),
}

// channelColor is the color of a channel's chip. The app channel is the neutral gray the
// macOS client gives it; every other channel takes its FNV-1a 64 hash modulo the palette,
// which is the hash the macOS client uses, so a channel has the same color in both.
func channelColor(channel string) ui.Color {
	if channel == "app" {
		return ui.RGB24(0x8b949e)
	}
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(channel))
	return channelColors[hash.Sum64()%uint64(len(channelColors))]
}

// levelColor is the color of a level's name and symbol.
func (p palette) levelColor(level core.LogLevel) ui.Color {
	switch level {
	case core.LevelError:
		return p.red
	case core.LevelWarn:
		return p.yel
	case core.LevelInfo:
		return p.blu
	}
	return p.tx3
}

// levelSymbol is the mark in front of a level's name.
func levelSymbol(level core.LogLevel) string {
	switch level {
	case core.LevelError:
		return "✖"
	case core.LevelWarn:
		return "▲"
	case core.LevelInfo:
		return "●"
	}
	return "·"
}
