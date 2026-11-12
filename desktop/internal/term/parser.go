package term

import (
	"strconv"
	"strings"
	"unicode/utf8"
)

type parseState uint8

const (
	stGround parseState = iota
	stEscape
	stEscapeInter // ESC followed by intermediate bytes (charset designation, #)
	stCSIEntry
	stCSIParam
	stCSIInter
	stCSIIgnore
	stOSC
	stDCS
	stAPC
	stString // SOS and PM: skipped up to the string terminator
)

const maxParams = 32

// parser is the escape-sequence state machine. It is a Paul Williams style
// VT500 parser with UTF-8 decoding in the ground state; any sequence may be
// split across Write calls at any byte.
type parser struct {
	state parseState

	utf8r   rune // code point being assembled
	utf8n   int  // continuation bytes still expected
	utf8min rune // smallest value a sequence of this length may encode

	params   [maxParams]int32 // -1 when the parameter was left empty
	colon    [maxParams]bool  // parameter was introduced by ':' (subparameter)
	np       int
	cur      int32
	hasCur   bool
	curColon bool
	priv     byte    // '<', '=', '>' or '?' leading the parameters
	inter    [2]byte // intermediate bytes
	ninter   int
	escInter byte

	osc         []byte
	oscOverflow bool
	dcs         []byte
	dcsOverflow bool
	apc         []byte
	apcOverflow bool

	scratch []byte // buffer answers are formatted in
}

// Write feeds output from the host into the terminal. It always consumes all
// of p.
func (t *Terminal) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	for i := 0; i < len(p); {
		if t.state == stGround && t.utf8n == 0 && t.charsets[t.gl] == charsetASCII {
			// The run check stays ahead of the scan: behind it, the scan's
			// hot path cost 7% more on a redraw of short runs.
			if p[i] >= 0x80 {
				if n := t.textRun(p[i:]); n > 0 {
					i += n
					continue
				}
			}
			j := i
			for j < len(p) && p[j] >= 0x20 && p[j] < 0x7F {
				j++
			}
			if j > i {
				t.printASCII(p[i:j])
				i = j
				continue
			}
		}
		if t.inString() {
			if run := t.stringRun(p[i:]); run > 0 {
				i += run
				continue
			}
		}
		t.feed(p[i])
		i++
	}
	t.version++
	return len(p), nil
}

// textRun writes the non-ASCII text at the start of p and returns how many
// bytes it took, or zero when the sequence cannot be completed from p. A run
// ends at a control character and at the end of p; the rest is the state
// machine's, so a character split across writes still carries over.
func (t *Terminal) textRun(p []byte) int {
	t.runBuf = t.runBuf[:0]
	n := 0
	for n < len(p) && len(t.runBuf) < maxTextRun {
		b := p[n]
		if b >= 0x20 && b < 0x7F {
			t.runBuf = append(t.runBuf, rune(b))
			n++
			continue
		}
		if b < 0x20 || b == 0x7F {
			break
		}
		r, size := utf8.DecodeRune(p[n:])
		if r == utf8.RuneError && size <= 1 {
			break
		}
		t.runBuf = append(t.runBuf, r)
		n += size
	}
	if n == 0 {
		return 0
	}
	t.printRunes(t.runBuf)
	return n
}

// inString reports whether the parser is inside a control string, whose payload
// is copied in runs rather than fed a byte at a time.
func (t *Terminal) inString() bool {
	switch t.state {
	case stOSC, stDCS, stAPC:
		return true
	}
	return false
}

// stringRun appends a printable run of a control string in one copy and
// returns how many bytes it took, or zero when the byte needs the per-byte
// state machine (a terminator, a C0 control, or an OSC whose limit still
// depends on its first bytes). An inline picture's payload is megabytes, and
// copying it one byte at a time cost more than decoding it.
func (t *Terminal) stringRun(p []byte) int {
	if len(p) == 0 || p[0] < 0x20 {
		return 0
	}
	var dst *[]byte
	limit, overflow := maxOSC, false
	switch t.state {
	case stOSC:
		// A longer limit applies only when the string starts with its prefix,
		// so the first bytes still go through the per-byte path.
		var decided bool
		if limit, decided = oscLimit(t.osc); !decided {
			return 0
		}
		dst, overflow = &t.osc, t.oscOverflow
	case stDCS:
		dst, overflow, limit = &t.dcs, t.dcsOverflow, maxSixelSequence
	case stAPC:
		dst, overflow, limit = &t.apc, t.apcOverflow, maxImageSequence
	default:
		return 0
	}
	run := 0
	for run < len(p) && p[run] >= 0x20 {
		run++
	}
	if overflow {
		return run
	}
	take := min(run, max(limit-len(*dst), 0))
	*dst = append(*dst, p[:take]...)
	if take < run {
		switch t.state {
		case stOSC:
			t.oscOverflow = true
		case stDCS:
			t.dcsOverflow = true
		case stAPC:
			t.apcOverflow = true
		}
	}
	return run
}

