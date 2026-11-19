package marketplace

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const (
	// MaxArchiveBytes is the existing marketplace download budget, not the
	// separately enforced limit for files after extraction.
	MaxArchiveBytes = 512 << 20
	// archiveStallTimeout ends a transfer that has delivered nothing for this
	// long. A transfer as a whole has no time limit: a large archive on a slow
	// link still arrives, and the window that started it can cancel it.
	archiveStallTimeout = time.Minute
)

var (
	ErrArchiveTooLarge  = errors.New("plugin archive exceeds the download limit")
	ErrArchiveChecksum  = errors.New("plugin archive checksum does not match the marketplace index")
	ErrArchiveSelection = errors.New("marketplace archive selection is not available")
	// ErrArchiveStalled ends a transfer that delivered nothing for the stall
	// time. The error also matches context.DeadlineExceeded: to the person
	// waiting it is a timeout.
	ErrArchiveStalled = errors.New("plugin archive download stalled")

	// errArchiveSilent is the stall timer's cause for ending a transfer.
	errArchiveSilent = errors.New("plugin archive transfer went silent")
	errUnaskedRange  = errors.New("plugin archive response holds a range that was not asked for")
)

// stallTimer is the part of *time.Timer the stall watch uses.
type stallTimer interface {
	Reset(time.Duration) bool
	Stop() bool
}

// ArchiveDownloader only transfers bytes. A matching checksum identifies the
// index's archive; it does not establish publisher trust or approve execution.
// Its staging root is the operating system's temporary directory, never a
// path derived from the installed application or plugin package.
//
// A transfer has no time limit of its own; one that delivers nothing for the
// stall time ends with ErrArchiveStalled.
type ArchiveDownloader struct {
	http          *http.Client
	temporaryRoot string
	maximumBytes  int64
	stall         time.Duration
	stallTimer    func(time.Duration, func()) stallTimer
}

func NewArchiveDownloader(client *http.Client) *ArchiveDownloader {
	return newArchiveDownloader(client, os.TempDir())
}

func newArchiveDownloader(client *http.Client, temporaryRoot string) *ArchiveDownloader {
	return &ArchiveDownloader{
		http:          marketplaceHTTPClient(client, 0),
		temporaryRoot: temporaryRoot,
		maximumBytes:  MaxArchiveBytes,
		stall:         archiveStallTimeout,
		stallTimer:    func(d time.Duration, f func()) stallTimer { return time.AfterFunc(d, f) },
	}
}

// HTTPClient returns the configured HTTP client (including any proxy or test transport).
func (d *ArchiveDownloader) HTTPClient() *http.Client {
	if d != nil && d.http != nil {
		return d.http
	}
	return marketplaceHTTPClient(nil, 0)
}

// DownloadedArchive owns a private staging directory. The caller must discard
// it after review, cancellation, successful installation, or any later error.
// The path is not an immutable handle: before extraction, the caller must bind
// validation to the bytes it actually reads and guard against replacement.
type DownloadedArchive struct {
	mu        sync.Mutex
	file      *archiveFile
	discarded bool
}

type archiveFile struct {
	mu              sync.Mutex
	directory, path string
	owners          int
}

func (a *DownloadedArchive) Path() string { return a.file.path }

func (a *DownloadedArchive) retain() *DownloadedArchive {
	a.file.mu.Lock()
	defer a.file.mu.Unlock()
	a.file.owners++
	return &DownloadedArchive{file: a.file}
}

// Discard is idempotent after success and permits retrying a failed cleanup.
func (a *DownloadedArchive) Discard() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.discarded {
		return nil
	}
	a.file.mu.Lock()
	defer a.file.mu.Unlock()
	if a.file.owners == 1 {
		if err := os.RemoveAll(a.file.directory); err != nil {
			return err
		}
	}
	a.file.owners--
	a.discarded = true
	return nil
}

// partialArchive is a transfer that was cut off: its staging directory, holding
// the bytes that arrived, and the selection they belong to. Whoever holds one
// continues the transfer from it or removes it.
type partialArchive struct {
	directory, path string
	url, digest     string
}

// matches says the kept bytes are the start of selection's archive.
func (p *partialArchive) matches(selection core.MarketplaceAvailability) bool {
	return selection.Status == "available" && p.url == selection.DownloadURL && p.digest == selection.SHA256
}

func (p *partialArchive) remove() error { return os.RemoveAll(p.directory) }

