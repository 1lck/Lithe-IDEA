package shellkind

import "testing"

func TestParseProbeNamesTheShellThatAnsweredIt(t *testing.T) {
	tests := []struct {
		name, output string
		want         Kind
	}{
		{"posix shells expand the variables to nothing", "motty-shell:\n", POSIX},
		{"posix over a windows pty", "motty-shell:\r\n", POSIX},
		{"pwsh prints the version table's type", "motty-shell:System.Collections.Hashtable\r\n", PowerShell},
		{"windows powershell", "motty-shell:System.Management.Automation.PSVersionHashtable\r\n", PowerShell},
		{"fish prints its version", "motty-shell:3.7.1\n", Fish},
		{"cmd.exe echoes the quotes", "\"motty-shell:$PSVersionTable$FISH_VERSION\"\r\n", Cmd},
		{"nushell does not interpolate", "motty-shell:$PSVersionTable$FISH_VERSION\n", Nushell},
		{"a login banner before the answer is skipped", "Welcome\nmotty-shell:\n", POSIX},
		{"no answer", "", Unknown},
		{"an unrelated answer", "command not found\n", Unknown},
		{"an answer nobody expects", "motty-shell:weird\n", Unknown},
	}
	for _, tc := range tests {
		if got := ParseProbe(tc.output); got != tc.want {
			t.Errorf("%s: ParseProbe(%q) = %v, want %v", tc.name, tc.output, got, tc.want)
		}
	}
}

func TestFromProgram(t *testing.T) {
	tests := map[string]Kind{
		"/bin/zsh":                               POSIX,
		"bash":                                   POSIX,
		`C:\Program Files\Git\bin\bash.exe`:      POSIX,
		"wsl:Ubuntu":                             POSIX,
		`C:\Program Files\PowerShell\7\pwsh.exe`: PowerShell,
		`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`: PowerShell,
		`C:\WINDOWS\system32\CMD.EXE`:                               Cmd,
		"/usr/bin/fish":                                             Fish,
		"/opt/homebrew/bin/nu":                                      Nushell,
		"claude":                                                    Unknown,
		"":                                                          Unknown,
	}
	for program, want := range tests {
		if got := FromProgram(program); got != want {
			t.Errorf("FromProgram(%q) = %v, want %v", program, got, want)
		}
	}
}

func TestUnsupportedShellsAreOnlyThoseWithNoWrapper(t *testing.T) {
	for _, kind := range []Kind{Unknown, POSIX, PowerShell, Console} {
		if !kind.SupportsExec() {
			t.Errorf("%v should support exec", kind)
		}
	}
	for _, kind := range []Kind{Cmd, Fish, Nushell} {
		if kind.SupportsExec() {
			t.Errorf("%v should not support exec", kind)
		}
	}
}
