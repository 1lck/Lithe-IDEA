package localshell

import "bytes"

// markIntroducer starts every prompt mark the integration scripts print: OSC 133, then
// the mark's letter, its parameters and the token suffix, ended by BEL.
const markIntroducer = "\x1b]133;"

// promptMarks recognizes the prompt marks an integrated shell prints (see
// integration_scripts.go) in its output, read in pieces as they arrive: A where
// the prompt begins, B where the prompt ends and the shell waits for input, C
// where a command starts and D, with the status, where it finished. A mark counts
// only with the session's token, so a program that prints OSC 133 itself does not
// move it. Only the reader feeds it.
type promptMarks struct {
	// suffix is ";motty=<token>", the end of every mark of this session.
	suffix []byte
	// matched is how much of markIntroducer the output ends with, kind the mark's
	// letter once all of it matched, and params what followed the letter so far.
	matched int
	kind    byte
	params  []byte
}

func newPromptMarks(token string) *promptMarks {
	if token == "" {
		return nil
	}
	return &promptMarks{suffix: []byte(";motty=" + token)}
}

// feed reads the next piece of output and calls seen with the letter of each mark of
// the session it completes.
func (m *promptMarks) feed(data []byte, seen func(kind byte)) {
	for i := 0; i < len(data); i++ {
		b := data[i]
		switch {
		case m.kind != 0:
			switch {
			case b == 0x07:
				if m.ours() {
					seen(m.kind)
				}
				m.reset()
			case b == 0x1b || len(m.params) >= len(m.suffix)+maxMarkStatus:
				m.reset()
				m.restart(b)
			default:
				m.params = append(m.params, b)
			}
		case m.matched == len(markIntroducer):
			m.reset()
			if b >= 'A' && b <= 'D' {
				m.kind = b
			} else {
				m.restart(b)
			}
		case m.matched > 0:
			if b == markIntroducer[m.matched] {
				m.matched++
			} else {
				m.reset()
				m.restart(b)
			}
		default:
			next := bytes.IndexByte(data[i:], 0x1b)
			if next < 0 {
				return
			}
			i += next
			m.matched = 1
		}
	}
}

// maxMarkStatus bounds what a mark may carry before the suffix: D's ";<status>".
const maxMarkStatus = 12

// ours says whether the mark that just ended carries the session's suffix, after
// nothing but D's status.
func (m *promptMarks) ours() bool {
	rest, ok := bytes.CutSuffix(m.params, m.suffix)
	return ok && (len(rest) == 0 || m.kind == 'D')
}

// restart begins a new match at b, which may itself start the introducer.
func (m *promptMarks) restart(b byte) {
	if b == 0x1b {
		m.matched = 1
	}
}

func (m *promptMarks) reset() {
	m.matched, m.kind, m.params = 0, 0, m.params[:0]
}
