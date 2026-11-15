package localshell

import (
	"encoding/base64"
	"strings"
	"unicode/utf16"
)

// A WSL distribution is chosen like any other local shell, by naming it in
// Config.Shell. The name is not a path: it is "wsl:" and the distribution's
// name, which no Windows file name can be, so it never collides with an
// executable. Everything here is plain string work, so it is the same and can
// be tested on every platform; only starting wsl.exe is Windows-only.

const wslPrefix = "wsl:"

// WSLDirectoryVariable names the environment variable that carries the folder
// a WSL shell starts in. It is handed over the environment, never the command
// line, so no quoting of the path can go wrong.
const WSLDirectoryVariable = "MOTTY_WSL_CD"

// WSLShell is the Config.Shell value that runs distro.
func WSLShell(distro string) string { return wslPrefix + distro }

// WSLDistro is the distribution a Config.Shell value names, or false when it is
// an ordinary program.
func WSLDistro(shell string) (string, bool) {
	distro, ok := strings.CutPrefix(shell, wslPrefix)
	if !ok || !validDistro(distro) {
		return "", false
	}
	return distro, true
}

// validDistro accepts the names distributions are given: letters, digits, dots,
// underscores and hyphens, starting with a letter or digit. A name with a
// space or an accent is left out rather than risk reading a sentence as a name,
// and one starting with a hyphen could be taken for an option.
func validDistro(name string) bool {
	if name == "" || len(name) > 128 {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		letter := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
		if !letter && (i == 0 || c != '.' && c != '_' && c != '-') {
			return false
		}
	}
	return true
}

// ParseWSLDistros reads the output of `wsl.exe --list --quiet`: one name a
// line, in UTF-16 unless WSL was asked for UTF-8. It leaves out WSL's own
// service distributions, which have no shell, and anything that is not a
// plausible name, such as the sentence wsl.exe prints when nothing is
// installed.
func ParseWSLDistros(output []byte) []string {
	text := decodeWSLOutput(output)
	var names []string
	seen := map[string]bool{}
	for _, line := range strings.Split(text, "\n") {
		name := strings.TrimSpace(strings.TrimPrefix(line, "\ufeff"))
		if !validDistro(name) || strings.HasPrefix(strings.ToLower(name), "docker-desktop") || seen[strings.ToLower(name)] {
			continue
		}
		seen[strings.ToLower(name)] = true
		names = append(names, name)
	}
	return names
}

func decodeWSLOutput(output []byte) string {
	// UTF-16 is recognized by its byte order mark, or by the zero that follows
	// the first letter of any name written in it.
	if len(output) >= 2 && (output[0] == 0xff && output[1] == 0xfe || output[1] == 0) {
		units := make([]uint16, 0, len(output)/2)
		for i := 0; i+1 < len(output); i += 2 {
			units = append(units, uint16(output[i])|uint16(output[i+1])<<8)
		}
		return string(utf16.Decode(units))
	}
	return strings.ReplaceAll(string(output), "\x00", "")
}

// WSLName is how a menu names distro's shell.
func WSLName(distro string) string { return "WSL: " + distro }

// WSLChoices is the menu entries of distros.
func WSLChoices(distros []string) []Choice {
	choices := make([]Choice, 0, len(distros))
	for _, distro := range distros {
		choices = append(choices, Choice{Name: WSLName(distro), Path: WSLShell(distro)})
	}
	return choices
}

