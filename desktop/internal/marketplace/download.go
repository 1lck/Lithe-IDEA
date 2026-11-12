package marketplace

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const (
	// MaxArchiveBytes is the existing marketplace download budget, not the
	// separately enforced limit for files after extraction.
	MaxArchiveBytes = 512 << 20
	archiveTimeout  = 5 * time.Minute
)

var (
	ErrArchiveTooLarge  = errors.New("plugin archive exceeds the download limit")
	ErrArchiveChecksum  = errors.New("plugin archive checksum does not match the marketplace index")
	ErrArchiveSelection = errors.New("marketplace archive selection is not available")
)

// ArchiveDownloader only transfers bytes. A matching checksum identifies the
// index's archive; it does not establish publisher trust or approve execution.
// Its staging root is the operating system's temporary directory, never a
// path derived from the installed application or plugin package.
type ArchiveDownloader struct {
	http          *http.Client
	temporaryRoot string
	maximumBytes  int64
}

func NewArchiveDownloader(client *http.Client) *ArchiveDownloader {
	return newArchiveDownloader(client, os.TempDir())
}

func newArchiveDownloader(client *http.Client, temporaryRoot string) *ArchiveDownloader {
	return &ArchiveDownloader{http: marketplaceHTTPClient(client, archiveTimeout), temporaryRoot: temporaryRoot, maximumBytes: MaxArchiveBytes}
}

// DownloadedArchive owns a private staging directory. The caller must discard
// it after review, cancellation, successful installation, or any later error.
// The path is not an immutable handle: before extraction, the caller must bind
// validation to the bytes it actually reads and guard against replacement.
type DownloadedArchive struct {
	mu        sync.Mutex
	directory string
	path      string
	discarded bool
}

func (a *DownloadedArchive) Path() string { return a.path }

// Discard is idempotent after success and permits retrying a failed cleanup.
func (a *DownloadedArchive) Discard() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.discarded {
		return nil
	}
	if err := os.RemoveAll(a.directory); err != nil {
		return err
	}
	a.discarded = true
	return nil
}

// Download streams the Core-selected archive into a private temporary folder,
// refuses oversized responses while reading, and checks the index digest before
// returning the file. No archive contents are opened or executed here.
func (d *ArchiveDownloader) Download(ctx context.Context, selection core.MarketplaceAvailability) (archive *DownloadedArchive, err error) {
	if selection.Status != "available" || selection.DownloadURL == "" || d.maximumBytes <= 0 {
		return nil, ErrArchiveSelection
	}
	want, err := hex.DecodeString(selection.SHA256)
	if err != nil || len(want) != sha256.Size {
		return nil, ErrArchiveSelection
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, selection.DownloadURL, nil)
	if err != nil {
		return nil, err
	}
	if !strings.EqualFold(request.URL.Scheme, "https") || request.URL.Host == "" || request.URL.User != nil {
		return nil, ErrUnsafeRedirect
	}
	if d.temporaryRoot == "" || !filepath.IsAbs(d.temporaryRoot) {
		return nil, ErrArchiveSelection
	}
	response, err := d.http.Do(request)
	if err != nil {
		return nil, err
	}
	var directory string
	var file *os.File
	defer func() {
		if file != nil {
			err = errors.Join(err, file.Close())
		}
		err = errors.Join(err, response.Body.Close())
		if err != nil && directory != "" {
			err = errors.Join(err, os.RemoveAll(directory))
			archive = nil
		}
	}()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("plugin archive HTTP status %d", response.StatusCode)
	}
	if response.ContentLength > d.maximumBytes {
		return nil, ErrArchiveTooLarge
	}
	directory, err = os.MkdirTemp(d.temporaryRoot, "lithe-plugin-transfer-")
	if err != nil {
		return nil, err
	}
	path := filepath.Join(directory, "archive.zip")
	file, err = os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, err
	}
	hash := sha256.New()
	buffer := make([]byte, 32*1024)
	var received int64
	emptyReads := 0
	for {
		if err = ctx.Err(); err != nil {
			return nil, err
		}
		count, readErr := response.Body.Read(buffer)
		if count > 0 {
			emptyReads = 0
			if int64(count) > d.maximumBytes-received {
				return nil, ErrArchiveTooLarge
			}
			written, writeErr := file.Write(buffer[:count])
			if writeErr != nil {
				return nil, writeErr
			}
			if written != count {
				return nil, io.ErrShortWrite
			}
			hash.Write(buffer[:count]) // hash.Hash.Write never returns an error.
			received += int64(count)
		} else if readErr == nil {
			emptyReads++
			if emptyReads >= 100 {
				return nil, io.ErrNoProgress
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				break
			}
			return nil, readErr
		}
	}
	if err = ctx.Err(); err != nil {
		return nil, err
	}
	if subtle.ConstantTimeCompare(hash.Sum(nil), want) != 1 {
		return nil, ErrArchiveChecksum
	}
	return &DownloadedArchive{directory: directory, path: path}, nil
}
