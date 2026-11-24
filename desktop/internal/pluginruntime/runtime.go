// Package pluginruntime performs native I/O for Core-selected, immutable runtime
// archives. The caller owns dependency selection and plugin validation; this
// package never knows a language, changes a toolchain default, or writes inside
// an installed plugin. Root is the platform's version-independent plugin state.
package pluginruntime

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/atomicfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/filelock"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

const inventoryLimit = 32 << 20

var (
	// ErrCorrupt means recorded runtime contents no longer match their install.
	// Preparing the same artifact repairs it without touching the old generation.
	ErrCorrupt  = errors.New("managed runtime contents are incomplete or changed")
	ErrArtifact = errors.New("managed runtime artifact is not usable")
	ErrArchive  = errors.New("managed runtime archive is not safe to extract")
	ErrBusy     = errors.New("managed runtime preparation is busy")
	// ErrDownload means no URL of the artifact delivered its archive; it wraps the last
	// URL's failure, such as marketplace.ErrArchiveChecksum for bytes that do not match.
	ErrDownload = errors.New("managed runtime archive could not be downloaded")
)

// Artifact is the selected platform artifact returned by Core. All paths are
// slash-separated and relative; Executable is relative to Home. CacheKey binds
// dependency version, platform and archive identity, independently of plugin
// versions. Empty Home means the stripped extraction root.
type Artifact struct {
	ID, Version, CacheKey, URL, SHA256, Archive string
	Mirrors                                     []string
	StripPrefix, Home, Executable               string
}

// Installation names a completed immutable generation. Directory is the
// extraction root, Home the dependency's home, and Executable may be empty.
type Installation struct {
	Directory, Home, Executable string
	Reused                      bool
}

// Progress runs on the I/O worker. A consumer must publish a bounded UI snapshot
// without blocking. Cause is present only when an earlier cache needs repair;
// the owning host boundary records that recovery in its structured log.
type Progress struct {
	ID, Phase       string
	Received, Total int64
	Cause           error
}

// Manager owns no background worker. Root and Downloader must be configured
// before use; multiple managers and processes safely share Root. Generations
// and verified archives survive plugin upgrades and are removed with plugin
// state. Old generations remain readable by running processes and rollback.
type Manager struct {
	Root       string
	Downloader *marketplace.ArchiveDownloader
}

type inventoryEntry struct {
	Path     string `json:"path"`
	Kind     string `json:"kind"`
	Size     int64  `json:"size,omitempty"`
	Modified int64  `json:"modified,omitempty"`
	Mode     uint32 `json:"mode,omitempty"`
	SHA256   string `json:"sha256,omitempty"`
	Link     string `json:"link,omitempty"`
}

type receipt struct {
	CacheKey   string           `json:"cacheKey"`
	SHA256     string           `json:"sha256"`
	Generation string           `json:"generation"`
	Entries    []inventoryEntry `json:"entries"`
}

// Find checks the completion record and complete file inventory without reading
// unchanged file contents. Changed timestamps trigger a checksum check. It is
// suitable for startup, followed by the plugin's version/layout health check.
func (m *Manager) Find(ctx context.Context, artifact Artifact) (Installation, bool, error) {
	return m.find(ctx, artifact, false)
}

// Verify also hashes every recorded file. Installation and update preflight use
// this stronger check; normal language-server startups use Find.
func (m *Manager) Verify(ctx context.Context, artifact Artifact) (Installation, bool, error) {
	return m.find(ctx, artifact, true)
}

func (m *Manager) find(ctx context.Context, artifact Artifact, contents bool) (Installation, bool, error) {
	if err := m.check(artifact); err != nil {
		return Installation{}, false, err
	}
	if err := ctx.Err(); err != nil {
		return Installation{}, false, err
	}
	base := filepath.Join(m.Root, artifact.CacheKey)
	for _, directory := range []string{m.Root, base} {
		info, statErr := os.Lstat(directory)
		if errors.Is(statErr, os.ErrNotExist) {
			return Installation{}, false, nil
		}
		if statErr != nil {
			return Installation{}, false, statErr
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return Installation{}, false, ErrArtifact
		}
	}
	data, err := configfile.Capture(ctx, base, "ready.json", inventoryLimit)
	if err != nil {
		return Installation{}, false, err
	}
	if !data.Exists() {
		return Installation{}, false, nil
	}
	var record receipt
	if err := json.Unmarshal(data.Bytes(), &record); err != nil {
		return Installation{}, false, fmt.Errorf("%w: completion record", ErrCorrupt)
	}
	if record.CacheKey != artifact.CacheKey || record.SHA256 != artifact.SHA256 ||
		!strings.HasPrefix(record.Generation, "install-") || strings.ContainsAny(record.Generation, "/\\") ||
		len(record.Entries) == 0 || len(record.Entries) > maxEntries {
		return Installation{}, false, fmt.Errorf("%w: completion identity", ErrCorrupt)
	}
	if _, err := pluginpkg.ValidatePath(record.Generation); err != nil {
		return Installation{}, false, ErrCorrupt
	}
	directory := filepath.Join(base, record.Generation)
	if err := verifyInventory(ctx, directory, record.Entries, contents); err != nil {
		return Installation{}, false, err
	}
	result, err := installation(directory, artifact)
	result.Reused = true
	return result, err == nil, err
}

