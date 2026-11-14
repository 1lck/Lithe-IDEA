package marketplace

import (
	"context"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// ArchiveSession owns the settings window's last downloaded file. This native
// file lease avoids transferring identical Core-selected bytes again after a
// cancelled review. It retains at most one MaxArchiveBytes archive on disk, no
// archive bytes in memory, and no resources in the installed application.
// Every borrower must still verify the archive it opens before extraction.
type ArchiveSession struct {
	mu         sync.Mutex
	downloader *ArchiveDownloader
	archive    *DownloadedArchive
	digest     string
	url        string
	closed     bool
}

func NewArchiveSession(client *ArchiveDownloader) *ArchiveSession {
	if client == nil {
		client = NewArchiveDownloader(nil)
	}
	return &ArchiveSession{downloader: client}
}

// Download serializes file ownership with Close. Transfer cancellation belongs
// to the calling window; closing a session cannot remove a borrower's file.
func (s *ArchiveSession) Download(ctx context.Context, selection core.MarketplaceAvailability, progress func(ArchiveProgress)) (*DownloadedArchive, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if s.closed {
		return nil, context.Canceled
	}
	if selection.Status == "available" && s.archive != nil && s.digest == selection.SHA256 && s.url == selection.DownloadURL {
		return s.archive.retain(), nil
	}
	if err := s.forget(); err != nil {
		return nil, err
	}
	archive, err := s.downloader.DownloadWithProgress(ctx, selection, progress)
	if err != nil {
		return nil, err
	}
	s.archive, s.digest, s.url = archive, selection.SHA256, selection.DownloadURL
	return archive.retain(), nil
}

// Forget releases a failed preparation's retained file so a retry fetches new
// bytes. Existing borrowers retain ownership until their own Discard calls.
func (s *ArchiveSession) Forget(archive *DownloadedArchive) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.archive == nil || s.archive.file != archive.file {
		return nil
	}
	return s.forget()
}

func (s *ArchiveSession) forget() error {
	if s.archive != nil {
		if err := s.archive.Discard(); err != nil {
			return err
		}
		s.archive, s.digest, s.url = nil, "", ""
	}
	return nil
}

// Close is idempotent and releases the window's retained temporary file. The
// final borrower performs physical cleanup when it finishes preparation.
func (s *ArchiveSession) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	return s.forget()
}
