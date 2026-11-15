// Package installedpackage is the only place the client locates its own installed package: the
// macOS app bundle or the Windows installation folder.
//
// That package is part of the release baseline. Its exact bytes carry the code signature, and
// Sparkle builds each differential update against them, so a file written, created, moved or
// removed there at run time breaks the signature and turns the next update into a full download.
// Everything here is therefore read-only. Executable returns the running executable so another
// client can be started from it; it is never a place to write. Caches, indexes, logs, downloads
// and other state belong to the platform's data and cache directories, and fixed resources the
// client needs at run time are compiled into the executable rather than read from the package.
// scripts/macos/verify/verify-runtime-bundle-immutability.sh allows package lookups only in this
// package and fails if it ever writes to the file system.
package installedpackage

import "os"

// Executable returns the path of the running client executable. Its only use is starting another
// client of the same build; nothing is written beside it.
func Executable() (string, error) {
	return os.Executable()
}
