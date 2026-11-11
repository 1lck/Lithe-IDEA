package workbench

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/shellkind"
	"github.com/1lck/Lithe-IDEA/desktop/internal/wslpath"
	"github.com/vivaui/viva/gfx"
)

// Paths go into a terminal by dragging (matrix id file-explorer-copy-path-for-terminal): a project
// tree row dropped on a terminal, or files dropped on it from the system, are pasted at its prompt
// as absolute paths quoted for the shell it runs, separated by spaces. They are pasted, not typed
// and run: a shell that asked for bracketed paste inserts them without executing anything, and the
// quoting keeps characters such as $() ` & | ; < > from meaning anything to the shell either way.

// terminalTreeAccept says whether a tree row can be dropped on the terminal of target.
func (a *App) terminalTreeAccept(source, target gfx.ID) bool {
	p := a.project
	if p == nil {
		return false
	}
	_, row := p.tree.rowRefs[source]
	return row && a.focusedTerminalTab(target) != nil
}

// terminalTreeDrop pastes the dropped tree row's absolute path into the terminal.
func (a *App) terminalTreeDrop(source, target gfx.ID) {
	p := a.project
	if p == nil {
		return
	}
	ref, ok := p.tree.rowRefs[source]
	t := a.focusedTerminalTab(target)
	if !ok || t == nil {
		return
	}
	a.performed("terminal.dropPath", surfaceMenu)
	a.pasteTerminalPaths(t, []string{filepath.Join(p.root, filepath.FromSlash(ref.path))})
}

// terminalFileDrop takes files the system drops on a terminal; it reports false for a drop
// elsewhere.
func (a *App) terminalFileDrop(event gfx.FileDropEvent) (gfx.EventResult, bool) {
	t := a.focusedTerminalTab(event.Target)
	if t == nil {
		return gfx.EventResult{}, false
	}
	switch event.Phase {
	case gfx.FileDropOver:
		return gfx.EventResult{Handled: true}, true
	case gfx.FileDropDrop:
		if len(event.Paths) > 0 {
			a.performed("terminal.dropPath", surfaceMenu)
			a.pasteTerminalPaths(t, event.Paths)
			return gfx.EventResult{Handled: true, Repaint: true}, true
		}
	}
	return gfx.EventResult{}, true
}

// pasteTerminalPaths pastes paths, quoted for the terminal's shell, followed by a space.
func (a *App) pasteTerminalPaths(t *terminal, paths []string) {
	program := t.shell
	if program == "" {
		program = loginShellProgram()
	}
	kind := shellkind.FromProgram(program)
	wsl := strings.HasPrefix(t.shell, "wsl:")
	quoted := make([]string, 0, len(paths))
	for _, path := range paths {
		if wsl {
			if location, ok := wslpath.Parse(path); ok {
				path = location.Linux
			} else if converted, ok := windowsPathInWSL(path); ok {
				path = converted
			}
		}
		quoted = append(quoted, quoteShellPath(kind, path))
	}
	if t.view.Paste(strings.Join(quoted, " ") + " ") {
		a.focusTerminal(t.id)
	}
}

// loginShellProgram is the program a terminal with no shell asked for runs: the login shell on
// Unix, PowerShell or the command interpreter on Windows (as localshell picks it).
func loginShellProgram() string {
	if runtime.GOOS != "windows" {
		return os.Getenv("SHELL")
	}
	for _, name := range []string{"pwsh", "powershell"} {
		if path, err := exec.LookPath(name); err == nil {
			return path
		}
	}
	return "cmd.exe"
}

// windowsPathInWSL is a Windows drive path as WSL mounts it: C:\a\b is /mnt/c/a/b.
func windowsPathInWSL(path string) (string, bool) {
	if len(path) < 3 || path[1] != ':' || (path[2] != '\\' && path[2] != '/') {
		return "", false
	}
	drive := strings.ToLower(path[:1])
	if drive[0] < 'a' || drive[0] > 'z' {
		return "", false
	}
	return "/mnt/" + drive + strings.ReplaceAll(path[2:], `\`, "/"), true
}

// quoteShellPath quotes path so the shell reads it as one word with nothing in it expanded.
func quoteShellPath(kind shellkind.Kind, path string) string {
	switch kind {
	case shellkind.PowerShell:
		// In single quotes PowerShell expands nothing; a quote, straight or curly (it takes
		// U+2018 to U+201B as quotes too), is written twice.
		var b strings.Builder
		b.WriteByte('\'')
		for _, r := range path {
			if r == '\'' || (r >= '\u2018' && r <= '\u201B') {
				b.WriteRune(r)
			}
			b.WriteRune(r)
		}
		b.WriteByte('\'')
		return b.String()
	case shellkind.Cmd:
		// A Windows path cannot hold a double quote; % is doubled so it expands nothing, and the
		// other specials (& | < > ^ ( )) are inert inside double quotes.
		return `"` + strings.ReplaceAll(path, "%", "%%") + `"`
	case shellkind.Nushell:
		// A raw string takes everything literally; enough # make its end unique.
		hashes := "#"
		for strings.Contains(path, "'"+hashes) {
			hashes += "#"
		}
		return "r" + hashes + "'" + path + "'" + hashes
	case shellkind.Fish:
		// Fish single quotes take \\ and \' as escapes and nothing else.
		return "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(path) + "'"
	}
	// POSIX shells: single quotes expand nothing; a quote closes, is escaped and reopens.
	return "'" + strings.ReplaceAll(path, "'", `'\''`) + "'"
}
