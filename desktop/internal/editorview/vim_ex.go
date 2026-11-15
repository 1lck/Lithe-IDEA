package editorview

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
)

// vim_ex.go is the Vim command line: the : prompt and the commands it runs. w, q, q!, wq and x are
// the window's to run (SetVimExit); a line number goes to that line; :s substitutes over a range as
// one undo step; :noh is accepted and does nothing, as the editor shows no search highlight.

// SetVimExit sets what the window does for the commands that save and close: run returns false for
// a command it does not know.
func (v *View) SetVimExit(run func(cmd string) bool) { v.vim.exit = run }

// vimExStart opens the : prompt with prefill in it.
func (v *View) vimExStart(prefill string) {
	v.vimCancel()
	st := &v.vim
	st.searching, st.exPrompt, st.searchBack = true, true, false
	st.prompt = []rune(prefill)
	st.message = ""
}

// vimSelectedLines is the first and last line of the selection.
func (v *View) vimSelectedLines() (int, int) {
	from, to := v.Selection()
	last := v.text.LineOf(to)
	if to > from && v.text.ByteAt(to-1) == '\n' {
		last = v.text.LineOf(to - 1)
	}
	return v.text.LineOf(from), last
}

// vimExecute runs the command line cmd. A failed command leaves its message in the status bar.
func (v *View) vimExecute(cmd string) {
	st := &v.vim
	cur := v.text.LineOf(v.caret)
	from, to := cur, cur
	cmd = strings.TrimSpace(cmd)
	switch {
	case strings.HasPrefix(cmd, "%"):
		from, to, cmd = 0, v.text.LineCount()-1, cmd[1:]
	case strings.HasPrefix(cmd, "'<,'>"):
		from, to, cmd = st.exFrom, st.exTo, cmd[5:]
	}
	cmd = strings.TrimSpace(cmd)
	switch {
	case cmd == "", cmd == "noh":
	case vimAllDigits(cmd):
		n, _ := strconv.Atoi(cmd)
		v.vimGotoLine(n - 1)
	case cmd == "w" || cmd == "q" || cmd == "q!" || cmd == "wq" || cmd == "x":
		if st.exit == nil || !st.exit(cmd) {
			v.vimSetMessage(v.vimWord(v.words.VimUnknown, cmd))
		}
	case len(cmd) > 1 && cmd[0] == 's' && !unicode.IsLetter(rune(cmd[1])) && !unicode.IsDigit(rune(cmd[1])) && cmd[1] != ' ':
		v.vimSubstitute(cmd, from, to)
	default:
		v.vimSetMessage(v.vimWord(v.words.VimUnknown, cmd))
	}
}

// vimWord is the message f makes of arg, or arg itself when the window gave no message.
func (v *View) vimWord(f func(string) string, arg string) string {
	if f == nil {
		return arg
	}
	return f(arg)
}

// vimSetMessage shows text in the status bar until the next key.
func (v *View) vimSetMessage(text string) { v.vim.message = text }

// vimGotoLine moves the caret to the first character of line, clamped to the text.
func (v *View) vimGotoLine(line int) {
	line = min(max(line, 0), v.text.LineCount()-1)
	v.moveTo(v.vimFirstNB(line), false)
	v.vimClamp()
}

// vimSubstitute runs the :s command cmd (s/pattern/replacement/flags, with the delimiter any
// punctuation) over the lines from..to. The pattern is a Go regular expression; the replacement
// takes \0-\9 and & for the match groups, \n for a line break, and $ is literal. The g flag replaces
// every match in a line, and otherwise the first one. The whole change is one undo step.
func (v *View) vimSubstitute(cmd string, from, to int) {
	pat, rep, flags := vimSplitSub(cmd[2:], cmd[1])
	re, err := regexp.Compile(pat)
	if err != nil || pat == "" {
		v.vimSetMessage(v.vimWord(v.words.VimNotFound, pat))
		return
	}
	tmpl := vimReplacement(rep)
	global := strings.Contains(flags, "g")
	from, to = max(from, 0), min(to, v.text.LineCount()-1)
	first, last := -1, -1
	out := make([]string, 0, to-from+1)
	for i := from; i <= to; i++ {
		raw := v.text.Line(i)
		body, cr := raw, ""
		if strings.HasSuffix(raw, "\r") {
			body, cr = raw[:len(raw)-1], "\r"
		}
		changed := body
		if global {
			changed = re.ReplaceAllString(body, tmpl)
		} else if loc := re.FindStringSubmatchIndex(body); loc != nil {
			changed = body[:loc[0]] + string(re.ExpandString(nil, tmpl, body, loc)) + body[loc[1]:]
		}
		if changed != body {
			if first < 0 {
				first = i
			}
			last = i
		}
		out = append(out, changed+cr)
	}
	if first < 0 {
		v.vimSetMessage(v.vimWord(v.words.VimNotFound, pat))
		return
	}
	v.edit(v.text.LineStart(from), v.text.LineEnd(to), strings.Join(out, "\n"), editOther)
	v.moveTo(v.vimFirstNB(last), false)
	v.vimClamp()
}

// vimSplitSub splits the text of a substitute after its command letter, delimited by delim, into
// the pattern, the replacement and the flags. A backslash before the delimiter is the delimiter.
func vimSplitSub(text string, delim byte) (pat, rep, flags string) {
	var parts [3]strings.Builder
	n := 0
	for i := 0; i < len(text); i++ {
		c := text[i]
		switch {
		case c == '\\' && i+1 < len(text) && text[i+1] == delim:
			parts[n].WriteByte(delim)
			i++
		case c == delim && n < 2:
			n++
		default:
			parts[n].WriteByte(c)
		}
	}
	return parts[0].String(), parts[1].String(), parts[2].String()
}

// vimReplacement is the replacement text of a substitute as a Go template.
func vimReplacement(rep string) string {
	var b strings.Builder
	for i := 0; i < len(rep); i++ {
		c := rep[i]
		switch {
		case c == '\\' && i+1 < len(rep):
			i++
			n := rep[i]
			switch {
			case n >= '0' && n <= '9':
				b.WriteString("${" + string(n) + "}")
			case n == 'n':
				b.WriteByte('\n')
			default:
				b.WriteByte(n)
			}
		case c == '&':
			b.WriteString("${0}")
		case c == '$':
			b.WriteString("$$")
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// vimAllDigits says s is a non-empty run of digits.
func vimAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
