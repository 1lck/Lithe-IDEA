// Package pluginpkg turns a downloaded plugin archive into an installed package.
//
// The marketplace layer only transfers bytes: it checks an archive against the
// index digest and never opens it. This package owns the steps that follow, and
// both of them read hostile input.
//
// Extract reads a ZIP archive into a staging directory. It refuses what the
// plugin contract forbids — absolute paths, ".." segments, backslashes, NUL
// bytes and symbolic links — and adds the rules a package needs to survive
// installation on macOS and Windows alike: no Windows device name, no segment
// ending in a dot or a space, no duplicate file path, and no path that is both a
// file and a directory.
//
// Install moves a validated staging directory into the plugin root with a single
// rename, so an interrupted install leaves either nothing or the whole package.
// Uninstall renames a package out of the root before deleting it and never
// touches the plugin's private state directory.
//
// The contract sets no numeric limit for archives, so the budgets below are host
// policy rather than contract values. They exist so that a malformed archive
// cannot exhaust memory or disk, and they are deliberately generous enough for a
// plugin that ships a language server and a JDK.
package pluginpkg

import (
	"errors"
	"io/fs"
)

const (
	// ManifestFile is the declaration every package must carry at its root.
	ManifestFile = "plugin.json"

	// MaxEntries bounds the number of ZIP entries one archive may hold,
	// directories included.
	MaxEntries = 20000

	// MaxPathLength bounds a package-relative path in bytes.
	MaxPathLength = 1024

	// MaxPathDepth bounds the number of segments in a package-relative path.
	MaxPathDepth = 32

	// MaxFileBytes bounds one extracted file. Nothing a plugin ships is expected
	// to approach it; it is a ceiling, not a target.
	MaxFileBytes int64 = 512 << 20

	// MaxExtractedBytes bounds everything one extraction writes. It is larger
	// than MaxArchiveBytes in the marketplace package because an archive of
	// compiled binaries still expands when it is written out.
	MaxExtractedBytes int64 = 2 << 30

	// MaxCompressionRatio bounds how far a single entry may expand. This is the
	// limit that actually stops a decompression bomb; the byte budgets above
	// only stop it from reaching the disk first.
	MaxCompressionRatio = 200
)

var (
	// ErrUnsafePath reports a package path this host refuses to write.
	ErrUnsafePath = errors.New("plugin package path is not allowed")
	// ErrSymbolicLink reports an archive that carries a symbolic link.
	ErrSymbolicLink = errors.New("plugin package contains a symbolic link")
	// ErrSpecialFile reports an entry that is neither a regular file nor a directory.
	ErrSpecialFile = errors.New("plugin package contains a non-regular file")
	// ErrDuplicatePath reports two entries that would land on the same file.
	ErrDuplicatePath = errors.New("plugin package contains a duplicate path")
	// ErrPathConflict reports one path used both as a file and as a directory.
	ErrPathConflict = errors.New("plugin package path is both a file and a directory")
	// ErrTooManyEntries reports an archive over MaxEntries.
	ErrTooManyEntries = errors.New("plugin package has too many entries")
	// ErrFileTooLarge reports an entry over MaxFileBytes.
	ErrFileTooLarge = errors.New("plugin package entry exceeds the file limit")
	// ErrArchiveTooLarge reports an extraction over MaxExtractedBytes.
	ErrArchiveTooLarge = errors.New("plugin package exceeds the extracted size limit")
	// ErrCompressionRatio reports an entry that expands past MaxCompressionRatio.
	ErrCompressionRatio = errors.New("plugin package entry expands past the compression limit")
	// ErrNotArchive reports bytes that are not a readable ZIP archive.
	ErrNotArchive = errors.New("plugin package is not a readable ZIP archive")
	// ErrStagingNotEmpty reports an extraction target that already holds entries.
	ErrStagingNotEmpty = errors.New("plugin package staging directory is not empty")
	// ErrManifestMissing reports an archive without ManifestFile at its root.
	ErrManifestMissing = errors.New("plugin package has no plugin.json at its root")
	// ErrInvalidIdentity reports a plugin ID or version that is not a safe path segment.
	ErrInvalidIdentity = errors.New("plugin identity is not a safe path segment")
	// ErrPackageExists reports an install whose target version is already present.
	ErrPackageExists = errors.New("plugin package is already installed")
	// ErrNotInstalled reports an uninstall whose target is not present.
	ErrNotInstalled = errors.New("plugin package is not installed")
)

// File is one file an extraction wrote.
type File struct {
	// Path is the package-relative path, using "/" as the separator.
	Path string
	// Size is the number of bytes written.
	Size int64
	// Mode is the permission bits the file was given.
	Mode fs.FileMode
}

// Package describes what one extraction wrote.
type Package struct {
	// Files holds every extracted file, ordered by path.
	Files []File
	// Total is the number of bytes written for all files.
	Total int64
}
