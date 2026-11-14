package workbench

import (
	"context"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file holds the file operations of the project tree that the menu runs without a dialog
// (matrix id workspace-files): Duplicate copies a file or folder beside itself under a free
// "copy" name. It also holds moveToTrash, which the Delete dialog uses to send items to the
// system's trash, so they can be restored (filetree_batch.go).

// duplicateTreeItem copies the row's file or folder next to it as "<name> copy", "<name> copy 2"
// and so on, and shows the copy in the tree.
func (a *App) duplicateTreeItem(p *project, n *treeNode) {
	language := a.language()
	if n == nil || n == p.tree.root {
		return
	}
	source := filepath.Join(p.root, filepath.FromSlash(n.path))
	dir, base := filepath.Split(source)
	stem, ext := base, ""
	if !n.dir {
		stem, ext = strings.TrimSuffix(base, filepath.Ext(base)), filepath.Ext(base)
	}
	target := ""
	for i := 1; ; i++ {
		name := stem + " copy" + ext
		if i > 1 {
			name = stem + " copy " + strconv.Itoa(i) + ext
		}
		target = filepath.Join(dir, name)
		if _, err := os.Lstat(target); os.IsNotExist(err) {
			break
		}
	}
	if err := copyTreeEntry(source, target); err != nil {
		a.notifyError(i18n.SharedFormat(language, "desktop.files.duplicateFailed", map[string]string{"reason": treeErrorReason(err)}))
		return
	}
	a.performed("workspace.file.duplicate", surfaceMenu)
	rel, _ := filepath.Rel(p.root, dir)
	a.listTree(p, path.Clean(filepath.ToSlash(rel)))
	a.loadGit(p)
}

// copyTreeEntry copies source to target: a file with its mode, a folder with everything in it,
// and a symbolic link as the same link. target must not exist.
func copyTreeEntry(source, target string) error {
	return filepath.WalkDir(source, func(current string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(source, current)
		if err != nil {
			return err
		}
		dest := filepath.Join(target, rel)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		switch {
		case info.Mode()&fs.ModeSymlink != 0:
			link, err := os.Readlink(current)
			if err != nil {
				return err
			}
			return os.Symlink(link, dest)
		case info.IsDir():
			return os.Mkdir(dest, info.Mode().Perm())
		default:
			return copyTreeFile(current, dest, info.Mode().Perm())
		}
	})
}

// copyTreeFile copies the bytes of one regular file to dest with perm, which must not exist.
func copyTreeFile(source, dest string, perm fs.FileMode) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// moveToTrash sends the file or folder at full to the system trash with the platform's own
// command: Finder on macOS, the shell's recycle bin on Windows, and gio where it is available.
// The path is passed as an argument or an environment variable, never spliced into a script.
func moveToTrash(full string) error {
	ctx := context.Background()
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.CommandContext(ctx, "osascript",
			"-e", "on run argv",
			"-e", "tell application \"Finder\" to delete POSIX file (item 1 of argv)",
			"-e", "end run", "--", full)
	case "windows":
		script := "Add-Type -AssemblyName Microsoft.VisualBasic; $p = $env:LITHE_TRASH_PATH; " +
			"if (Test-Path -LiteralPath $p -PathType Container) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin') } " +
			"else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin') }"
		cmd = exec.CommandContext(ctx, "powershell", "-NoProfile", "-NonInteractive", "-Command", script)
		cmd.Env = append(os.Environ(), "LITHE_TRASH_PATH="+full)
	default:
		cmd = exec.CommandContext(ctx, "gio", "trash", "--", full)
	}
	output, err := cmd.CombinedOutput()
	if err != nil {
		if message := strings.TrimSpace(string(output)); message != "" {
			return &trashError{message: message}
		}
		return err
	}
	return nil
}

// trashError is a trash command's own message, shown as the reason.
type trashError struct{ message string }

func (e *trashError) Error() string { return e.message }
