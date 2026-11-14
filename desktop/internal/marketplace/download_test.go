package marketplace

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func archiveSelection(body string) core.MarketplaceAvailability {
	digest := sha256.Sum256([]byte(body))
	return core.MarketplaceAvailability{Status: "available", DownloadURL: "https://plugins.example.test/archive.zip", SHA256: hex.EncodeToString(digest[:])}
}

func archiveClient(body string, length int64) *http.Client {
	return &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), ContentLength: length, Request: request}, nil
	})}
}

func assertArchiveRootEmpty(t *testing.T, root string) {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("temporary transfer remains: %v", entries)
	}
}

func TestArchiveDownloadMatchesChecksumAndCleansUp(t *testing.T) {
	root := t.TempDir()
	const body = "archive contents"
	d := newArchiveDownloader(archiveClient(body, int64(len(body))), root)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	archive, err := d.Download(ctx, archiveSelection(body))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := archive.Discard(); err != nil {
			t.Error(err)
		}
	})
	if filepath.Dir(filepath.Dir(archive.Path())) != root {
		t.Fatalf("archive outside temporary root: %s", archive.Path())
	}
	data, err := os.ReadFile(archive.Path())
	if err != nil || string(data) != body {
		t.Fatalf("archive bytes = %q, error = %v", data, err)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(filepath.Dir(archive.Path()))
		if err != nil || info.Mode().Perm() != 0o700 {
			t.Fatalf("temporary directory permissions = %v, error = %v", info, err)
		}
	}
	if err := archive.Discard(); err != nil {
		t.Fatal(err)
	}
	if err := archive.Discard(); err != nil {
		t.Fatal(err)
	}
	assertArchiveRootEmpty(t, root)
}

func TestArchiveDownloadRejectsMismatchAndOversize(t *testing.T) {
	for _, tc := range []struct {
		name, body, expected string
		length, limit        int64
		want                 error
	}{
		{"checksum", "wrong bytes", "expected bytes", -1, 100, ErrArchiveChecksum},
		{"declared size", "small", "small", 101, 100, ErrArchiveTooLarge},
		{"streamed size", "0123456789", "0123456789", -1, 4, ErrArchiveTooLarge},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			d := newArchiveDownloader(archiveClient(tc.body, tc.length), root)
			d.maximumBytes = tc.limit
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			archive, err := d.Download(ctx, archiveSelection(tc.expected))
			if archive != nil || !errors.Is(err, tc.want) {
				t.Fatalf("archive = %v, error = %v, want %v", archive, err, tc.want)
			}
			assertArchiveRootEmpty(t, root)
		})
	}
}

func TestArchiveDownloadRejectsUnsafeRedirectAndBodyCloseFailure(t *testing.T) {
	root := t.TempDir()
	client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusFound, Header: http.Header{"Location": []string{"http://plugins.example.test/archive.zip"}}, Body: io.NopCloser(strings.NewReader("")), Request: request}, nil
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := newArchiveDownloader(client, root).Download(ctx, archiveSelection("anything"))
	if !errors.Is(err, ErrUnsafeRedirect) {
		t.Fatalf("redirect error = %v", err)
	}
	assertArchiveRootEmpty(t, root)
	client.Transport = transportFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: failingCloseBody{strings.NewReader("body")}, Request: request}, nil
	})
	archive, err := newArchiveDownloader(client, root).Download(ctx, archiveSelection("body"))
	if archive != nil || !errors.Is(err, errCloseBody) {
		t.Fatalf("archive = %v, error = %v", archive, err)
	}
	assertArchiveRootEmpty(t, root)
}

func TestArchiveDownloadRejectsInvalidSelectionBeforeNetwork(t *testing.T) {
	root := t.TempDir()
	client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		t.Fatal("invalid selection reached the network")
		return nil, errors.New("unexpected request")
	})}
	valid := archiveSelection("body")
	for _, selection := range []core.MarketplaceAvailability{
		{Status: "unsupported", DownloadURL: valid.DownloadURL, SHA256: valid.SHA256},
		{Status: "available", DownloadURL: valid.DownloadURL, SHA256: "not-a-digest"},
		{Status: "available", DownloadURL: "http://plugins.example.test/archive.zip", SHA256: valid.SHA256},
		{Status: "available", DownloadURL: "https://user@plugins.example.test/archive.zip", SHA256: valid.SHA256},
	} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		archive, err := newArchiveDownloader(client, root).Download(ctx, selection)
		cancel()
		if archive != nil || !(errors.Is(err, ErrArchiveSelection) || errors.Is(err, ErrUnsafeRedirect)) {
			t.Fatalf("archive = %v, error = %v", archive, err)
		}
	}
	assertArchiveRootEmpty(t, root)
}

type cancelledArchiveBody struct {
	ctx     context.Context
	started chan struct{}
	sent    bool
}

func (b *cancelledArchiveBody) Read(buffer []byte) (int, error) {
	if !b.sent {
		b.sent = true
		return copy(buffer, "partial"), nil
	}
	close(b.started)
	<-b.ctx.Done()
	return 0, b.ctx.Err()
}
func (*cancelledArchiveBody) Close() error { return nil }

func TestArchiveDownloadCancellationRemovesPartialFile(t *testing.T) {
	root := t.TempDir()
	started := make(chan struct{})
	client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: &cancelledArchiveBody{ctx: request.Context(), started: started}, ContentLength: -1, Request: request}, nil
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	result := make(chan error, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, err := newArchiveDownloader(client, root).Download(ctx, archiveSelection("expected"))
		result <- err
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("download goroutine did not exit during cleanup")
		}
	})
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("download did not start before the deadline")
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 1 {
		t.Fatalf("partial transfer directory = %v, error = %v", entries, err)
	}
	partial, err := os.ReadFile(filepath.Join(root, entries[0].Name(), "archive.zip"))
	if err != nil || string(partial) != "partial" {
		t.Fatalf("partial transfer = %q, error = %v", partial, err)
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancellation error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled download did not stop")
	}
	assertArchiveRootEmpty(t, root)
}
