//go:build windows

package localshell

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"golang.org/x/sys/windows/registry"
)

// cygwinSetupKey is where the Cygwin setup program records the root it should
// install into. It is read before the default roots so a Cygwin installed to a
// directory of the user's choosing is still found (issue #435).
const cygwinSetupKey = `Software\Cygwin\setup`

// cygwinSetupProbe is one place that record can be: this user's view of it or
// the machine's, each in the 64- and 32-bit views, because a 32-bit setup on a
// 64-bit Windows writes under WOW6432Node.
type cygwinSetupProbe struct {
	hive   registry.Key
	access uint32
}

var cygwinSetupProbes = []cygwinSetupProbe{
	{registry.CURRENT_USER, registry.WOW64_64KEY},
	{registry.CURRENT_USER, registry.WOW64_32KEY},
	{registry.LOCAL_MACHINE, registry.WOW64_64KEY},
	{registry.LOCAL_MACHINE, registry.WOW64_32KEY},
}

// cygwinRootFromRegistry reads the recorded root of one probe, or "" when that
// key says nothing. It is a variable so a test can stand in for the registry.
var cygwinRootFromRegistry = func(probe cygwinSetupProbe) string {
	key, err := registry.OpenKey(probe.hive, cygwinSetupKey, registry.QUERY_VALUE|probe.access)
	if err != nil {
		return ""
	}
	defer key.Close()
	root, _, err := key.GetStringValue("rootdir")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(root)
}

// cygwinRecordedRoots lists the roots the setup program recorded, this user's
// first, without repeats.
func cygwinRecordedRoots() []string {
	var roots []string
	for _, probe := range cygwinSetupProbes {
		root := cygwinRootFromRegistry(probe)
		if root == "" || !filepath.IsAbs(root) {
			continue
		}
		if slices.ContainsFunc(roots, func(seen string) bool { return strings.EqualFold(seen, root) }) {
			continue
		}
		roots = append(roots, root)
	}
	return roots
}

// InstalledWindowsShells looks in PATH and standard machine/per-user install
// locations. It checks executable files without starting the user's programs.
func InstalledWindowsShells() []Choice {
	pwsh := []string{"pwsh.exe"}
	bash := []string{}
	nu := []string{"nu.exe"}
	for _, root := range []string{os.Getenv("ProgramW6432"), os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)"), filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs")} {
		if root == "" || !filepath.IsAbs(root) {
			continue
		}
		versions, _ := filepath.Glob(filepath.Join(root, "PowerShell", "*", "pwsh.exe"))
		slices.Sort(versions)
		slices.Reverse(versions)
		pwsh = append(pwsh, versions...)
		bash = append(bash, filepath.Join(root, "Git", "bin", "bash.exe"))
		nu = append(nu, filepath.Join(root, "nu", "bin", "nu.exe"), filepath.Join(root, "Nushell", "nu.exe"))
	}
	if root := os.Getenv("LOCALAPPDATA"); root != "" {
		versions, _ := filepath.Glob(filepath.Join(root, "Microsoft", "PowerShell", "*", "pwsh.exe"))
		pwsh = append(pwsh, versions...)
	}
	if home := os.Getenv("USERPROFILE"); home != "" {
		pwsh = append(pwsh, filepath.Join(home, "scoop", "apps", "pwsh", "current", "pwsh.exe"))
		bash = append(bash, filepath.Join(home, "scoop", "apps", "git", "current", "bin", "bash.exe"))
		nu = append(nu, filepath.Join(home, "scoop", "apps", "nu", "current", "nu.exe"))
	}
	if git, err := exec.LookPath("git.exe"); err == nil {
		bash = append(bash, filepath.Join(filepath.Dir(git), "..", "bin", "bash.exe"))
	}
	// Cygwin installs to a root the setup program is told to use, which it
	// records in the registry; the two roots beside the system drive are only
	// the defaults it falls back to. A bare bash.exe on the PATH is deliberately
	// not probed: it could be this Cygwin, Git Bash, or the WSL launcher, and
	// only the path tells them apart (issue #435).
	cygwin := []string{}
	for _, root := range cygwinRecordedRoots() {
		cygwin = append(cygwin, filepath.Join(root, "bin", "bash.exe"))
	}
	if drive := os.Getenv("SystemDrive"); drive != "" {
		cygwin = append(cygwin,
			filepath.Join(drive+string(os.PathSeparator), "cygwin64", "bin", "bash.exe"),
			filepath.Join(drive+string(os.PathSeparator), "cygwin", "bin", "bash.exe"))
	}
	system := filepath.Join(os.Getenv("SystemRoot"), "System32")
	return discoverShells([]shellCandidate{
		{"PowerShell 7", pwsh},
		{"Windows PowerShell", []string{"powershell.exe", filepath.Join(system, "WindowsPowerShell", "v1.0", "powershell.exe")}},
		{"CMD", []string{os.Getenv("COMSPEC"), "cmd.exe", filepath.Join(system, "cmd.exe")}},
		{"Git Bash", bash},
		{"Cygwin", cygwin},
		{"Nushell", nu},
	}, defaultShell(), exec.LookPath)
}
