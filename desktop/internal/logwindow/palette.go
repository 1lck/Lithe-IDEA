package logwindow

import (
	"hash/fnv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// palette is the log window's own colors. The window keeps them apart from the workbench
// theme because a log reads best in the dense, high-contrast look of a terminal, and the
// macOS client's log window uses exactly these values, so both clients look the same.
type palette struct {
	bg, bg2, bg3   gfx.Color
	hl, line, bd   gfx.Color
	tx, tx2, tx3   gfx.Color
	red, org, yel  gfx.Color
	grn, cyn, blu  gfx.Color
	pur, pnk       gfx.Color
	errRow, errSel gfx.Color
	opRow, menu    gfx.Color
	foot, white    gfx.Color
	pulse          gfx.Color
	dark           bool
}

func lightPalette() palette {
	return palette{
		bg: gfx.RGB24(0xffffff), bg2: gfx.RGB24(0xf6f8fa), bg3: gfx.RGB24(0xeef1f4),
		hl: gfx.RGB24(0xddf4ff), line: gfx.RGB24(0xe4e8ec), bd: gfx.RGB24(0xd0d7de),
		tx: gfx.RGB24(0x1f2328), tx2: gfx.RGB24(0x59636e), tx3: gfx.RGB24(0x8c959f),
		red: gfx.RGB24(0xcf222e), org: gfx.RGB24(0xbc4c00), yel: gfx.RGB24(0x9a6700),
		grn: gfx.RGB24(0x1a7f37), cyn: gfx.RGB24(0x0550ae), blu: gfx.RGB24(0x0969da),
		pur: gfx.RGB24(0x8250df), pnk: gfx.RGB24(0xbf3989),
		errRow: gfx.RGB24(0xffebe9), errSel: gfx.RGB24(0xffd8d3),
		opRow: gfx.RGB24(0xfbefff), menu: gfx.RGB24(0xffffff),
		foot: gfx.RGB24(0x0969da), white: gfx.RGB24(0xffffff), pulse: gfx.RGB24(0x7ee787),
	}
}

func darkPalette() palette {
	return palette{
		bg: gfx.RGB24(0x0d1117), bg2: gfx.RGB24(0x010409), bg3: gfx.RGB24(0x161b22),
		hl: gfx.RGB24(0x1f2a3a), line: gfx.RGB24(0x21262d), bd: gfx.RGB24(0x30363d),
		tx: gfx.RGB24(0xc9d1d9), tx2: gfx.RGB24(0x8b949e), tx3: gfx.RGB24(0x6e7681),
		red: gfx.RGB24(0xff7b72), org: gfx.RGB24(0xffa657), yel: gfx.RGB24(0xe3b341),
		grn: gfx.RGB24(0x7ee787), cyn: gfx.RGB24(0x79c0ff), blu: gfx.RGB24(0x58a6ff),
		pur: gfx.RGB24(0xd2a8ff), pnk: gfx.RGB24(0xff9bce),
		errRow: gfx.RGB24(0xf85149).WithAlpha(0.102), errSel: gfx.RGB24(0x3b1d22),
		opRow: gfx.RGB24(0x2a1f3d), menu: gfx.RGB24(0x161b22),
		foot: gfx.RGB24(0x1f6feb), white: gfx.RGB24(0xffffff), pulse: gfx.RGB24(0x7ee787),
		dark: true,
	}
}

// channelColors are the colors a channel other than app is told apart by. The index is a
// stable hash of the channel's name, so a channel keeps its color across sessions and in
// both clients.
var channelColors = [...]gfx.Color{
	gfx.RGB24(0x2f81f7), gfx.RGB24(0xe16f24), gfx.RGB24(0xcf222e),
	gfx.RGB24(0xf78166), gfx.RGB24(0x2da44e), gfx.RGB24(0xa371f7),
}

// channelColor is the color of a channel's chip. The app channel is the neutral gray the
// macOS client gives it; every other channel takes its FNV-1a 64 hash modulo the palette,
// which is the hash the macOS client uses, so a channel has the same color in both.
func channelColor(channel string) gfx.Color {
	if channel == "app" {
		return gfx.RGB24(0x8b949e)
	}
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(channel))
	return channelColors[hash.Sum64()%uint64(len(channelColors))]
}

// levelColor is the color of a level's name and symbol.
func (p palette) levelColor(level core.LogLevel) gfx.Color {
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
