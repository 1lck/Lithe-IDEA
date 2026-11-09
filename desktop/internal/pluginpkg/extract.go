package pluginpkg

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Extract reads the ZIP archive at archivePath and writes its entries into
// directory. The directory must not exist yet: Extract creates it with owner-only
// permissions and removes it again when any entry is refused, so a failed
// extraction never leaves a partial package behind.
//
// The archive must carry ManifestFile at its root. Extract does not interpret the
// manifest, verify a publisher signature, or approve execution; those belong to
// the install review.
func Extract(archivePath, directory string) (Package, error) {
	reader, err := zip.OpenReader(archivePath)
	if err != nil {
		return Package{}, fmt.Errorf("%w: %w", ErrNotArchive, err)
	}
	defer reader.Close()
	return extractEntries(reader.File, directory)
}

func extractEntries(entries []*zip.File, directory string) (pkg Package, err error) {
	if len(entries) > MaxEntries {
		return Package{}, fmt.Errorf("%w: %d entries, limit %d", ErrTooManyEntries, len(entries), MaxEntries)
	}
	if err := os.Mkdir(directory, 0o700); err != nil {
		return Package{}, err
	}
	defer func() {
		if err != nil {
			pkg = Package{}
			err = errors.Join(err, os.RemoveAll(directory))
		}
	}()

	files := make(map[string]struct{}, len(entries))
	directories := make(map[string]struct{}, len(entries))
	written := make([]File, 0, len(entries))
	var total int64

	for _, entry := range entries {
		name := entry.Name
		if entry.FileInfo().IsDir() {
			// ZIP marks a directory by a trailing separator, which is not part of
			// the path itself.
			name = strings.TrimSuffix(name, "/")
		}
		name, pathErr := ValidatePath(name)
		if pathErr != nil {
			return Package{}, pathErr
		}
		if entry.Mode()&fs.ModeSymlink != 0 {
			return Package{}, fmt.Errorf("%w: %q", ErrSymbolicLink, name)
		}
		key := foldPath(name)
		if entry.FileInfo().IsDir() {
			if _, ok := files[key]; ok {
				return Package{}, fmt.Errorf("%w: %q is also a file", ErrPathConflict, name)
			}
			if err := addParents(name, files, directories); err != nil {
				return Package{}, err
			}
			directories[key] = struct{}{}
			target, targetErr := targetPath(directory, name)
			if targetErr != nil {
				return Package{}, targetErr
			}
			// The owner needs write access to fill the directory even when the
			// package records it as read-only.
			if mkErr := os.MkdirAll(target, entry.Mode().Perm()|0o700); mkErr != nil {
				return Package{}, mkErr
			}
			continue
		}
		if !entry.Mode().IsRegular() {
			return Package{}, fmt.Errorf("%w: %q", ErrSpecialFile, name)
		}
		if _, ok := files[key]; ok {
			return Package{}, fmt.Errorf("%w: %q", ErrDuplicatePath, name)
		}
		if _, ok := directories[key]; ok {
			return Package{}, fmt.Errorf("%w: %q is also a directory", ErrPathConflict, name)
		}
		if err := addParents(name, files, directories); err != nil {
			return Package{}, err
		}
		file, size, writeErr := writeEntry(entry, directory, name, total)
		if writeErr != nil {
			return Package{}, writeErr
		}
		total += size
		files[key] = struct{}{}
		written = append(written, file)
	}

	if _, ok := files[foldPath(ManifestFile)]; !ok {
		return Package{}, ErrManifestMissing
	}
	sort.Slice(written, func(i, j int) bool { return written[i].Path < written[j].Path })
	return Package{Files: written, Total: total}, nil
}

// addParents records the directories name lives in and refuses a path that would
// sit inside a file.
func addParents(name string, files, directories map[string]struct{}) error {
	for _, parent := range parentDirectories(name) {
		if _, ok := files[parent]; ok {
			return fmt.Errorf("%w: %q is inside the file %q", ErrPathConflict, name, parent)
		}
		directories[parent] = struct{}{}
	}
	return nil
}

// writeEntry writes one regular file entry under root and reports what it wrote.
// It trusts no size the archive declares: the declared size only decides whether
// the entry is worth opening, and the copy itself is bounded.
func writeEntry(entry *zip.File, root, name string, total int64) (File, int64, error) {
	declared := int64(entry.UncompressedSize64)
	if declared > MaxFileBytes {
		return File{}, 0, fmt.Errorf("%w: %q declares %d bytes, limit %d", ErrFileTooLarge, name, declared, MaxFileBytes)
	}
	if declared > 0 {
		if entry.CompressedSize64 == 0 {
			return File{}, 0, fmt.Errorf("%w: %q declares %d bytes from nothing", ErrCompressionRatio, name, declared)
		}
		if declared/int64(entry.CompressedSize64) > MaxCompressionRatio {
			return File{}, 0, fmt.Errorf("%w: %q declares %d bytes from %d", ErrCompressionRatio, name, declared, entry.CompressedSize64)
		}
	}
	if total+declared > MaxExtractedBytes {
		return File{}, 0, fmt.Errorf("%w: %q passes the total limit", ErrArchiveTooLarge, name)
	}

	limit := MaxFileBytes
	if remaining := MaxExtractedBytes - total; remaining < limit {
		limit = remaining
	}
	target, err := targetPath(root, name)
	if err != nil {
		return File{}, 0, err
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return File{}, 0, err
	}
	source, err := entry.Open()
	if err != nil {
		return File{}, 0, err
	}
	file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		source.Close()
		return File{}, 0, err
	}
	written, copyErr := io.Copy(file, io.LimitReader(source, limit+1))
	closeErr := file.Close()
	sourceErr := source.Close()
	if copyErr != nil || closeErr != nil || sourceErr != nil {
		return File{}, 0, errors.Join(copyErr, closeErr, sourceErr)
	}
	if written > limit {
		if limit == MaxFileBytes {
			return File{}, 0, fmt.Errorf("%w: %q", ErrFileTooLarge, name)
		}
		return File{}, 0, fmt.Errorf("%w: %q", ErrArchiveTooLarge, name)
	}
	perm := entry.Mode().Perm()
	if perm == 0 {
		// An archive written without permission bits still has to produce a
		// readable file.
		perm = 0o644
	}
	// An installed package is read-only for the host, and an archive written on
	// Windows reports 0666 for every entry. Neither may leave the extracted tree
	// writable by anyone but its owner.
	perm &= 0o755
	if perm&0o400 == 0 {
		perm |= 0o400
	}
	if err := os.Chmod(target, perm); err != nil {
		return File{}, 0, err
	}
	return File{Path: name, Size: written, Mode: perm}, written, nil
}

// targetPath maps a validated package-relative path to an absolute path under
// root. ValidatePath already rejected every escape, so a failure here means the
// two functions disagree and the extraction must stop rather than guess.
func targetPath(root, name string) (string, error) {
	target := filepath.Join(root, filepath.FromSlash(name))
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return "", fmt.Errorf("%w: %q does not resolve inside the package: %w", ErrUnsafePath, name, err)
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("%w: %q resolves outside the package", ErrUnsafePath, name)
	}
	return target, nil
}