// Prepare reuses a verified generation or downloads only the selected missing
// archive, extracts privately, asks the plugin to validate it, and publishes one
// completion record. The callback is required and must not retain the staging
// paths: Prepare returns their final, stable paths after publication.
func (m *Manager) Prepare(ctx context.Context, artifact Artifact, validate func(context.Context, Installation) error, progress func(Progress)) (result Installation, err error) {
	if err := m.check(artifact); err != nil {
		return result, err
	}
	if validate == nil {
		return result, ErrArtifact
	}
	report := func(phase string, cause error) {
		if progress != nil {
			progress(Progress{ID: artifact.ID, Phase: phase, Total: -1, Cause: cause})
		}
	}
	report("checking", nil)
	base, err := m.createRoot(artifact.CacheKey)
	if err != nil {
		return result, err
	}
	unlock, err := filelock.Acquire(ctx, filepath.Join(base, ".lock"))
	if err != nil {
		switch {
		case errors.Is(err, filelock.ErrInvalid):
			err = fmt.Errorf("%w: %w", ErrArtifact, err)
		case errors.Is(err, filelock.ErrBusy):
			err = fmt.Errorf("%w: %w", ErrBusy, err)
		}
		return result, err
	}
	defer func() { err = errors.Join(err, unlock()) }()
	if err := removeAbandoned(ctx, base); err != nil {
		return result, err
	}
	previous, found, checkErr := m.Verify(ctx, artifact)
	if checkErr == nil && found {
		checkErr = validate(ctx, previous)
		if checkErr == nil {
			report("ready", nil)
			return previous, nil
		}
	}
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	if checkErr != nil {
		if !found && !errors.Is(checkErr, ErrCorrupt) {
			return result, checkErr
		}
		report("repairing", checkErr)
	}
	archive, err := m.archive(ctx, artifact, base, progress)
	if err != nil {
		return result, err
	}
	defer func() { err = errors.Join(err, archive.Close()) }()
	staging, err := os.MkdirTemp(base, ".staging-")
	if err != nil {
		return result, err
	}
	defer func() {
		if staging != "" {
			err = errors.Join(err, os.RemoveAll(staging))
		}
	}()
	report("extracting", nil)
	entries, err := extract(ctx, archive, staging, artifact)
	if err != nil {
		return result, err
	}
	report("verifying", nil)
	candidate, err := installation(staging, artifact)
	if err != nil {
		return result, err
	}
	if err := validate(ctx, candidate); err != nil {
		return result, err
	}
	// A validator may execute a probe but must not modify the immutable input.
	if err := verifyInventory(ctx, staging, entries, true); err != nil {
		return result, err
	}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	generation := "install-" + strings.TrimPrefix(filepath.Base(staging), ".staging-")
	finalDirectory := filepath.Join(base, generation)
	if err := os.Rename(staging, finalDirectory); err != nil {
		return result, err
	}
	staging = finalDirectory // Unpublished generation is still this attempt's to remove.
	encoded, err := json.Marshal(receipt{artifact.CacheKey, artifact.SHA256, generation, entries})
	if err != nil {
		return result, err
	}
	snapshot, err := configfile.Capture(ctx, base, "ready.json", inventoryLimit)
	if err != nil {
		return result, err
	}
	committed, err := snapshot.Replace(ctx, encoded, nil)
	if committed {
		staging = ""
	}
	if err != nil {
		return result, err
	}
	result, err = installation(finalDirectory, artifact)
	if err == nil {
		report("ready", nil)
	}
	return result, err
}