// Download streams the Core-selected archive into a private temporary folder,
// refuses oversized responses while reading, and checks the index digest before
// returning the file. No archive contents are opened or executed here. A
// transfer that is cut off is removed: only an ArchiveSession continues one.
func (d *ArchiveDownloader) Download(ctx context.Context, selection core.MarketplaceAvailability) (*DownloadedArchive, error) {
	archive, kept, err := d.download(ctx, selection, nil, nil)
	if kept != nil {
		if removeErr := kept.remove(); removeErr != nil {
			err = errors.Join(err, removeErr)
		}
	}
	return archive, err
}

// ArchiveProgress reports transport bytes, not installation completion.
// Total is negative when the server does not provide a content length.
type ArchiveProgress struct{ Received, Total int64 }

// download fetches selection's archive, continuing from the bytes in from when
// it holds the start of the same archive. It owns from, which it continues or
// removes, and returns either the verified archive or, after a transfer that was
// cut off, the bytes that arrived, which the caller continues or removes.
func (d *ArchiveDownloader) download(ctx context.Context, selection core.MarketplaceAvailability, from *partialArchive, progress func(ArchiveProgress)) (*DownloadedArchive, *partialArchive, error) {
	want, err := d.check(selection)
	var staging *archiveTransfer
	if err == nil && from != nil {
		staging, err = resumeArchiveTransfer(from, d.maximumBytes)
		// log-exempt: 预期的缺失：系统清理了临时目录里留下的部分下载，归档从头下载。
		if errors.Is(err, fs.ErrNotExist) {
			staging, err = nil, nil
		}
	}
	if staging == nil && from != nil {
		if removeErr := from.remove(); removeErr != nil {
			err = errors.Join(err, removeErr)
		}
	}
	if err == nil && staging == nil {
		staging, err = newArchiveTransfer(d.temporaryRoot)
	}
	if err != nil {
		return nil, nil, err
	}
	return d.transfer(ctx, selection, want, staging, progress)
}

// check refuses a selection that cannot be downloaded before anything reaches
// the network, and returns the digest its archive must have.
func (d *ArchiveDownloader) check(selection core.MarketplaceAvailability) ([]byte, error) {
	if selection.Status != "available" || selection.DownloadURL == "" || d.maximumBytes <= 0 {
		return nil, ErrArchiveSelection
	}
	want, err := hex.DecodeString(selection.SHA256)
	if err != nil || len(want) != sha256.Size {
		return nil, ErrArchiveSelection
	}
	location, err := url.Parse(selection.DownloadURL)
	if err != nil {
		return nil, err
	}
	if !strings.EqualFold(location.Scheme, "https") || location.Host == "" || location.User != nil {
		return nil, ErrUnsafeRedirect
	}
	if d.temporaryRoot == "" || !filepath.IsAbs(d.temporaryRoot) {
		return nil, ErrArchiveSelection
	}
	return want, nil
}

// transfer fetches what staging lacks of selection's archive and settles
// staging: it becomes the archive when its bytes match want, is kept when the
// transfer was cut off and the bytes that arrived can be continued, and is
// removed otherwise.
func (d *ArchiveDownloader) transfer(ctx context.Context, selection core.MarketplaceAvailability, want []byte, staging *archiveTransfer, progress func(ArchiveProgress)) (archive *DownloadedArchive, kept *partialArchive, err error) {
	cut := false
	defer func() { archive, kept, err = staging.settle(selection, err, cut) }()
	if staging.received > 0 && staging.matches(want) {
		// The transfer was cut off after its last byte: nothing is left to ask for.
		staging.total = staging.received
	} else {
		if cut, err = d.watch(ctx, selection.DownloadURL, staging, progress); err != nil {
			return nil, nil, err
		}
		if !staging.matches(want) {
			return nil, nil, ErrArchiveChecksum
		}
	}
	if progress != nil {
		progress(ArchiveProgress{staging.received, staging.total})
	}
	return nil, nil, nil
}

// watch runs fetch under the stall timer, which is reset whenever something
// arrives: a transfer that delivers nothing for the stall time, from the
// request on, ends with ErrArchiveStalled. The caller's context ending is
// reported as its own error.
func (d *ArchiveDownloader) watch(ctx context.Context, location string, staging *archiveTransfer, progress func(ArchiveProgress)) (cut bool, err error) {
	watched, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	timer := d.stallTimer(d.stall, func() { cancel(errArchiveSilent) })
	defer timer.Stop()
	cut, err = d.fetch(watched, location, staging, progress, func() { timer.Reset(d.stall) })
	if ctxErr := ctx.Err(); ctxErr != nil {
		return cut || err == nil, ctxErr
	}
	if err != nil && errors.Is(context.Cause(watched), errArchiveSilent) {
		return cut, fmt.Errorf("%w: nothing arrived for %s: %w", ErrArchiveStalled, d.stall, context.DeadlineExceeded)
	}
	return cut, err
}

