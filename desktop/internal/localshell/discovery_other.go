//go:build !windows

package localshell

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// systemShellFile is the list of shells the system accepts for a login. It is
// the authority on what this machine offers, and a user who adds a shell
// through chsh or a package manager's post-install hook appends it here, so
// reading it picks those up without this file naming every shell in advance.
// It is a variable so a test can point it at its own list.
var systemShellFile = "/etc/shells"

// shellPrefixes are searched for every known shell family, in this order,
// before PATH is consulted. PATH alone is not enough: an application started
// from the Finder inherits launchd's minimal PATH (/usr/bin:/bin:/usr/sbin:
// /sbin), which holds neither Homebrew prefix, so a shell installed with brew
// would be invisible to it. /opt/local is MacPorts, with the same problem.
var shellPrefixes = []string{"/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin"}

// shellFamilies are the interactive shells worth an entry whether or not the
// system shell file names them, in the order the settings offer them.
var shellFamilies = []string{"zsh", "bash", "fish", "nu", "elvish", "xonsh", "tcsh", "csh", "ksh", "dash", "sh"}

// InstalledWindowsShells is the cross-platform name for local shell discovery.
// On non-Windows systems it lists the shells the system shell file accepts,
// the standard installation prefixes and PATH, keeping one entry per family.
func InstalledWindowsShells() []Choice {
	paths := shellPathsByFamily(systemShellFile, shellPrefixes)
	return collapseCShellAlias(discoverShells(candidatesFrom(paths), defaultShell(), exec.LookPath))
}

// collapseCShellAlias keeps one entry when csh and tcsh are two names for the
// same executable, as on macOS. They run the same C shell there, so offering
// both only repeats the same program in the picker. sh is not merged with the
// shell it may link to: argv[0] selects POSIX mode, which is a distinct shell.
func collapseCShellAlias(choices []Choice) []Choice {
	csh, tcsh := -1, -1
	for index, choice := range choices {
		switch choice.Name {
		case "csh":
			csh = index
		case "tcsh":
			tcsh = index
		}
	}
	if csh < 0 || tcsh < 0 {
		return choices
	}
	cshInfo, err := os.Stat(choices[csh].Path)
	if err != nil {
		return choices
	}
	tcshInfo, err := os.Stat(choices[tcsh].Path)
	if err != nil || !os.SameFile(cshInfo, tcshInfo) {
		return choices
	}
	return append(choices[:csh], choices[csh+1:]...)
}

// shellPathsByFamily gathers the places each shell family may live, in the
// order they should be tried: the system shell file first, then the standard
// prefixes, then the bare name for the final PATH lookup. Families named by
// the shell file but absent from shellFamilies are kept and listed last, so a
// shell this file does not know about still appears.
func shellPathsByFamily(shellFile string, prefixes []string) map[string][]string {
	paths := make(map[string][]string)
	add := func(family, path string) {
		if family == "" || path == "" {
			return
		}
		paths[family] = append(paths[family], path)
	}

	for _, line := range readShellFile(shellFile) {
		add(filepath.Base(line), line)
	}
	for _, family := range shellFamilies {
		for _, prefix := range prefixes {
			add(family, filepath.Join(prefix, family))
		}
		// The last resort: a program only on PATH, such as a shell built from
		// source into a directory of its own.
		add(family, family)
	}
	return paths
}

// readShellFile returns the executable paths the system shell file names,
// ignoring comments, blank lines and entries that are not there.
func readShellFile(name string) []string {
	data, err := os.ReadFile(name)
	if err != nil {
		return nil
	}
	var shells []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if info, err := os.Stat(line); err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			continue
		}
		shells = append(shells, line)
	}
	return shells
}

// candidatesFrom orders the gathered families: the known ones first, in the
// order the settings show them, then anything else the shell file named.
func candidatesFrom(paths map[string][]string) []shellCandidate {
	known := make(map[string]bool, len(shellFamilies))
	for _, family := range shellFamilies {
		known[family] = true
	}
	var extra []string
	for family := range paths {
		if !known[family] {
			extra = append(extra, family)
		}
	}
	sort.Strings(extra)

	candidates := make([]shellCandidate, 0, len(paths))
	for _, family := range append(append([]string{}, shellFamilies...), extra...) {
		if familyPaths, ok := paths[family]; ok {
			candidates = append(candidates, shellCandidate{name: family, paths: familyPaths})
		}
	}
	return candidates
}