func (m *Manager) check(artifact Artifact) error {
	if m == nil || !filepath.IsAbs(m.Root) || filepath.Clean(m.Root) == string(filepath.Separator) {
		return ErrArtifact
	}
	for _, digest := range []string{artifact.CacheKey, artifact.SHA256} {
		bytes, err := hex.DecodeString(digest)
		if err != nil || len(bytes) != sha256.Size || digest != strings.ToLower(digest) {
			return ErrArtifact
		}
	}
	for _, name := range []string{artifact.StripPrefix, artifact.Home, artifact.Executable} {
		if name != "" {
			if _, err := pluginpkg.ValidatePath(name); err != nil {
				return fmt.Errorf("%w: %w", ErrArtifact, err)
			}
		}
	}
	if artifact.Archive != "zip" && artifact.Archive != "tar.gz" {
		return ErrArtifact
	}
	return nil
}

func (m *Manager) createRoot(key string) (_ string, err error) {
	if err := os.MkdirAll(m.Root, 0o700); err != nil {
		return "", err
	}
	info, err := os.Lstat(m.Root)
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", ErrArtifact
	}
	root, err := os.OpenRoot(m.Root)
	if err != nil {
		return "", err
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	if err := root.Mkdir(key, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return "", err
	}
	info, err = root.Lstat(key)
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", ErrArtifact
	}
	return filepath.Join(m.Root, key), nil
}

func installation(directory string, artifact Artifact) (result Installation, err error) {
	result = Installation{Directory: directory, Home: filepath.Join(directory, filepath.FromSlash(artifact.Home))}
	if artifact.Executable != "" {
		result.Executable = filepath.Join(result.Home, filepath.FromSlash(artifact.Executable))
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return Installation{}, fmt.Errorf("%w: %w", ErrCorrupt, err)
	}
	defer func() { err = errors.Join(err, root.Close()) }()
	homeName := filepath.FromSlash(artifact.Home)
	if homeName == "" {
		homeName = "."
	}
	home, err := root.Stat(homeName)
	if err != nil || !home.IsDir() {
		return Installation{}, fmt.Errorf("%w: home directory", ErrCorrupt)
	}
	if artifact.Executable != "" {
		file, err := root.Stat(filepath.Join(filepath.FromSlash(artifact.Home), filepath.FromSlash(artifact.Executable)))
		if err != nil || !file.Mode().IsRegular() {
			return Installation{}, fmt.Errorf("%w: executable", ErrCorrupt)
		}
	}
	return result, nil
}

func removeAbandoned(ctx context.Context, base string) error {
	entries, err := os.ReadDir(base)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if err := ctx.Err(); err != nil {
			return err
		}
		if strings.HasPrefix(entry.Name(), ".staging-") || strings.HasPrefix(entry.Name(), ".archive.") || strings.HasPrefix(entry.Name(), ".archive-") {
			if err := os.RemoveAll(filepath.Join(base, entry.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}

// archive returns one open, verified handle. Extraction reads that exact handle
// rather than reopening a pathname after checking its digest.
func (m *Manager) archive(ctx context.Context, artifact Artifact, base string, progress func(Progress)) (result *os.File, err error) {
	defer func() {
		if err != nil && result != nil {
			err = errors.Join(err, result.Close())
			result = nil
		}
	}()
	path := filepath.Join(base, "archive")
	file, checkErr := openVerified(ctx, path, artifact.SHA256)
	if checkErr == nil {
		return file, nil
	}
	if !errors.Is(checkErr, os.ErrNotExist) && !errors.Is(checkErr, ErrCorrupt) {
		return nil, checkErr
	}
	if progress != nil && errors.Is(checkErr, ErrCorrupt) {
		progress(Progress{ID: artifact.ID, Phase: "repairing", Total: -1, Cause: checkErr})
	}
	download, cleanup, err := m.downloadArchive(ctx, artifact, progress)
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, cleanup()) }()
	source, err := openVerified(ctx, download.Path(), artifact.SHA256)
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, source.Close()) }()
	if err := atomicfile.WriteWithCheck(path, 0o600, func(w io.Writer) error {
		if _, err := io.Copy(w, contextReader{ctx, source}); err != nil {
			return err
		}
		return ctx.Err()
	}, ctx.Err); err != nil {
		return nil, err
	}
	return openVerified(ctx, path, artifact.SHA256)
}

func openVerified(ctx context.Context, path, digest string) (_ *os.File, err error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > marketplace.MaxArchiveBytes {
		return nil, ErrCorrupt
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			err = errors.Join(err, file.Close())
		}
	}()
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !os.SameFile(info, opened) || !opened.Mode().IsRegular() {
		return nil, ErrCorrupt
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, contextReader{ctx, io.LimitReader(file, marketplace.MaxArchiveBytes+1)}); err != nil {
		return nil, err
	}
	if hex.EncodeToString(hash.Sum(nil)) != digest {
		return nil, ErrCorrupt
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	return file, nil
}

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
