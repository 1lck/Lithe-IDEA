// Package remoteplaceholder gives a remote workspace its local root: the path that names the
// workspace in Core's requests and in the window, and that the local file system can never open,
// list or create (#2231).
//
// Core reads and writes below a remote workspace's local root on the host, and refuses every
// command that has no remote adapter instead of touching the local path. The client still calls the
// operating system with project paths in places that do not go through Core. Every placeholder
// therefore lies below the anchor, a regular read-only file in the user's cache directory, and not
// below a directory. A local call fails with ENOTDIR (ERROR_PATH_NOT_FOUND on Windows) instead of
// reading or creating a local folder that only looks like the project: os.MkdirAll, os.Create and
// os.ReadDir below a file all fail. Core maps a host path outside the workspace to a sibling of the
// local root (<root>.lithe-remote-host), which lies below the anchor too.
//
// The anchor holds no data and is never deleted. It is created on first use and checked on every
// use: a directory, a link or any other kind of file at its path is refused, since a local folder
// below it could be created.
package remoteplaceholder

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"unicode"
)

// AnchorName is the anchor's file name in the client's cache directory.
const AnchorName = "remote-workspaces"

// ErrAnchorUnusable means something other than a regular file is at the anchor's path, so a local
// folder could be created below it; no placeholder is given out until it is removed.
var ErrAnchorUnusable = errors.New("remoteplaceholder: the anchor is not a regular file")

// DefaultAnchor is the anchor of the client: Lithe/remote-workspaces in the user's cache directory.
func DefaultAnchor() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("remoteplaceholder: locate the cache directory: %w", err)
	}
	return filepath.Join(base, "Lithe", AnchorName), nil
}

// Ensure makes sure the anchor is a regular file, creating an empty read-only one when nothing is
// at its path. A link, a directory or any other kind of file there fails with ErrAnchorUnusable
// and is left as it is.
func Ensure(anchor string) error {
	info, err := os.Lstat(anchor)
	if errors.Is(err, fs.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(anchor), 0o700); err != nil {
			return fmt.Errorf("remoteplaceholder: create the cache directory: %w", err)
		}
		file, err := os.OpenFile(anchor, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o444)
		if err == nil {
			return file.Close()
		}
		if !errors.Is(err, fs.ErrExist) {
			return fmt.Errorf("remoteplaceholder: create the anchor: %w", err)
		}
		// Another process created it first: check what it created.
		info, err = os.Lstat(anchor)
	}
	if err != nil {
		return fmt.Errorf("remoteplaceholder: inspect the anchor: %w", err)
	}
	if !info.Mode().IsRegular() {
		return ErrAnchorUnusable
	}
	return nil
}

// Root is the local root of the remote workspace whose host folder is remoteRoot, reached over the
// saved connection connectionID: anchor/<key>/<name>. The key tells apart the same folder over two
// connections and two folders of one name; the name is the folder's own, made safe for every local
// file system, so the window and the tree show it. Opening the same folder over the same
// connection again gives the same root, which is how the window finds it already open.
func Root(anchor, connectionID, remoteRoot string) string {
	sum := sha256.Sum256([]byte(connectionID + "\x00" + remoteRoot))
	return filepath.Join(anchor, hex.EncodeToString(sum[:8]), localName(remoteRoot))
}

// maxNameRunes bounds the local name, which only labels the root.
const maxNameRunes = 64

// localName is the final element of the POSIX path remoteRoot as a file name every local file
// system accepts: "root" for the host's root, letters, digits and "._-" kept, every other
// character replaced by "_".
func localName(remoteRoot string) string {
	base := path.Base(path.Clean("/" + strings.TrimLeft(remoteRoot, "/")))
	if base == "/" {
		return "root"
	}
	var name strings.Builder
	count := 0
	for _, r := range base {
		if count == maxNameRunes {
			break
		}
		count++
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '.' || r == '_' || r == '-' {
			name.WriteRune(r)
			continue
		}
		name.WriteByte('_')
	}
	// Windows drops trailing dots, and "." and ".." are no names at all.
	text := strings.TrimRight(name.String(), ".")
	if text == "" {
		return "folder"
	}
	if reservedOnWindows(text) {
		return "_" + text
	}
	return text
}