// wslUNCPrefixes are the two spellings of the network path Windows shows a
// distribution's files under: the current one, and the one before Windows 11.
var wslUNCPrefixes = []string{`\\wsl.localhost\`, `\\wsl$\`}

// splitWSLUNC reads a Windows path that names a file in a distribution, such as
// \\wsl.localhost\Ubuntu\home\me: the distribution, and the path inside it.
func splitWSLUNC(windowsPath string) (distro, linux string, ok bool) {
	normalized := strings.ReplaceAll(windowsPath, "/", `\`)
	for _, prefix := range wslUNCPrefixes {
		if len(normalized) < len(prefix) || !strings.EqualFold(normalized[:len(prefix)], prefix) {
			continue
		}
		name, rest, _ := strings.Cut(normalized[len(prefix):], `\`)
		return name, "/" + strings.Trim(strings.ReplaceAll(rest, `\`, "/"), "/"), name != ""
	}
	return "", "", false
}

// IsWSLUNC reports whether windowsPath is inside some distribution's files.
// Opening one can start the distribution, so it is not a path to test for
// existence on the window thread.
func IsWSLUNC(windowsPath string) bool {
	_, _, ok := splitWSLUNC(windowsPath)
	return ok
}

// wslUNCPath is the path inside distro of a Windows path that names a file in
// it.
func wslUNCPath(windowsPath, distro string) (string, bool) {
	name, linux, ok := splitWSLUNC(windowsPath)
	if !ok || !strings.EqualFold(name, distro) {
		return "", false
	}
	return linux, true
}

// WSLPath is a Windows path as distro sees it: a folder of its own files, or a
// file on a Windows drive, which is mounted under /mnt. It reports false for a
// path that distro cannot name, and assumes the drives are mounted where WSL
// puts them unless told otherwise in /etc/wsl.conf.
func WSLPath(windowsPath, distro string) (string, bool) {
	if linux, ok := wslUNCPath(windowsPath, distro); ok {
		return linux, true
	}
	if len(windowsPath) >= 3 && windowsPath[1] == ':' && (windowsPath[2] == '\\' || windowsPath[2] == '/') {
		drive := windowsPath[0]
		if drive >= 'A' && drive <= 'Z' {
			drive += 'a' - 'A'
		}
		if drive >= 'a' && drive <= 'z' {
			return "/mnt/" + string(rune(drive)) + "/" + strings.Trim(strings.ReplaceAll(windowsPath[3:], `\`, "/"), "/"), true
		}
	}
	return "", false
}

// wslStartDirectory is what to tell the start script to change into for dir,
// a folder the files panel or a Windows path reported: a path inside distro
// is given as the distribution knows it, a path on a Windows drive as Windows
// writes it, and anything else, which distro cannot reach, as nothing.
func wslStartDirectory(dir, distro string) string {
	if dir == "" || len(dir) > 2048 || strings.IndexFunc(dir, func(r rune) bool { return r < 0x20 || r == 0x7f }) >= 0 {
		return ""
	}
	if linux, ok := wslUNCPath(dir, distro); ok {
		return linux
	}
	if len(dir) >= 3 && dir[1] == ':' && (dir[2] == '\\' || dir[2] == '/') {
		return dir
	}
	return ""
}

// wslEnvironmentVariables are the variables WSL is told to carry into the
// distribution, besides the ones the user already shares.
var wslEnvironmentVariables = []string{"TERM", "COLORTERM", WSLDirectoryVariable}

// wslShared is WSLENV with the variables a Motty shell needs added, keeping
// whatever the user already shares and its translation flags.
func wslShared(inherited string) string {
	shared := map[string]bool{}
	var entries []string
	for _, entry := range strings.Split(inherited, ":") {
		if entry == "" {
			continue
		}
		name, _, _ := strings.Cut(entry, "/")
		shared[strings.ToUpper(name)] = true
		entries = append(entries, entry)
	}
	for _, name := range wslEnvironmentVariables {
		if !shared[name] {
			entries = append(entries, name)
		}
	}
	return strings.Join(entries, ":")
}

// wslCommandLine is the single argument given to sh -c that runs script. The
// script travels base64-encoded because wsl.exe re-splits its arguments, and
// the line must survive that without a quote, backslash or newline in it; sh
// then decodes and evaluates it. An undecodable payload falls back to the
// user's own shell, rather than a tab that closes at once.
func wslCommandLine(script string) string {
	// eval gets one word, so the script keeps its newlines: no field splitting
	// and no pathname expansion; the script itself starts by restoring both.
	payload := "unset IFS\nset +f\n" + script
	units := base64.StdEncoding.EncodeToString([]byte(payload))
	return "_motty_script=$(printf %s " + units + "|base64 -d) || exec ${SHELL:-/bin/sh} -l; IFS=;set -f;eval $_motty_script"
}

// wslLaunch is how to start config's shell in distro through the wsl.exe at
// exe: its arguments, and the environment to add to the process's own.
func wslLaunch(exe string, config Config, distro, inheritedWSLENV string) (program string, args, env []string) {
	args = []string{"-d", distro}
	cd := wslStartDirectory(config.Dir, distro)
	switch {
	case len(config.Args) > 0:
		// An explicit command runs as given, without the integration.
		args = append(args, "--cd", "~", "-e")
		args = append(args, config.Args...)
		return exe, args, nil
	case config.WSLScript == "":
		// No script: the distribution's own login shell, started where asked
		// when that is a place wsl.exe takes as a Windows or a Linux path.
		if cd == "" {
			cd = "~"
		}
		return exe, append(args, "--cd", cd), nil
	}
	args = append(args, "--cd", "~", "-e", "/bin/sh", "-c", wslCommandLine(config.WSLScript), "sh")
	if cd != "" {
		env = append(env, WSLDirectoryVariable+"="+cd)
	}
	env = append(env, "WSLENV="+wslShared(inheritedWSLENV))
	return exe, args, env
}
