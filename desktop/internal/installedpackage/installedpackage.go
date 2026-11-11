// Package installedpackage is the only place the client locates its own installed package: the
// macOS app bundle or the Windows installation folder.
//
// That package is part of the release baseline. Its exact bytes carry the code signature, and
// Sparkle builds each differential update against them, so a file written, created, moved or
// removed there at run time breaks the signature and turns the next update into a full download.
// Everything here is therefore read-only. Executable returns the running executable so another
// client can be started from it. ResourceFolder returns a folder of fixed resources that the
// packaging step placed in the bundle, for reading. Neither result may be used as a place to
// write; caches, indexes, logs, downloads and other state belong to the platform's data and
// cache directories. scripts/macos/verify/verify-runtime-bundle-immutability.sh allows package
// lookups only in this package and fails if it ever writes to the file system.
package installedpackage

import (
	"os"
	"path/filepath"
)

// Executable returns the path of the running client executable. Its only use is starting another
// client of the same build; nothing is written beside it.
func Executable() (string, error) {
	return os.Executable()
}

// ResourceFolder returns the folder name inside the Resources of the macOS app bundle the client
// runs from. It returns "" when the client is not running from an app bundle (development builds
// and Windows) or when the bundle has no such folder. The folder is a build-time input and is
// read-only at run time.
func ResourceFolder(name string) string {
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	return resourceFolder(executable, name)
}

// resourceFolder is ResourceFolder for a given executable path.
func resourceFolder(executable, name string) string {
	macos := filepath.Dir(executable)
	contents := filepath.Dir(macos)
	if name == "" || filepath.Base(macos) != "MacOS" || filepath.Base(contents) != "Contents" {
		return ""
	}
	folder := filepath.Join(contents, "Resources", name)
	if info, err := os.Stat(folder); err != nil || !info.IsDir() {
		return ""
	}
	return folder
}