// reservedOnWindows says whether name, before any extension, is a device name Windows reserves in
// every directory.
func reservedOnWindows(name string) bool {
	stem := strings.ToUpper(name)
	if dot := strings.IndexByte(stem, '.'); dot >= 0 {
		stem = stem[:dot]
	}
	switch stem {
	case "CON", "PRN", "AUX", "NUL":
		return true
	}
	if len(stem) == 4 && (strings.HasPrefix(stem, "COM") || strings.HasPrefix(stem, "LPT")) {
		return stem[3] >= '0' && stem[3] <= '9'
	}
	return false
}

// HostSuffix is added to a local root to name the sibling Core maps every host path outside the
// workspace to: <root>.lithe-remote-host/<the host path without its leading "/">.
const HostSuffix = ".lithe-remote-host"

// HostPath is the host path local stands for, as Core maps it, in the workspace whose local root
// is root and whose host folder is remoteRoot: a path below root is the same path below
// remoteRoot, and a path below root's sibling (HostSuffix) is the host path it names. ok is false
// for any other path.
func HostPath(root, remoteRoot, local string) (string, bool) {
	if suffix, ok := below(root+HostSuffix, local); ok {
		return path.Join("/", suffix), true
	}
	if suffix, ok := below(root, local); ok {
		return path.Join(remoteRoot, suffix), true
	}
	return "", false
}

// Outside says whether local stands for a host path outside the workspace whose local root is
// root: one below root's sibling (HostSuffix), not below root itself.
func Outside(root, local string) bool {
	_, ok := below(root+HostSuffix, local)
	return ok
}

// LocalPath is the path that stands for host, an absolute host path, in the same workspace: the
// inverse of HostPath. ok is false for a path that is not absolute, and on Windows for one with a
// name holding "\", which would name another path there.
func LocalPath(root, remoteRoot, host string) (string, bool) {
	if !path.IsAbs(host) {
		return "", false
	}
	host = path.Clean(host)
	remote := path.Clean(remoteRoot)
	if host == remote {
		return root, true
	}
	if rest, ok := strings.CutPrefix(host, strings.TrimSuffix(remote, "/")+"/"); ok {
		return joinLocal(root, rest)
	}
	return HostNamedPath(root, host)
}

// HostNamedPath is the path below root's sibling (HostSuffix) that names host, an absolute host
// path, whether or not host lies in the workspace's folder. Core maps it to host as it maps every
// path of the sibling, and so maps the paths Core derives beside it, such as the folder it suggests
// for a new worktree next to the repository, to the host paths beside host. ok is false as for
// LocalPath.
func HostNamedPath(root, host string) (string, bool) {
	if !path.IsAbs(host) {
		return "", false
	}
	return joinLocal(root+HostSuffix, strings.TrimPrefix(path.Clean(host), "/"))
}

// joinLocal is base with the slash-separated suffix below it as a local path; ok is false on
// Windows for a name of suffix holding "\", which would name another path there.
func joinLocal(base, suffix string) (string, bool) {
	if suffix == "" {
		return base, true
	}
	if filepath.Separator != '/' && strings.ContainsRune(suffix, filepath.Separator) {
		return "", false
	}
	return filepath.Join(base, filepath.FromSlash(suffix)), true
}

// below is the slash-separated path of full below dir, "" for dir itself; ok is false for a path
// outside dir.
func below(dir, full string) (string, bool) {
	rel, err := filepath.Rel(dir, full)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	if rel == "." {
		return "", true
	}
	return filepath.ToSlash(rel), true
}
