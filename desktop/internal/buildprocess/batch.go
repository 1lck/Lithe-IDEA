package buildprocess

import (
	"errors"
	"path/filepath"
	"strings"
)

// Windows runs a .cmd or .bat file through cmd.exe, which parses the whole command line again
// by its own rules. When Windows starts the script itself (os/exec on Windows does), the line
// becomes `cmd.exe /c <line>`, and cmd removes the first and the last quote of a line that holds
// more than two. A script under a directory with a space (C:\Program Files\...\mvn.cmd) then
// fails as soon as one argument is quoted too: cmd runs `C:\Program` (#2032). cmd also expands
// %VAR% and acts on & | < > ^ in an argument that is not quoted, so an argument can run a
// command (BatBadBut, CVE-2024-24576).
//
// batchCommandLine builds the line the host gives cmd.exe instead: the script and its arguments
// wrapped in one more pair of quotes, which cmd's /c removes, so the quotes inside stay as
// written. Arguments are quoted and escaped as Rust's standard library does since that
// advisory: every argument with a character other than letters, digits and #$*+-./:?@\_ is
// quoted, a quote is doubled, backslashes before a quote are doubled, and % is broken up so
// cmd never sees a variable.

// errBatchArgument is a script path or argument that cmd.exe cannot be given safely.
var errBatchArgument = errors.New("buildprocess: a batch file cannot be given this argument")

// isBatchFile says whether Windows would run executable through cmd.exe.
func isBatchFile(executable string) bool {
	switch strings.ToLower(filepath.Ext(executable)) {
	case ".cmd", ".bat":
		return true
	}
	return false
}

// batchCommandLine is the command line for cmd.exe that runs script with arguments, each of
// which the script receives exactly as given.
func batchCommandLine(script string, arguments []string) (string, error) {
	// A Windows file name holds no quote and does not end in a separator; either would end
	// the script's quotes early.
	if script == "" || strings.ContainsAny(script, "\"\x00\r\n") || strings.HasSuffix(script, `\`) {
		return "", errBatchArgument
	}
	var line strings.Builder
	// /d skips AutoRun commands, /e:ON keeps the %cd:~,% expansion below working and /v:OFF
	// keeps ! literal, whatever the user's registry defaults are.
	line.WriteString(`cmd.exe /e:ON /v:OFF /d /c ""`)
	line.WriteString(script)
	line.WriteByte('"')
	for _, argument := range arguments {
		// A line break ends cmd's command, so the rest would be a second command.
		if strings.ContainsAny(argument, "\x00\r\n") {
			return "", errBatchArgument
		}
		line.WriteByte(' ')
		appendBatchArgument(&line, argument)
	}
	line.WriteByte('"')
	return line.String(), nil
}

func appendBatchArgument(line *strings.Builder, argument string) {
	// An empty argument would vanish unquoted, and a trailing backslash would otherwise
	// escape the closing quote of a script that quotes "%~1".
	quote := argument == "" || strings.HasSuffix(argument, `\`)
	for _, r := range argument {
		if r < 0x80 {
			if !isUnquotedBatchByte(byte(r)) {
				quote = true
			}
		} else if r < 0xa0 {
			// C1 control characters.
			quote = true
		}
	}
	if quote {
		line.WriteByte('"')
	}
	backslashes := 0
	for _, r := range argument {
		if r == '\\' {
			backslashes++
			line.WriteRune(r)
			continue
		}
		switch r {
		case '"':
			// Backslashes before a quote are doubled, and the quote itself is doubled.
			line.WriteString(strings.Repeat(`\`, backslashes))
			line.WriteByte('"')
		case '%':
			// %cd:~,% is an empty substring of a variable that always exists, so cmd expands it
			// to nothing and the % that follows can no longer start a variable name.
			line.WriteString(`%%cd:~,`)
		}
		backslashes = 0
		line.WriteRune(r)
	}
	if quote {
		line.WriteString(strings.Repeat(`\`, backslashes))
		line.WriteByte('"')
	}
}

func isUnquotedBatchByte(c byte) bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	}
	return strings.IndexByte(`#$*+-./:?@\_`, c) >= 0
}