func (t *Terminal) feed(b byte) {
	// Input is UTF-8: C1 byte values can be continuation bytes inside a
	// control-string payload, where ground's UTF-8 decoder is not running.
	// Recognize string controls through their seven-bit ESC forms instead.
	switch b {
	case 0x18, 0x1A: // CAN, SUB cancel any sequence
		if t.utf8n > 0 {
			t.utf8n = 0
		}
		t.state = stGround
		return
	case 0x1B:
		t.endString()
		if t.utf8n > 0 {
			t.utf8n = 0
			t.print(0xFFFD)
		}
		t.state = stEscape
		t.escInter = 0
		return
	}
	switch t.state {
	case stGround:
		t.ground(b)
	case stEscape:
		t.escape(b)
	case stEscapeInter:
		t.escapeInter(b)
	case stCSIEntry, stCSIParam, stCSIInter, stCSIIgnore:
		t.csi(b)
	case stOSC:
		t.oscByte(b)
	case stDCS:
		t.dcsByte(b)
	case stAPC:
		t.apcByte(b)
	case stString:
		// Skipped; ESC (handled above) or CAN/SUB ends it.
	}
}

// ground handles text and C0 controls, decoding UTF-8 as it goes.
func (t *Terminal) ground(b byte) {
	if t.utf8n > 0 {
		if b&0xC0 == 0x80 {
			t.utf8r = t.utf8r<<6 | rune(b&0x3F)
			t.utf8n--
			if t.utf8n == 0 {
				r := t.utf8r
				if r < t.utf8min || r > 0x10FFFF || (r >= 0xD800 && r <= 0xDFFF) {
					r = 0xFFFD
				}
				t.print(r)
			}
			return
		}
		// A truncated sequence: report it, then handle b afresh.
		t.utf8n = 0
		t.print(0xFFFD)
	}
	switch {
	case b < 0x20:
		t.control(b)
	case b < 0x7F:
		t.print(rune(b))
	case b == 0x7F:
	case b >= 0xC2 && b <= 0xDF:
		t.utf8r, t.utf8n, t.utf8min = rune(b&0x1F), 1, 0x80
	case b >= 0xE0 && b <= 0xEF:
		t.utf8r, t.utf8n, t.utf8min = rune(b&0x0F), 2, 0x800
	case b >= 0xF0 && b <= 0xF4:
		t.utf8r, t.utf8n, t.utf8min = rune(b&0x07), 3, 0x10000
	default:
		t.print(0xFFFD)
	}
}

// control executes a C0 control character.
func (t *Terminal) control(b byte) {
	switch b {
	case 0x07: // BEL
		if t.bellFn != nil {
			t.bellFn()
		}
	case 0x08: // BS
		t.pend = false
		if t.cx > 0 {
			t.cx--
		}
	case 0x09: // HT
		t.tabForward(1)
	case 0x0A, 0x0B, 0x0C: // LF, VT, FF
		t.pend = false
		t.index()
		if t.modes.Newline {
			t.cx = 0
		}
	case 0x0D: // CR
		t.pend = false
		t.cx = 0
	case 0x0E: // SO
		t.gl = 1
	case 0x0F: // SI
		t.gl = 0
	}
}

func (t *Terminal) tabForward(n int) {
	t.pend = false
	for ; n > 0; n-- {
		x := t.cx + 1
		for x < t.cols-1 && !t.tabs[x] {
			x++
		}
		t.cx = min(x, t.cols-1)
	}
}

func (t *Terminal) tabBackward(n int) {
	t.pend = false
	for ; n > 0; n-- {
		x := t.cx - 1
		for x > 0 && !t.tabs[x] {
			x--
		}
		t.cx = max(x, 0)
	}
}

