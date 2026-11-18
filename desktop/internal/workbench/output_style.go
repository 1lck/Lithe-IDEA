package workbench

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const (
	// outputDecodePiece bounds the text of one Core decode, well under Core's 1 MiB chunk limit.
	outputDecodePiece = 256 << 10
	// outputDecodeTimeout bounds one Core decode.
	outputDecodeTimeout = 10 * time.Second
)

// styledLine is one line of console output with its escapes removed: plain text, which copying,
// search, output links and the IDE API read, and the ranges Core styled (UTF-16 offsets).
type styledLine struct {
	text  string
	spans []core.OutputSpan
}

// outputChunk is what one piece of output adds to a console: the lines it finished, the first
// continuing the previous open line, and the line still being written.
type outputChunk struct {
	lines []styledLine
	open  styledLine
}

// outputDecoder turns one console's output into styled lines through Core's outputStyle.decode,
// carrying Core's state from chunk to chunk. It runs on the goroutines that read the output, never
// on the window thread: deliver decodes and hands the result to post while holding the decoder, so
// the chunks of a console that two streams write reach the window in the order they were decoded.
type outputDecoder struct {
	kernel Kernel
	mu     sync.Mutex
	state  json.RawMessage
	// carry is the start of a character the previous text ended inside.
	carry string
	// open is the line still being written, kept for the plain fallback.
	open styledLine
	// plain is set once Core failed: the rest of the console is split into lines as it is.
	plain bool
}

func newOutputDecoder(kernel Kernel) *outputDecoder {
	return &outputDecoder{kernel: kernel}
}

// deliver decodes text and passes the result to post, with failure set the first time Core could
// not decode this console's output; the window thread logs it once.
func (d *outputDecoder) deliver(text string, post func(chunk outputChunk, failure error)) {
	d.mu.Lock()
	defer d.mu.Unlock()
	chunk, failure := d.decode(text)
	post(chunk, failure)
}

// decode is deliver without the lock and the hand-off; d.mu is held.
func (d *outputDecoder) decode(text string) (outputChunk, error) {
	text = d.carry + text
	d.carry = ""
	if cut := completeUTF8(text); cut < len(text) {
		d.carry, text = text[cut:], text[:cut]
	}
	chunk := outputChunk{open: d.open}
	var failure error
	for len(text) > 0 {
		piece := text
		if len(piece) > outputDecodePiece {
			cut := outputDecodePiece
			for cut > 0 && !utf8.RuneStart(piece[cut]) {
				cut--
			}
			piece = piece[:cut]
		}
		text = text[len(piece):]
		if !d.plain {
			ctx, cancel := context.WithTimeout(context.Background(), outputDecodeTimeout)
			decoded, err := d.kernel.DecodeOutputStyle(ctx, piece, d.state)
			cancel()
			if err == nil {
				d.state = decoded.State
				for _, line := range decoded.Lines {
					chunk.lines = append(chunk.lines, styledLine{text: line.Text, spans: line.Spans})
				}
				chunk.open = styledLine{text: decoded.Open.Text, spans: decoded.Open.Spans}
				continue
			}
			d.plain, d.state, failure = true, nil, err
		}
		chunk.lines, chunk.open = splitPlainOutput(chunk.lines, chunk.open, piece)
	}
	d.open = chunk.open
	return chunk, failure
}

// splitPlainOutput appends the lines text ends to lines, continuing open, without decoding escapes.
func splitPlainOutput(lines []styledLine, open styledLine, text string) ([]styledLine, styledLine) {
	for {
		index := strings.IndexByte(text, '\n')
		if index < 0 {
			open.text += text
			return lines, open
		}
		open.text += strings.TrimSuffix(text[:index], "\r")
		lines = append(lines, open)
		open, text = styledLine{}, text[index+1:]
	}
}

// completeUTF8 returns how much of text ends on a character boundary: a character the text ends
// inside is left for the next text.
func completeUTF8(text string) int {
	for back := 1; back < utf8.UTFMax && back <= len(text); back++ {
		start := len(text) - back
		if utf8.RuneStart(text[start]) {
			if utf8.FullRuneInString(text[start:]) {
				return len(text)
			}
			return start
		}
	}
	return len(text)
}

// outputBuffer is one console's bounded output: finished lines, oldest first, and the line still
// being written. The oldest lines go first when it holds more than maxLines lines or maxBytes
// bytes. start is the sequence number of lines[0] and sequence counts the lines ever finished, so
// a reader that remembers a sequence notices lines that were dropped. revision counts the changes
// to what it shows, so a view that wraps the lines breaks them again only when they changed; it
// is zero only before the first. Window thread only.
type outputBuffer struct {
	lines              []styledLine
	open               styledLine
	bytes              int
	start, sequence    int
	maxLines, maxBytes int
	revision           uint64
}

func newOutputBuffer(maxLines, maxBytes int) outputBuffer {
	return outputBuffer{maxLines: maxLines, maxBytes: maxBytes}
}

// apply adds a decoded chunk.
func (b *outputBuffer) apply(chunk outputChunk) {
	b.revision++
	for _, line := range chunk.lines {
		b.lines = append(b.lines, line)
		b.bytes += len(line.text) + 1
		b.sequence++
	}
	b.open = chunk.open
	for len(b.lines) > 0 && (len(b.lines) > b.maxLines || b.bytes > b.maxBytes) {
		b.bytes -= len(b.lines[0].text) + 1
		b.lines[0] = styledLine{}
		b.lines = b.lines[1:]
		b.start++
	}
}

// seal finishes the open line of a console whose writer ended.
func (b *outputBuffer) seal() {
	if b.open.text == "" {
		return
	}
	b.apply(outputChunk{lines: []styledLine{b.open}})
}

// clear drops the finished lines. The line still being written stays, since its writer continues
// it; the sequence keeps counting.
func (b *outputBuffer) clear() {
	b.lines, b.bytes, b.start = nil, 0, b.sequence
	b.revision++
}

// count is the number of rows the console shows: the finished lines and an open line with text.
func (b *outputBuffer) count() int {
	if b.open.text != "" {
		return len(b.lines) + 1
	}
	return len(b.lines)
}

// row is the row index of the console.
func (b *outputBuffer) row(index int) styledLine {
	if index < len(b.lines) {
		return b.lines[index]
	}
	return b.open
}

// empty reports whether the console shows nothing.
func (b *outputBuffer) empty() bool {
	return b.count() == 0
}

// text joins the finished lines from sequence from up to sequence to that the buffer still holds,
// each with its line ending.
func (b *outputBuffer) text(from, to int) string {
	from, to = max(from, b.start), min(to, b.sequence)
	if from >= to {
		return ""
	}
	var out strings.Builder
	for _, line := range b.lines[from-b.start : to-b.start] {
		out.WriteString(line.text)
		out.WriteByte('\n')
	}
	return out.String()
}

// all is everything the console shows, for copying and snapshots.
func (b *outputBuffer) all() string {
	return b.text(b.start, b.sequence) + b.open.text
}

// reportOutputStyleFailure logs that Core could not decode a console's escapes; that console
// shows the rest of its output as it came, so the colors are what is lost, not the output. Each
// decoder reports its failure once; nil is none.
func (a *App) reportOutputStyleFailure(failure error) {
	if failure != nil {
		a.backgroundFailed("output_style", failure)
	}
}
