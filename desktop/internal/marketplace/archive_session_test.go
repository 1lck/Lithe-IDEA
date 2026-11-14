package marketplace

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestArchiveSessionReusesTheLastVerifiedTransfer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root := t.TempDir()
	requests := 0
	body := "first package"
	client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		requests++
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), ContentLength: int64(len(body)), Request: request}, nil
	})}
	session := NewArchiveSession(newArchiveDownloader(client, root))
	t.Cleanup(func() {
		if err := session.Close(); err != nil {
			t.Error(err)
		}
	})
	first, err := session.Download(ctx, archiveSelection(body), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := first.Discard(); err != nil {
			t.Error(err)
		}
	})
	firstPath := first.Path()
	if err := first.Discard(); err != nil {
		t.Fatal(err)
	}
	again, err := session.Download(ctx, archiveSelection(body), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := again.Discard(); err != nil {
			t.Error(err)
		}
	})
	if requests != 1 || again.Path() != firstPath {
		t.Fatalf("retry downloaded again: requests=%d", requests)
	}
	body = "second package"
	second, err := session.Download(ctx, archiveSelection(body), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := second.Discard(); err != nil {
			t.Error(err)
		}
	})
	if requests != 2 {
		t.Fatalf("changed digest reused a different archive: requests=%d", requests)
	}
	// A late failure preparing the evicted archive cannot invalidate its replacement.
	if err := session.Forget(again); err != nil {
		t.Fatal(err)
	}
	newer, err := session.Download(ctx, archiveSelection(body), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := newer.Discard(); err != nil {
			t.Error(err)
		}
	})
	if requests != 2 || newer.Path() != second.Path() {
		t.Fatal("an older preparation evicted the newer transfer")
	}
	if err := newer.Discard(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(firstPath); err != nil {
		t.Fatalf("eviction removed an active borrow: %v", err)
	}
	if err := again.Discard(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(firstPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("evicted file remains: %v", err)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(second.Path()); err != nil {
		t.Fatalf("close removed an active borrow: %v", err)
	}
	if err := second.Discard(); err != nil {
		t.Fatal(err)
	}
	assertArchiveRootEmpty(t, root)
	if _, err := session.Download(ctx, archiveSelection(body), nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("closed session downloaded: %v", err)
	}
}

func TestArchiveSessionDoesNotRetainFailedOrForgottenTransfers(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root := t.TempDir()
	session := NewArchiveSession(newArchiveDownloader(archiveClient("body", 4), root))
	t.Cleanup(func() {
		if err := session.Close(); err != nil {
			t.Error(err)
		}
	})
	if _, err := session.Download(ctx, archiveSelection("wrong"), nil); !errors.Is(err, ErrArchiveChecksum) {
		t.Fatalf("mismatched checksum: %v", err)
	}
	assertArchiveRootEmpty(t, root)
	archive, err := session.Download(ctx, archiveSelection("body"), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := archive.Discard(); err != nil {
			t.Error(err)
		}
	})
	if err := archive.Discard(); err != nil {
		t.Fatal(err)
	}
	if err := session.Forget(archive); err != nil {
		t.Fatal(err)
	}
	assertArchiveRootEmpty(t, root)
	selection := archiveSelection("body")
	selection.DownloadURL = "http://plugins.example.test/archive.zip"
	if _, err := session.Download(ctx, selection, nil); !errors.Is(err, ErrUnsafeRedirect) {
		t.Fatalf("unsafe selection: %v", err)
	}
}

func TestArchiveDownloadReportsBytesWithoutKnowingTheSize(t *testing.T) {
	for _, size := range []int64{-1, 4} {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		var events []ArchiveProgress
		archive, err := newArchiveDownloader(archiveClient("body", size), t.TempDir()).DownloadWithProgress(ctx, archiveSelection("body"), func(p ArchiveProgress) { events = append(events, p) })
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if err := archive.Discard(); err != nil {
			t.Fatal(err)
		}
		if len(events) < 2 || events[0] != (ArchiveProgress{0, size}) || events[len(events)-1] != (ArchiveProgress{4, size}) {
			t.Fatalf("progress did not describe transport bytes: %+v", events)
		}
		for i := 1; i < len(events); i++ {
			if events[i].Received < events[i-1].Received {
				t.Fatalf("progress went backwards: %+v", events)
			}
		}
	}
}