// escape handles the byte after ESC.
func (t *Terminal) escape(b byte) {
	switch {
	case b < 0x20:
		t.control(b)
	case b <= 0x2F: // intermediate
		t.escInter = b
		t.state = stEscapeInter
	case b == '[':
		t.state = stCSIEntry
		t.resetParams()
	case b == ']':
		t.state = stOSC
		t.osc, t.oscOverflow = t.osc[:0], false
	case b == 'P':
		t.state, t.dcs, t.dcsOverflow = stDCS, t.dcs[:0], false
	case b == '_':
		t.state, t.apc, t.apcOverflow = stAPC, t.apc[:0], false
	case b == 'X' || b == '^':
		t.state = stString
	case b >= 0x80:
		t.state = stGround
		t.ground(b)
	default:
		t.state = stGround
		t.escDispatch(b)
	}
}

func (t *Terminal) escapeInter(b byte) {
	switch {
	case b < 0x20:
		t.control(b)
	case b <= 0x2F:
		t.escInter = b // later intermediates replace; only the last designates
	case b >= 0x80:
		t.state = stGround
		t.ground(b)
	default:
		t.state = stGround
		t.escDispatchInter(t.escInter, b)
	}
}

func (t *Terminal) resetParams() {
	t.np, t.cur, t.hasCur, t.curColon = 0, 0, false, false
	t.priv, t.ninter = 0, 0
}

func (t *Terminal) pushParam() {
	if t.np < maxParams {
		value := int32(-1)
		if t.hasCur {
			value = t.cur
		}
		t.params[t.np] = value
		t.colon[t.np] = t.curColon
		t.np++
	}
	t.cur, t.hasCur = 0, false
}

// csi advances the CSI sub-machine by one byte.
func (t *Terminal) csi(b byte) {
	switch {
	case b < 0x20:
		t.control(b)
	case b >= 0x80:
		t.state = stGround
		t.ground(b)
	case b >= 0x40 && b <= 0x7E:
		if t.state != stCSIIgnore {
			if t.np > 0 || t.hasCur {
				t.pushParam()
			}
			t.csiDispatch(b)
		}
		t.state = stGround
	case b >= 0x30 && b <= 0x39:
		if t.state == stCSIInter || t.state == stCSIIgnore {
			t.state = stCSIIgnore
			return
		}
		t.state = stCSIParam
		t.cur = min(t.cur*10+int32(b-'0'), 65535)
		t.hasCur = true
	case b == ';' || b == ':':
		if t.state == stCSIInter || t.state == stCSIIgnore {
			t.state = stCSIIgnore
			return
		}
		t.state = stCSIParam
		t.pushParam()
		t.curColon = b == ':'
	case b >= 0x3C && b <= 0x3F: // private markers
		if t.state == stCSIEntry {
			t.priv = b
			t.state = stCSIParam
		} else {
			t.state = stCSIIgnore
		}
	default: // 0x20-0x2F intermediates
		if t.state == stCSIIgnore {
			return
		}
		if t.ninter < len(t.inter) {
			t.inter[t.ninter] = b
		}
		t.ninter++
		t.state = stCSIInter
	}
}

func (t *Terminal) oscByte(b byte) {
	switch {
	case b == 0x07:
		t.endOSC()
		t.state = stGround
	case b < 0x20:
	default:
		limit, _ := oscLimit(t.osc)
		if len(t.osc) < limit {
			t.osc = append(t.osc, b)
		} else {
			t.oscOverflow = true
		}
	}
}

// oscPrefixLimits are the OSC strings that may run past maxOSC, by their first
// bytes: an inline picture, and a clipboard write, which carries a whole
// selection (a page of output, or a table whose box drawing is three bytes a
// character).
var oscPrefixLimits = [...]struct {
	prefix string
	limit  int
}{
	{"1337;File=", maxImageSequence},
	{"52;", maxClipboardSequence},
}

// oscLimit is the byte limit of an OSC string that begins with osc, and
// whether those bytes decide it: false while osc could still grow into one of
// the oscPrefixLimits prefixes.
func oscLimit(osc []byte) (limit int, decided bool) {
	decided = true
	for _, rule := range oscPrefixLimits {
		if len(osc) >= len(rule.prefix) {
			if string(osc[:len(rule.prefix)]) == rule.prefix {
				return rule.limit, true
			}
		} else if string(osc) == rule.prefix[:len(osc)] {
			decided = false
		}
	}
	return maxOSC, decided
}

