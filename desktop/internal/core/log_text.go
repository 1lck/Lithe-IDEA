package core

import (
	"slices"
	"strings"
	"unicode/utf8"
)

// logTextLimit bounds the text fields the helpers of this file build, in bytes.
const logTextLimit = 1024

// logTokenLimit bounds a catalog token, in bytes.
const logTokenLimit = 64

// visible replaces a control character with a space, so a value stays on one line.
func visible(r rune) rune {
	if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) {
		return ' '
	}
	return r
}

// cutText shortens text to at most limit bytes without splitting a character.
func cutText(text string, limit int) string {
	if len(text) <= limit {
		return text
	}
	cut := limit
	for cut > 0 && !utf8.RuneStart(text[cut]) {
		cut--
	}
	return text[:cut]
}

// LogText encodes free text, such as a panic value, the way the catalog asks for a text field:
// control characters become spaces, every run of white space becomes one space and the result
// is cut to 1024 bytes. The kernel still redacts it before it reaches the disk.
func LogText(text string) string {
	return cutText(strings.Join(strings.Fields(strings.Map(visible, text)), " "), logTextLimit)
}

// LogFirstLine is the first line of text that is not blank, encoded with LogText. It reads the
// headline of a Go crash report, such as "panic: …" or "fatal error: …".
func LogFirstLine(text string) string {
	for line := range strings.Lines(text) {
		if line = strings.TrimSpace(line); line != "" {
			return LogText(line)
		}
	}
	return ""
}

// LogToken turns a short description such as "darwin: AppKit callback" into a catalog token
// such as darwin:appkit-callback. Letters are lowercased, every run of characters a token
// cannot hold becomes one hyphen, a hyphen next to a separator (".", ":" or "/") or at either
// end is dropped, and the result is cut to 64 bytes. A description with nothing left is
// "unknown".
func LogToken(text string) string {
	mapped := strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || strings.ContainsRune("._:/$", r) {
			return r
		}
		return '-'
	}, strings.ToLower(text))
	keepsHyphen := func(c byte) bool { return c != 0 && c != '-' && !isTokenSeparator(c) }
	out := make([]byte, 0, len(mapped))
	for i := 0; i < len(mapped); i++ {
		c := mapped[i]
		if c != '-' {
			out = append(out, c)
			continue
		}
		var previous, next byte
		if len(out) > 0 {
			previous = out[len(out)-1]
		}
		if i+1 < len(mapped) {
			next = mapped[i+1]
		}
		if keepsHyphen(previous) && keepsHyphen(next) {
			out = append(out, '-')
		}
	}
	token := strings.TrimRight(cutText(string(out), logTokenLimit), "-")
	if token == "" {
		return "unknown"
	}
	return token
}

func isTokenSeparator(c byte) bool {
	return c == '.' || c == ':' || c == '/'
}

// LogPanicStack compacts the first goroutine of a Go stack trace, as runtime/debug.Stack or a
// crash report prints it, into the frames that led to the panic. Each frame is the function
// without its package path and arguments, then the base name of its file and the line; frames
// are joined innermost first by " < ". The frames up to and including the panic call, and the
// runtime's frames before the first frame of the program, are left out. The result ends at a
// frame boundary within 1024 bytes. Base file names keep the user's directories out of the log.
func LogPanicStack(stack []byte) string {
	type frame struct {
		function, file string
		runtime        bool
	}
	var frames []frame
	started := false
	for line := range strings.Lines(string(stack)) {
		line = strings.TrimRight(line, "\r\n")
		if !started {
			started = strings.HasPrefix(line, "goroutine ") && strings.HasSuffix(line, "]:")
			continue
		}
		if strings.TrimSpace(line) == "" {
			// The first goroutine ends at a blank line; the next one is another stack.
			break
		}
		switch {
		case strings.HasPrefix(line, "\t"):
			if n := len(frames); n > 0 && frames[n-1].file == "" {
				frames[n-1].file = stackFile(line)
			}
		case strings.HasPrefix(line, "..."):
			// "...additional frames elided..." is not a frame.
		default:
			frames = append(frames, frame{
				function: stackFunction(line),
				runtime:  strings.HasPrefix(line, "runtime.") || strings.HasPrefix(line, "internal/runtime/"),
			})
		}
	}
	for i := len(frames) - 1; i >= 0; i-- {
		if frames[i].function == "panic" {
			frames = frames[i+1:]
			break
		}
	}
	if program := slices.IndexFunc(frames, func(f frame) bool { return !f.runtime }); program > 0 {
		frames = frames[program:]
	}
	var b strings.Builder
	for _, f := range frames {
		text := f.function
		if f.file != "" {
			text += " " + f.file
		}
		text = strings.Join(strings.Fields(strings.Map(visible, text)), " ")
		separator := ""
		if b.Len() > 0 {
			separator = " < "
		}
		if b.Len()+len(separator)+len(text) > logTextLimit {
			break
		}
		b.WriteString(separator)
		b.WriteString(text)
	}
	return b.String()
}

// stackFunction is the function a stack trace line names, without its package path and
// arguments, for example workbench.(*App).draw. A goroutine's creator keeps "created by".
func stackFunction(line string) string {
	prefix := ""
	if rest, ok := strings.CutPrefix(line, "created by "); ok {
		prefix, line = "created by ", rest
		if at := strings.Index(line, " in goroutine "); at >= 0 {
			line = line[:at]
		}
	} else if at := strings.LastIndexByte(line, '('); at > 0 {
		// Arguments are hexadecimal words, braces, question marks and dots, never
		// parentheses, so the last opening parenthesis starts them, also after (*Type).
		line = line[:at]
	}
	if at := strings.LastIndexByte(line, '/'); at >= 0 {
		line = line[at+1:]
	}
	return prefix + line
}

// stackFile is the base name and line of a stack trace file line such as
// "\t/path/app.go:900 +0x30".
func stackFile(line string) string {
	line = strings.TrimSpace(line)
	if at := strings.Index(line, " +0x"); at >= 0 {
		line = line[:at]
	}
	if at := strings.LastIndexAny(line, `/\`); at >= 0 {
		line = line[at+1:]
	}
	return line
}
