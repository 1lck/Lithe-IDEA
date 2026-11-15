package localshell

import (
	"encoding/base64"
	"slices"
	"strings"
	"testing"
	"unicode/utf16"
)

func utf16le(text string, bom bool) []byte {
	units := utf16.Encode([]rune(text))
	var out []byte
	if bom {
		out = append(out, 0xff, 0xfe)
	}
	for _, unit := range units {
		out = append(out, byte(unit), byte(unit>>8))
	}
	return out
}

func TestWSLDistrosAreReadFromEitherEncodingAndLeaveOutWhatIsNotOne(t *testing.T) {
	list := "Ubuntu-22.04\r\ndocker-desktop\r\nDebian\r\ndocker-desktop-data\r\nubuntu-22.04\r\n\r\n"
	want := []string{"Ubuntu-22.04", "Debian"}
	for name, output := range map[string][]byte{
		"utf-16 with a byte order mark": utf16le(list, true),
		"utf-16 without":                utf16le(list, false),
		"utf-8":                         []byte(list),
	} {
		if got := ParseWSLDistros(output); !slices.Equal(got, want) {
			t.Errorf("%s: %q, want %q", name, got, want)
		}
	}
	// What wsl.exe says when there is nothing to list is not a distribution.
	for _, message := range []string{
		"Windows Subsystem for Linux has no installed distributions.\r\nYou can install a distribution by running 'wsl.exe --install'.\r\n",
		"适用于 Linux 的 Windows 子系统没有已安装的分发。\r\n",
		"",
	} {
		if got := ParseWSLDistros(utf16le(message, true)); len(got) != 0 {
			t.Errorf("%q was read as distributions %q", message, got)
		}
	}
}

func TestWSLShellNamesRoundTripAndRefuseOptionsAndPaths(t *testing.T) {
	if distro, ok := WSLDistro(WSLShell("Ubuntu-22.04")); !ok || distro != "Ubuntu-22.04" {
		t.Fatalf("WSLDistro = %q, %v", distro, ok)
	}
	for _, shell := range []string{"", "wsl:", "wsl:-d", "wsl:a b", `wsl:a"b`, `wsl:a\b`, "wsl:a/b", `C:\Windows\System32\wsl.exe`, "wsl.exe", "wsl:.hidden"} {
		if distro, ok := WSLDistro(shell); ok {
			t.Errorf("%q was taken for distribution %q", shell, distro)
		}
	}
}

