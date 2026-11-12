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

// InstalledShells lists the shells the system shell file accepts, the standard
// installation prefixes hold and PATH finds, for the terminal's new-terminal menu
// and its default shell setting. Every installation is an entry of its own: bash
// from the system and bash from Homebrew are different programs, often of
// different versions, and the user picks one of them, as the macOS client did.
func InstalledShells() []Choice {
	paths := shellPathsByFamily(systemShellFile, shellPrefixes)
	return collapseCShellAlias(discoverInstallations(candidatesFrom(paths), defaultShell(), exec.LookPath))
}

// discoverInstallations keeps every distinct executable of each family, in the
// order the family's places are tried. Places that reach the same file are one
// installation and keep the first place: a symbolic link into Homebrew's cellar,
// the bare name PATH resolves, /bin and /usr/bin on a merged /usr. Families never
// merge, so sh stays beside the shell it links to; collapseCShellAlias handles
// the one pair that is the same shell under two names.
//
// Default marks the preferred program by its path or, when the preferred path is
// not one of the places, by the entry of its family that is the same file.
func discoverInstallations(candidates []shellCandidate, preferred string, lookup func(string) (string, error)) []Choice {
	preferred = filepath.Clean(preferred)
	preferredInfo, preferredErr := os.Stat(preferred)
	var choices []Choice
	for _, candidate := range candidates {
		var kept []os.FileInfo
		for _, program := range candidate.paths {
			if program == "" {
				continue
			}
			path, err := lookup(program)
			if err != nil {
				continue
			}
			if path, err = filepath.Abs(path); err != nil {
				continue
			}
			info, err := os.Stat(path)
			if err != nil || info.IsDir() || hasPath(choices, path) || sameAsAny(kept, info) {
				continue
			}
			kept = append(kept, info)
			isDefault := path == preferred || (preferredErr == nil && candidate.name == filepath.Base(preferred) && os.SameFile(preferredInfo, info))
			choices = append(choices, Choice{Name: candidate.name, Path: path, Default: isDefault})
		}
	}
	return choices
}

// hasPath says whether a choice already runs path.
func hasPath(choices []Choice, path string) bool {
	for _, choice := range choices {
		if choice.Path == path {
			return true
		}
	}
	return false
}

// sameAsAny says whether info is the same file as one of kept.
func sameAsAny(kept []os.FileInfo, info os.FileInfo) bool {
	for _, other := range kept {
		if os.SameFile(other, info) {
			return true
		}
	}
	return false
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
