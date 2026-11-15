package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
	"unicode"

	"github.com/vivaui/viva/app"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell"
)

// This file pastes a picture into a terminal (matrix id terminal-interaction). A paste that finds
// a picture and no text on the clipboard saves the picture as a PNG file private to the user and
// types the file's path at the prompt, the way a dropped file is typed, so a program such as Codex
// or Claude Code reads the picture from there. A clipboard with neither keeps the empty paste
// termview sends, which programs that read the clipboard themselves wait for.
//
// The files live in the user's cache directory (Library/Caches on macOS, %LocalAppData% on
// Windows), in a folder only the user can read, and never in the application bundle or the
// installation directory, so code signing and update deltas do not see them. The window owns
// them: each paste writes one, and removes the ones older than terminalPasteKeep, which gives the
// program that was handed a path a week to read it. Ported from motty fe2570d9 and ed6db385, for
// local terminals.

const (
	// terminalPasteKeep is how long a pasted picture stays; the next paste removes older ones.
	terminalPasteKeep = 7 * 24 * time.Hour
	// terminalPasteTimeout bounds saving one picture.
	terminalPasteTimeout = 30 * time.Second
)

// terminalPasteDirectory is where pasted pictures are saved: the user's cache directory.
func terminalPasteDirectory() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "Lithe", "terminal-paste"), nil
}

// pasteTerminalImage takes over a paste into t that found no text when the clipboard holds a
// picture, and reports whether it did; false leaves the paste as it was (termview's
// Config.PasteImage). The clipboard is read when the paste is asked for and not before, as
// asking the program that owns it what it holds is not free.
func (a *App) pasteTerminalImage(p *project, t *terminal) bool {
	if t.pastingImage {
		// One picture at a time: the path of a second one typed while the first is saved
		// would come first, or in the middle of what the user types next.
		return true
	}
	read := a.clipboardImage
	if read == nil {
		read = app.ClipboardImagePNG
	}
	data, err := read()
	switch {
	case errors.Is(err, app.ErrNoImage), errors.Is(err, app.ErrUnsupported):
		return false
	case errors.Is(err, app.ErrTooLarge):
		a.notifyError(a.text.Terminal.PasteImageTooLarge)
		return true
	case err != nil:
		a.operationFailed("terminal_paste_image", err)
		a.notifyError(a.text.Terminal.PasteImageFailed(err.Error()))
		return true
	}
	t.pastingImage = true
	directory := a.pasteDirectory
	if directory == nil {
		directory = terminalPasteDirectory
	}
	distro, _ := localshell.WSLDistro(t.shell)
	now := a.now()
	a.background(p, terminalPasteTimeout, func(context.Context) func(*App) {
		path, err := savePastedImage(directory, data, now)
		return func(a *App) { a.finishTerminalImage(p, t, path, distro, err) }
	})
	return true
}

// finishTerminalImage types the path of a saved picture into the terminal it was pasted in, or
// says why there is none. A terminal closed in the meantime gets nothing; its picture goes with
// the next paste's tidying.
func (a *App) finishTerminalImage(p *project, t *terminal, path, distro string, err error) {
	t.pastingImage = false
	if p.terms.find(t.id) != t {
		return
	}
	if err != nil {
		a.operationFailed("terminal_paste_image", documentLogError(err))
		a.notifyError(a.text.Terminal.PasteImageFailed(err.Error()))
		return
	}
	// A space follows, as it does when a file is dropped on a terminal, so the next word typed
	// is not part of the path.
	t.view.Paste(quotePastedPath(path, distro, runtime.GOOS) + " ")
}

// savePastedImage writes png to a new file of its own in the folder directory names and
// returns the file's path. The folder and the file are private to the user, and the other
// pasted pictures there older than terminalPasteKeep are removed.
func savePastedImage(directory func() (string, error), png []byte, now time.Time) (string, error) {
	folder, err := directory()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return "", err
	}
	// A folder made before, by hand or by an older build, is made private too.
	if err := os.Chmod(folder, 0o700); err != nil {
		return "", err
	}
	file, err := os.CreateTemp(folder, "paste-"+now.Format("20060102-150405")+"-*.png")
	if err != nil {
		return "", err
	}
	name := file.Name()
	_, err = file.Write(png)
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(name)
		return "", err
	}
	prunePastedImages(folder, filepath.Base(name), now)
	return name, nil
}

// prunePastedImages removes the pasted pictures in folder older than terminalPasteKeep, all but
// keep, the one just written. Tidying is a courtesy: the paste has worked whether or not it does.
func prunePastedImages(folder, keep string, now time.Time) {
	entries, err := os.ReadDir(folder)
	if err != nil {
		return
	}
	cutoff := now.Add(-terminalPasteKeep)
	for _, entry := range entries {
		name := entry.Name()
		if name == keep || !entry.Type().IsRegular() || !strings.HasPrefix(name, "paste-") || !strings.HasSuffix(name, ".png") {
			continue
		}
		if info, err := entry.Info(); err == nil && info.ModTime().Before(cutoff) {
			_ = os.Remove(filepath.Join(folder, name))
		}
	}
}

// quotePastedPath writes path so the terminal's shell takes it as one word. In a WSL terminal
// it is the path as the distribution names it, quoted for a POSIX shell; on Windows it is in
// double quotes, which cmd.exe, PowerShell and Git Bash all read; elsewhere a backslash goes
// before every character that is not a plain path character, as Terminal and iTerm2 type a
// dropped file.
func quotePastedPath(path, distro, goos string) string {
	switch {
	case distro != "":
		if linux, ok := localshell.WSLPath(path, distro); ok {
			path = linux
		}
		return "'" + strings.ReplaceAll(path, "'", `'\''`) + "'"
	case goos == "windows":
		return `"` + strings.ReplaceAll(path, `"`, `""`) + `"`
	}
	var out strings.Builder
	for _, r := range path {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && !strings.ContainsRune("/._-+:@%,=~", r) {
			out.WriteByte('\\')
		}
		out.WriteRune(r)
	}
	return out.String()
}