// endOSC runs a completed operating-system command.
func (t *Terminal) endOSC() {
	t.state = stGround
	data := t.osc
	t.osc = t.osc[:0]
	if t.oscOverflow {
		return
	}
	n, i := 0, 0
	for i < len(data) && data[i] >= '0' && data[i] <= '9' && i < 6 {
		n = n*10 + int(data[i]-'0')
		i++
	}
	if i == 0 || (i < len(data) && data[i] != ';') {
		return
	}
	text := data[min(i+1, len(data)):]
	switch n {
	case 0, 2:
		t.setTitle(text)
	case 7:
		t.osc7(text)
	case 8:
		t.setHyperlink(text)
	case 9:
		t.osc9(text)
	case 99:
		t.osc99(text)
	case 133:
		suffix := ""
		if t.promptToken != "" {
			suffix = ";motty=" + t.promptToken
		}
		// The owning shell's prompt is drawn after the command it just finished,
		// so this is where a program that never restored its modes loses them.
		// A token is required: without one, markers a program echoes are
		// indistinguishable from the shell's own.
		own := t.promptToken != ""
		value := string(text)
		if value == "A"+suffix {
			t.inputStartSet = false
			if own {
				t.ReclaimApplicationModes()
			}
			if t.promptStartFn != nil {
				t.promptStartFn()
			}
		}
		if value == "B"+suffix {
			t.markInputStart(own)
			if t.promptReadyFn != nil {
				t.promptReadyFn()
			}
		}
		if value == "C"+suffix {
			t.inputStartSet = false
			if t.commandStartFn != nil {
				t.commandStartFn()
			}
		}
		if strings.HasPrefix(value, "D;") && strings.HasSuffix(value, suffix) {
			t.inputStartSet = false
			status := strings.TrimSuffix(value[2:], suffix)
			if code, err := strconv.Atoi(status); err == nil && code >= 0 && code <= 255 && strconv.Itoa(code) == status {
				if own {
					t.ReclaimApplicationModes()
				}
				if t.commandFinishedFn != nil {
					t.commandFinishedFn(code)
				}
			}
		}
	case 777:
		t.inputEnvironmentReport(text)
		t.osc777(text)
	case 10, 11:
		if len(text) == 1 && text[0] == '?' && t.haveDefaults {
			color := t.defFG
			if n == 11 {
				color = t.defBG
			}
			t.answerColor(n, color)
		}
	case 52:
		t.osc52(text)
	case 1337:
		if t.itermImage(text) {
			// The decoder reads the payload in place; the next escape sequence
			// must not overwrite the buffer under it.
			t.osc = nil
		}
	}
}

func (t *Terminal) dcsByte(b byte) {
	if b < 0x20 {
		return
	}
	if len(t.dcs) < maxSixelSequence {
		t.dcs = append(t.dcs, b)
	} else {
		t.dcsOverflow = true
	}
}

func (t *Terminal) apcByte(b byte) {
	if b < 0x20 {
		return
	}
	if len(t.apc) < maxImageSequence {
		t.apc = append(t.apc, b)
	} else {
		t.apcOverflow = true
	}
}

func (t *Terminal) endString() {
	switch t.state {
	case stOSC:
		t.endOSC()
	case stDCS:
		data, overflow := t.dcs, t.dcsOverflow
		t.dcs, t.dcsOverflow, t.state = t.dcs[:0], false, stGround
		if !overflow {
			if t.sixel(data) {
				// Decoding reads the sequence in place; detach it.
				t.dcs = nil
			}
		}
	case stAPC:
		data, overflow := t.apc, t.apcOverflow
		t.apc, t.apcOverflow, t.state = t.apc[:0], false, stGround
		if !overflow {
			t.kittyGraphics(data)
		}
	case stString:
		t.state = stGround
	}
}

func (t *Terminal) setTitle(text []byte) {
	if len(text) > maxTitle {
		text = text[:maxTitle]
	}
	out := make([]rune, 0, len(text))
	for _, r := range string(text) {
		if r >= 0x20 && r != 0x7F {
			out = append(out, r)
		}
	}
	t.title = string(out)
}

func (t *Terminal) answerColor(n int, c [3]uint8) {
	b := append(t.scratch[:0], "\x1b]"...)
	b = strconv.AppendInt(b, int64(n), 10)
	b = append(b, ";rgb:"...)
	for i, v := range c {
		if i > 0 {
			b = append(b, '/')
		}
		b = append(b, hexDigits[v>>4], hexDigits[v&15], hexDigits[v>>4], hexDigits[v&15])
	}
	b = append(b, "\x1b\\"...)
	t.send(b)
}

const hexDigits = "0123456789abcdef"

// send hands an answer to the owner.
func (t *Terminal) send(b []byte) {
	t.scratch = b[:0]
	if t.replyFn != nil {
		t.replyFn(b)
	}
}