func TestWSLPathsAreTranslatedBothWays(t *testing.T) {
	for _, test := range []struct {
		windows, distro, linux string
		ok                     bool
	}{
		{`\\wsl.localhost\Ubuntu\home\me\a b`, "Ubuntu", "/home/me/a b", true},
		{`\\WSL.LOCALHOST\ubuntu\home\me`, "Ubuntu", "/home/me", true},
		{`\\wsl$\Ubuntu\`, "Ubuntu", "/", true},
		{`\\wsl$\Ubuntu`, "Ubuntu", "/", true},
		{`\\wsl.localhost\Debian\home`, "Ubuntu", "", false},
		{`\\server\share\file`, "Ubuntu", "", false},
		{`C:\Users\me\x y.txt`, "Ubuntu", "/mnt/c/Users/me/x y.txt", true},
		{`d:/data`, "Ubuntu", "/mnt/d/data", true},
		{`C:\`, "Ubuntu", "/mnt/c/", true},
		{`relative\path`, "Ubuntu", "", false},
	} {
		got, ok := WSLPath(test.windows, test.distro)
		if got != test.linux || ok != test.ok {
			t.Errorf("WSLPath(%q, %q) = %q, %v; want %q, %v", test.windows, test.distro, got, ok, test.linux, test.ok)
		}
	}
}

func TestWSLStartDirectoryIsOnlyAWayTheDistributionCanReach(t *testing.T) {
	for dir, want := range map[string]string{
		`\\wsl.localhost\Ubuntu\home\me`: "/home/me",
		`C:\Users\me`:                    `C:\Users\me`,
		`\\wsl.localhost\Debian\home`:    "",
		`\\server\share`:                 "",
		"":                               "",
		"/home/me":                       "",
		"C:\\a\nb":                       "",
	} {
		if got := wslStartDirectory(dir, "Ubuntu"); got != want {
			t.Errorf("wslStartDirectory(%q) = %q, want %q", dir, got, want)
		}
	}
}

func TestSharedEnvironmentKeepsWhatTheUserShares(t *testing.T) {
	if got := wslShared(""); got != "TERM:COLORTERM:"+WSLDirectoryVariable {
		t.Fatalf("empty WSLENV became %q", got)
	}
	got := wslShared("GOPATH/l:term/u::")
	if got != "GOPATH/l:term/u:COLORTERM:"+WSLDirectoryVariable {
		t.Fatalf("WSLENV became %q", got)
	}
}

func TestWSLLaunchGivesWslExeOnlyArgumentsItCannotMisread(t *testing.T) {
	const exe = `C:\Windows\System32\wsl.exe`
	program, args, env := wslLaunch(exe, Config{Dir: `\\wsl.localhost\Ubuntu\home\me\my project`, WSLScript: "echo 'a \"b\" \\ c'\nexit 3\n"}, "Ubuntu", "KEEP/p")
	if program != exe {
		t.Fatalf("program = %q", program)
	}
	want := []string{"-d", "Ubuntu", "--cd", "~", "-e", "/bin/sh", "-c"}
	if !slices.Equal(args[:len(want)], want) || args[len(args)-1] != "sh" || len(args) != len(want)+2 {
		t.Fatalf("args = %q", args)
	}
	line := args[len(want)]
	if strings.ContainsAny(line, "\"\\\n\r\t") {
		t.Fatalf("the command line has a character wsl.exe may re-split: %q", line)
	}
	if !slices.Contains(env, WSLDirectoryVariable+"=/home/me/my project") || !slices.Contains(env, "WSLENV=KEEP/p:TERM:COLORTERM:"+WSLDirectoryVariable) {
		t.Fatalf("env = %q", env)
	}
}

func TestWSLCommandLineDecodesToTheScriptWithItsShellStateRestored(t *testing.T) {
	script := "case $x in *) echo \"quoted $y\" ;; esac\ncat <<'EOF'\nline\nEOF\n"
	line := wslCommandLine(script)
	encoded := line[strings.Index(line, "printf %s ")+len("printf %s ") : strings.Index(line, "|base64")]
	payload, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != "unset IFS\nset +f\n"+script {
		t.Fatalf("payload = %q", payload)
	}
	if !strings.Contains(line, "IFS=;set -f;eval $_motty_script") || !strings.Contains(line, "|| exec ${SHELL:-/bin/sh} -l;") {
		t.Fatalf("line = %q", line)
	}
}

func TestWSLLaunchWithoutAScriptStartsTheDistributionsOwnShell(t *testing.T) {
	_, args, env := wslLaunch("wsl.exe", Config{Dir: `C:\Users\me`}, "Debian", "")
	if !slices.Equal(args, []string{"-d", "Debian", "--cd", `C:\Users\me`}) || len(env) != 0 {
		t.Fatalf("args = %q, env = %q", args, env)
	}
	_, args, _ = wslLaunch("wsl.exe", Config{Dir: `\\server\share`}, "Debian", "")
	if !slices.Equal(args, []string{"-d", "Debian", "--cd", "~"}) {
		t.Fatalf("args = %q", args)
	}
	_, args, _ = wslLaunch("wsl.exe", Config{Args: []string{"ls", "-l"}, WSLScript: "ignored"}, "Debian", "")
	if !slices.Equal(args, []string{"-d", "Debian", "--cd", "~", "-e", "ls", "-l"}) {
		t.Fatalf("args = %q", args)
	}
}
