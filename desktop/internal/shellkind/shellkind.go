// Package shellkind names the family of command language an interactive shell
// speaks. Code that types a command into a terminal for the user, such as the
// assistant's terminal_exec, must know it: a POSIX "{ ...; }" group and "$?"
// mean nothing to PowerShell, cmd.exe, fish or nushell, and a network device
// console has neither.
package shellkind

import (
	"strings"
)

// Kind is a shell family. The zero value, Unknown, means nothing was learned;
// callers keep their historical POSIX assumption for it rather than refusing
// to work.
type Kind uint8

const (
	Unknown Kind = iota
	// POSIX is sh, bash, zsh, dash, ksh and their relatives, including Git Bash
	// and WSL shells.
	POSIX
	// PowerShell is Windows PowerShell 5.1 and PowerShell 7+ (pwsh).
	PowerShell
	// Cmd is the Windows command interpreter.
	Cmd
	Fish
	Nushell
	// Console is a line-oriented terminal that is not a known shell: a network
	// device CLI, an appliance console, or any other program reached over Telnet
	// or a serial port. It accepts one command line at a time and shows a prompt
	// when the command returns, but it has no shell syntax and no exit status of
	// its own.
	Console
)

// String is the shell's display name, for messages shown to the user.
func (kind Kind) String() string {
	switch kind {
	case POSIX:
		return "POSIX shell"
	case PowerShell:
		return "PowerShell"
	case Cmd:
		return "cmd.exe"
	case Fish:
		return "fish"
	case Nushell:
		return "nushell"
	case Console:
		return "device console"
	}
	return "unknown shell"
}

// FromProgram classifies a shell by its executable: a path or a bare name, with
// or without ".exe". It is Unknown for a program it does not recognize.
func FromProgram(program string) Kind {
	if strings.HasPrefix(program, "wsl:") {
		return POSIX // a WSL distribution's login shell
	}
	name := program
	if cut := strings.LastIndexAny(name, `\/`); cut >= 0 {
		name = name[cut+1:]
	}
	name = strings.ToLower(strings.TrimSuffix(strings.ToLower(name), ".exe"))
	switch name {
	case "sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "busybox", "rbash":
		return POSIX
	case "pwsh", "powershell", "pwsh-preview":
		return PowerShell
	case "cmd":
		return Cmd
	case "fish":
		return Fish
	case "nu":
		return Nushell
	}
	return Unknown
}

// Probe is one command line that every shell family understands well enough to
// tell itself apart, run over a command channel (the server runs it with the
// same shell as an interactive session). The double-quoted string expands
// differently in each:
//
//   - POSIX shells print "motty-shell:", the variables being unset;
//   - fish prints its version after the colon;
//   - PowerShell prints its version table's type name, which starts "System.";
//   - cmd.exe prints the quotes and the text unchanged;
//   - nushell's double quotes do not interpolate, so the text is unchanged.
const Probe = `echo "motty-shell:$PSVersionTable$FISH_VERSION"`

// ParseProbe classifies the output of [Probe]. Anything it cannot read is
// Unknown, never a guess.
func ParseProbe(output string) Kind {
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, `"motty-shell:`) {
			return Cmd
		}
		value, ok := strings.CutPrefix(line, "motty-shell:")
		if !ok {
			continue
		}
		switch {
		case value == "":
			return POSIX
		case strings.HasPrefix(value, "System."):
			return PowerShell
		case value == "$PSVersionTable$FISH_VERSION":
			return Nushell
		case value[0] >= '0' && value[0] <= '9':
			return Fish
		}
		return Unknown
	}
	return Unknown
}

// SupportsExec reports whether the assistant can run a command in a shell of
// this kind and learn how it ended. Unknown is supported: the POSIX wrapper has
// always been used for it. Console is supported without a wrapper; the prompt
// returning marks the end.
func (kind Kind) SupportsExec() bool {
	switch kind {
	case Unknown, POSIX, PowerShell, Console:
		return true
	}
	return false
}