// The ways a response can answer a request for the archive from an offset.
const (
	answerRest  = iota // the bytes from the offset on
	answerWhole        // the whole archive
	answerAgain        // neither: the whole archive has to be asked for
)

// fetch reads into staging what it lacks of the archive at location: the bytes
// after those it holds, or the whole archive when the host does not serve that
// range. alive is called whenever something arrives. When fetch fails, it
// also says whether the bytes staging holds are sound, so the transfer can
// continue from them.
func (d *ArchiveDownloader) fetch(ctx context.Context, location string, staging *archiveTransfer, progress func(ArchiveProgress), alive func()) (bool, error) {
	// answerAgain only answers a request for a range, and starting over drops
	// the range, so this asks for the archive twice at most.
	for {
		from := staging.received
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, location, nil)
		if err != nil {
			return false, err
		}
		if from > 0 {
			request.Header.Set("Range", "bytes="+strconv.FormatInt(from, 10)+"-")
		}
		response, err := d.http.Do(request)
		if err != nil {
			return !errors.Is(err, ErrUnsafeRedirect), err
		}
		alive()
		kind, total, err := d.answer(response, from)
		var status statusError
		cut := errors.As(err, &status) && status.temporary()
		if err == nil && kind != answerRest {
			err = staging.startOver()
		}
		if err == nil && kind != answerAgain {
			staging.total = total
			cut, err = d.receive(ctx, response.Body, staging, progress, alive)
		}
		if closeErr := response.Body.Close(); closeErr != nil {
			cut, err = false, errors.Join(err, closeErr)
		}
		if err != nil || kind != answerAgain {
			return cut, err
		}
	}
}

// answer says what response holds, asked for the archive from offset from, and
// the length of the whole archive, negative when it is not known.
func (d *ArchiveDownloader) answer(response *http.Response, from int64) (kind int, total int64, err error) {
	switch {
	case response.StatusCode == http.StatusPartialContent:
		start, length, ok := contentRange(response.Header.Get("Content-Range"))
		if !ok || start != from {
			if from > 0 {
				return answerAgain, 0, nil
			}
			return 0, 0, errUnaskedRange
		}
		kind, total = answerRest, length
		if total < 0 && response.ContentLength >= 0 {
			total = from + response.ContentLength
		}
	case response.StatusCode == http.StatusRequestedRangeNotSatisfiable && from > 0:
		return answerAgain, 0, nil
	case response.StatusCode >= 200 && response.StatusCode < 300:
		kind, total, from = answerWhole, response.ContentLength, 0
	default:
		return 0, 0, statusError(response.StatusCode)
	}
	if response.ContentLength > d.maximumBytes-from || total > d.maximumBytes {
		return 0, 0, ErrArchiveTooLarge
	}
	return kind, total, nil
}

// contentRange returns the first byte a 206 response's Content-Range names and
// the length of the whole archive, negative when the host gives it as "*".
func contentRange(header string) (start, length int64, ok bool) {
	spec, found := strings.CutPrefix(header, "bytes ")
	span, size, cut := strings.Cut(spec, "/")
	first, _, dash := strings.Cut(span, "-")
	if !found || !cut || !dash {
		return 0, 0, false
	}
	start, err := strconv.ParseInt(first, 10, 64)
	if err != nil || start < 0 {
		return 0, 0, false
	}
	if size == "*" {
		return start, -1, true
	}
	length, err = strconv.ParseInt(size, 10, 64)
	if err != nil || length <= start {
		return 0, 0, false
	}
	return start, length, true
}

// statusError is an HTTP status that is not the archive.
type statusError int

func (e statusError) Error() string { return fmt.Sprintf("plugin archive HTTP status %d", int(e)) }

// temporary says the host may serve the archive again soon, so the bytes a
// transfer kept are still worth continuing.
func (e statusError) temporary() bool {
	switch int(e) {
	case http.StatusRequestTimeout, http.StatusTooManyRequests, http.StatusInternalServerError,
		http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return true
	}
	return false
}

