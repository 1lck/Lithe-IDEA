package term

import (
	"bytes"
	"encoding/base64"
	"unicode/utf8"
)

// maxClipboardText is the decoded OSC 52 text accepted from one sequence: room
// for a selection many screens long. maxClipboardSequence, the OSC string that
// carries it ("52;", a selection list of at most 16 bytes, ';', then base64),
// limits the encoded input first.
const (
	maxClipboardText     = 1 << 20
	maxClipboardSequence = len("52;") + 16 + len(";") + (maxClipboardText+2)/3*4
)

// ClipboardWrite is one validated OSC 52 request to replace the system
// clipboard. Selection is the requested xterm selection list; it always
// contains 'c', the only selection Viva's portable clipboard API represents.
type ClipboardWrite struct {
	Selection string
	Text      string
}

func (t *Terminal) osc52(payload []byte) {
	separator := bytes.IndexByte(payload, ';')
	if separator < 0 || t.clipboardFn == nil {
		return
	}
	selection, encoded := payload[:separator], payload[separator+1:]
	if !osc52ClipboardSelection(selection) || bytes.Equal(encoded, []byte{'?'}) {
		return
	}
	decodedLength := base64.StdEncoding.DecodedLen(len(encoded))
	if decodedLength > maxClipboardText {
		return
	}
	decoded := make([]byte, decodedLength)
	n, err := base64.StdEncoding.Strict().Decode(decoded, encoded)
	if err != nil {
		decodedLength = base64.RawStdEncoding.DecodedLen(len(encoded))
		if decodedLength > maxClipboardText {
			return
		}
		decoded = make([]byte, decodedLength)
		n, err = base64.RawStdEncoding.Strict().Decode(decoded, encoded)
	}
	decoded = decoded[:n]
	if err != nil || !utf8.Valid(decoded) || bytes.IndexByte(decoded, 0) >= 0 {
		return
	}
	name := string(selection)
	if name == "" {
		name = "c"
	}
	t.clipboardFn(ClipboardWrite{Selection: name, Text: string(decoded)})
}

func osc52ClipboardSelection(selection []byte) bool {
	if len(selection) == 0 {
		return true
	}
	if len(selection) > 16 {
		return false
	}
	clipboard := false
	for _, value := range selection {
		switch value {
		case 'c':
			clipboard = true
		case 'p', 'q', 's', '0', '1', '2', '3', '4', '5', '6', '7':
		default:
			return false
		}
	}
	return clipboard
}
