package pluginpkg

import (
	"archive/zip"
	"context"
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
// directory. The directory may be absent, or present and empty; a directory that
// already holds entries is refused so an extraction never merges into an earlier
// attempt.
//
// On any refusal after the directory is accepted, Extract removes it: the caller
// gives up ownership at that point. A directory that already holds entries is
// refused without being touched.
//
// The archive must carry ManifestFile at its root or directly inside exactly one
// top-level directory, which is then the package's content root. Extract does not
// interpret the manifest, verify a publisher signature, or approve execution;
// those belong to the install review.
//
// A caller that verified a digest must use ExtractReader with the same open handle
// instead: a path can be replaced between two opens, an open file cannot.
func Extract(archivePath, directory string) (Package, error) {
	return ExtractReader(context.Background(), archivePath, directory)
}

// ExtractReader reads an archive the caller already holds open, so that a digest
// checked over the handle is checked over the bytes that are extracted.
//
// Cancelling ctx stops the extraction between entries and inside a single entry's
// copy, so a caller that gave up does not keep a background goroutine reading a
// large archive while the application waits for it to finish.
func ExtractReader(ctx context.Context, archivePath, directory string) (Package, error) {
	file, err := os.Open(archivePath)
	if err != nil {
		return Package{}, fmt.Errorf("%w: %w", ErrNotArchive, err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return Package{}, fmt.Errorf("%w: %w", ErrNotArchive, err)
	}
	if !info.Mode().IsRegular() {
		// A directory, device or named pipe would block or read something else.
		return Package{}, fmt.Errorf("%w: %s is not a regular file", ErrNotArchive, archivePath)
	}
	return ExtractFrom(ctx, file, info.Size(), directory)
}

// ExtractFrom reads an archive through a handle the caller owns, which is what
// binds a verified digest to the bytes that are written.
func ExtractFrom(ctx context.Context, source io.ReaderAt, size int64, directory string) (Package, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	reader, err := zip.NewReader(contextReaderAt{ctx: ctx, source: source}, size)
	if err != nil {
		return Package{}, fmt.Errorf("%w: %w", ErrNotArchive, err)
	}
	return extractEntries(ctx, reader.File, directory)
}

// contextReaderAt stops a read once its context ends.
type contextReaderAt struct {
	ctx    context.Context
	source io.ReaderAt
}

func (r contextReaderAt) ReadAt(p []byte, off int64) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.ReadAt(p, off)
}

// contextReader stops a copy once its context ends.
type contextReader struct {
	ctx    context.Context
	source io.Reader
}

func (r contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.source.Read(p)
}

// archiveMember is one validated ZIP entry whose name is relative to the archive
// root and whose trailing directory separator is gone.
type archiveMember struct {
	entry *zip.File
	name  string
	dir   bool
}

func extractEntries(ctx context.Context, entries []*zip.File, directory string) (pkg Package, err error) {
	if len(entries) > MaxEntries {
		return Package{}, fmt.Errorf("%w: %d entries, limit %d", ErrTooManyEntries, len(entries), MaxEntries)
	}
	if err := ensureEmptyDirectory(directory); err != nil {
		return Package{}, err
	}
	defer func() {
		if err != nil {
			pkg = Package{}
			err = errors.Join(err, os.RemoveAll(directory))
		}
	}()

	// The first pass validates every archive path and entry type before anything
	// is written, and decides which directory is the package's content root. A
	// refusal here therefore also leaves no half-written content behind.
	members := make([]archiveMember, 0, len(entries))
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return Package{}, err
		}
		name := entry.Name
		dir := entry.FileInfo().IsDir()
		if dir {
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
		if !dir && !entry.Mode().IsRegular() {
			return Package{}, fmt.Errorf("%w: %q", ErrSpecialFile, name)
		}
		members = append(members, archiveMember{entry: entry, name: name, dir: dir})
	}
	contentRoot, err := contentRootOf(members)
	if err != nil {
		return Package{}, err
	}

	files := make(map[string]struct{}, len(entries))
	directories := make(map[string]struct{}, len(entries))
	written := make([]File, 0, len(entries))
	var total int64
	manifestWritten := false

	for _, member := range members {
		if err := ctx.Err(); err != nil {
			return Package{}, err
		}
		name := member.name
		if contentRoot != "" {
			if name == contentRoot {
				if !member.dir {
					return Package{}, fmt.Errorf("%w: %q is both the content root and a file", ErrPathConflict, name)
				}
				// The staging directory already is the content root.
				continue
			}
			prefix := contentRoot + "/"
			if !strings.HasPrefix(name, prefix) {
				return Package{}, fmt.Errorf("%w: %q is beside %q", ErrOutsideContentRoot, name, contentRoot)
			}
			name = strings.TrimPrefix(name, prefix)
		}
		key := foldPath(name)
		if member.dir {
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
			if mkErr := os.MkdirAll(target, member.entry.Mode().Perm()|0o700); mkErr != nil {
				return Package{}, mkErr
			}
			continue
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
		file, size, writeErr := writeEntry(ctx, member.entry, directory, name, total)
		if writeErr != nil {
			return Package{}, writeErr
		}
		total += size
		files[key] = struct{}{}
		written = append(written, file)
		if name == ManifestFile {
			manifestWritten = true
		}
	}

	if !manifestWritten {
		return Package{}, ErrManifestMissing
	}
	sort.Slice(written, func(i, j int) bool { return written[i].Path < written[j].Path })
	return Package{ContentRoot: contentRoot, Files: written, Total: total}, nil
}

// contentRootOf reports the single archive-root directory that holds the
// manifest, or "" when the manifest sits at the archive root.
//
// The contract's package layout is <plugin-id>/plugin.json, so a distributed
// archive has one top-level directory. A flat archive is accepted as well for
// packages that were already installable that way. The manifest is located
// first, then the whole archive is checked for a second manifest at any depth:
// a package that carries two candidate manifests is ambiguous even when neither
// would be used, so the host refuses it instead of choosing one.
func contentRootOf(members []archiveMember) (string, error) {
	var manifests []string
	for _, member := range members {
		if member.dir {
			continue
		}
		if strings.EqualFold(pathBase(member.name), ManifestFile) {
			manifests = append(manifests, member.name)
		}
	}
	if len(manifests) == 0 {
		return "", ErrManifestMissing
	}
	if len(manifests) > 1 {
		sort.Strings(manifests)
		return "", fmt.Errorf("%w: %s", ErrManifestAmbiguous, strings.Join(manifests, ", "))
	}
	manifest := manifests[0]
	if manifest == ManifestFile {
		return "", nil
	}
	if pathBase(manifest) != ManifestFile {
		// A spelling difference such as Plugin.json would resolve only on a
		// case-insensitive volume, so the package is not portable.
		return "", fmt.Errorf("%w: %q is not spelled plugin.json", ErrManifestAmbiguous, manifest)
	}
	segments := strings.Split(manifest, "/")
	if len(segments) != 2 {
		return "", fmt.Errorf("%w: %q is not at the archive root or one directory below it", ErrManifestMissing, manifest)
	}
	return segments[0], nil
}

// pathBase returns the last "/"-separated segment of a validated archive path.
func pathBase(name string) string {
	if slash := strings.LastIndexByte(name, '/'); slash >= 0 {
		return name[slash+1:]
	}
	return name
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
func writeEntry(ctx context.Context, entry *zip.File, root, name string, total int64) (File, int64, error) {
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
		if errors.Is(err, fs.ErrExist) {
			// The name already exists although no earlier entry had it: the file
			// system collapsed two spellings the archive treats as distinct, such as
			// two Unicode normalisation forms of one name. Reporting it as a
			// duplicate is clearer than the bare EEXIST.
			return File{}, 0, fmt.Errorf("%w: %q collides with an extracted file", ErrDuplicatePath, name)
		}
		return File{}, 0, err
	}
	written, copyErr := io.Copy(file, io.LimitReader(contextReader{ctx: ctx, source: source}, limit+1))
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

// ensureEmptyDirectory creates directory when it is absent and refuses one that
// already holds entries.
func ensureEmptyDirectory(directory string) error {
	entries, err := os.ReadDir(directory)
	if errors.Is(err, fs.ErrNotExist) {
		return os.Mkdir(directory, 0o700)
	}
	if err != nil {
		return err
	}
	if len(entries) != 0 {
		return fmt.Errorf("%w: %s", ErrStagingNotEmpty, directory)
	}
	return nil
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