// receive appends body to staging. When it fails, cut says the bytes written
// are sound: the body ended early, rather than being refused or not written.
func (d *ArchiveDownloader) receive(ctx context.Context, body io.Reader, staging *archiveTransfer, progress func(ArchiveProgress), alive func()) (cut bool, err error) {
	buffer := make([]byte, 32*1024)
	if progress != nil {
		progress(ArchiveProgress{staging.received, staging.total})
	}
	lastProgress := time.Now()
	emptyReads := 0
	for {
		if err := ctx.Err(); err != nil {
			return true, err
		}
		count, readErr := body.Read(buffer)
		if count > 0 {
			alive()
			emptyReads = 0
			if int64(count) > d.maximumBytes-staging.received {
				return false, ErrArchiveTooLarge
			}
			if err := staging.write(buffer[:count]); err != nil {
				return false, err
			}
			if progress != nil && time.Since(lastProgress) >= 100*time.Millisecond {
				progress(ArchiveProgress{staging.received, staging.total})
				lastProgress = time.Now()
			}
		} else if readErr == nil {
			emptyReads++
			if emptyReads >= 100 {
				return true, io.ErrNoProgress
			}
		}
		if errors.Is(readErr, io.EOF) {
			return false, nil
		}
		if readErr != nil {
			return true, readErr
		}
	}
}

// archiveTransfer is the staging file of one transfer: the bytes written so
// far, their hash, and the archive's length, negative when it is not known.
type archiveTransfer struct {
	directory, path string
	file            *os.File
	hash            hash.Hash
	received, total int64
}

// newArchiveTransfer creates a private staging directory under root.
func newArchiveTransfer(root string) (*archiveTransfer, error) {
	directory, err := os.MkdirTemp(root, "lithe-plugin-transfer-")
	if err != nil {
		return nil, err
	}
	path := filepath.Join(directory, "archive.zip")
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, errors.Join(err, os.RemoveAll(directory))
	}
	return &archiveTransfer{directory: directory, path: path, file: file, hash: sha256.New(), total: -1}, nil
}

// resumeArchiveTransfer reopens the bytes a cut-off transfer kept and hashes
// them, so the rest is appended to them.
func resumeArchiveTransfer(kept *partialArchive, limit int64) (*archiveTransfer, error) {
	file, err := os.OpenFile(kept.path, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	hash := sha256.New()
	received, err := io.Copy(hash, io.LimitReader(file, limit+1))
	if err == nil && received > limit {
		err = ErrArchiveTooLarge
	}
	if err != nil {
		return nil, errors.Join(err, file.Close())
	}
	return &archiveTransfer{directory: kept.directory, path: kept.path, file: file, hash: hash, received: received, total: -1}, nil
}

func (t *archiveTransfer) write(chunk []byte) error {
	written, err := t.file.Write(chunk)
	if err == nil && written != len(chunk) {
		err = io.ErrShortWrite
	}
	if err != nil {
		return err
	}
	t.hash.Write(chunk) // hash.Hash.Write never returns an error.
	t.received += int64(len(chunk))
	return nil
}

// startOver drops the bytes written so far, for a host that sends the whole
// archive again.
func (t *archiveTransfer) startOver() error {
	if err := t.file.Truncate(0); err != nil {
		return err
	}
	if _, err := t.file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	t.hash.Reset()
	t.received = 0
	return nil
}

func (t *archiveTransfer) matches(want []byte) bool {
	return subtle.ConstantTimeCompare(t.hash.Sum(nil), want) == 1
}

// settle closes the staging file of a transfer that ended with err. Its
// directory becomes the archive when err is nil, is kept for the transfer to
// continue when cut says its bytes are sound, and is removed otherwise.
func (t *archiveTransfer) settle(selection core.MarketplaceAvailability, err error, cut bool) (*DownloadedArchive, *partialArchive, error) {
	if closeErr := t.file.Close(); closeErr != nil {
		cut, err = false, errors.Join(err, closeErr)
	}
	switch {
	case err == nil:
		return &DownloadedArchive{file: &archiveFile{directory: t.directory, path: t.path, owners: 1}}, nil, nil
	case cut && t.received > 0:
		return nil, &partialArchive{directory: t.directory, path: t.path, url: selection.DownloadURL, digest: selection.SHA256}, err
	}
	if removeErr := os.RemoveAll(t.directory); removeErr != nil {
		err = errors.Join(err, removeErr)
	}
	return nil, nil, err
}
