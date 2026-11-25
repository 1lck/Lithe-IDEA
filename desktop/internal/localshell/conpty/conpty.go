// Package conpty carries Microsoft's ConPTY, conpty.dll and OpenConsole.exe (see NOTICE.md),
// inside the Windows client binary and installs it in the user's cache directory, where the
// local terminal loads it in place of the inbox ConPTY.
//
// The resource's lifecycle:
//
//   - Source: the files of this folder, tracked by Git; TestTheConPTYFolderMatchesItsNotice
//     checks them against the hashes in NOTICE.md.
//   - Build: they are compiled into the Windows executable on amd64 and arm64 (go:embed);
//     other builds carry none. Nothing is copied beside the executable, so the installation
//     directory, its code signature and the baseline a differential update is computed
//     from stay exactly as released.
//   - Run time: Install writes the set to <root>\<digest>\ the first time a process starts
//     a terminal. The client owns the folder; it is private to the user and named by the
//     digest of the set, so releases with different sets never write the same folder, and a
//     folder whose DLL another running client has loaded already holds the right bytes and
//     is not rewritten. Older folders stay until the user clears the cache: removing one
//     could break a running client of another release, and each holds about 2.4 MB (x64)
//     or 1.3 MB (arm64).
//
// Note: 为何编进程序并装到用户缓存，见 .agents/notes/implemented/architecture/2026-11-16-windows-bundled-conpty-in-user-cache.md
package conpty

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/atomicfile"
)

// ErrUnavailable means this build carries no ConPTY: only the Windows builds for amd64 and
// arm64 do.
var ErrUnavailable = errors.New("conpty: this build carries no ConPTY")

// DLL is the name of the library Install returns the path of.
const DLL = "conpty.dll"

// file is one file of the set, at its slash-separated path inside the installed folder.
type file struct {
	path string
	data []byte
}

// DefaultRoot is the folder the client installs the ConPTY below: Lithe\conpty in the user's
// cache directory (%LocalAppData% on Windows).
func DefaultRoot() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("conpty: find the cache directory: %w", err)
	}
	return filepath.Join(base, "Lithe", "conpty"), nil
}

// Install makes this build's ConPTY available below root and returns the absolute path of
// its conpty.dll, with the console hosts in the folders beside it where the DLL looks for
// them. Files that already hold the right bytes are kept, so a later start reads them and
// writes nothing; a missing or different file is replaced atomically, and a partial file
// never sits where the DLL would load it.
func Install(root string) (string, error) { return install(root, bundled) }

func install(root string, files []file) (string, error) {
	if len(files) == 0 {
		return "", ErrUnavailable
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("conpty: %w", err)
	}
	dir := filepath.Join(root, digest(files))
	for _, f := range files {
		if err := place(filepath.Join(dir, filepath.FromSlash(f.path)), f.data); err != nil {
			return "", err
		}
	}
	return filepath.Join(dir, DLL), nil
}

// digest names the folder of a set: the first half of a SHA-256 over every file's path,
// length and bytes, in hex.
func digest(files []file) string {
	sum := sha256.New()
	for _, f := range files {
		fmt.Fprintf(sum, "%s\x00%d\x00", f.path, len(f.data))
		sum.Write(f.data)
	}
	return hex.EncodeToString(sum.Sum(nil)[:16])
}

// place installs an immutable resource with the same atomic policy as other
// bundled helpers. Windows already-loaded DLLs can be reused when bytes match.
func place(path string, data []byte) error {
	if err := atomicfile.Install(path, data, 0o700); err != nil {
		return fmt.Errorf("conpty: install %s: %w", filepath.Base(path), err)
	}
	return nil
}
