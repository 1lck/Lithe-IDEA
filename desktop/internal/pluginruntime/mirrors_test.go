package pluginruntime

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func makeMirrorZip(t *testing.T) ([]byte, string) {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, err := zw.Create("jdk/bin/java")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte("#!/bin/sh\necho 25\n")); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(buf.Bytes())
	return buf.Bytes(), hex.EncodeToString(sum[:])
}

func okResponse(req *http.Request, body []byte) *http.Response {
	var r io.ReadCloser = io.NopCloser(bytes.NewReader(body))
	if req.Method == http.MethodHead {
		r = io.NopCloser(bytes.NewReader(nil))
	}
	return &http.Response{
		StatusCode:    http.StatusOK,
		Header:        make(http.Header),
		Body:          r,
		ContentLength: int64(len(body)),
		Request:       req,
	}
}

func TestDownloadMirrorsSelectsFastestReachableSource(t *testing.T) {
	payload, digest := makeMirrorZip(t)
	var mu sync.Mutex
	var gets []string

	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch req.URL.Host {
		case "slow.example.com":
			if req.Method == http.MethodHead {
				select {
				case <-time.After(400 * time.Millisecond):
				case <-req.Context().Done():
					return nil, req.Context().Err()
				}
			}
			mu.Lock()
			if req.Method == http.MethodGet {
				gets = append(gets, req.URL.Host)
			}
			mu.Unlock()
			return okResponse(req, payload), nil
		case "fast.example.cn":
			mu.Lock()
			if req.Method == http.MethodGet {
				gets = append(gets, req.URL.Host)
			}
			mu.Unlock()
			return okResponse(req, payload), nil
		default:
			return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader("")), Request: req}, nil
		}
	})}

	oldGrace, oldTimeout := mirrorProbeGrace, mirrorProbeTimeout
	mirrorProbeGrace, mirrorProbeTimeout = 40*time.Millisecond, time.Second
	defer func() { mirrorProbeGrace, mirrorProbeTimeout = oldGrace, oldTimeout }()

	mgr := Manager{Root: filepath.Join(t.TempDir(), "runtimes"), Downloader: marketplace.NewArchiveDownloader(client)}
	artifact := Artifact{
		ID: "jdk", Version: "25", CacheKey: digest,
		URL:         "https://slow.example.com/jdk.zip",
		Mirrors:     []string{"https://fast.example.cn/jdk.zip"},
		SHA256:      digest,
		Archive:     "zip",
		StripPrefix: "jdk",
		Executable:  "bin/java",
	}
	inst, err := mgr.Prepare(context.Background(), artifact, func(context.Context, Installation) error { return nil }, nil)
	if err != nil {
		t.Fatalf("Prepare failed: %v", err)
	}
	if inst.Home == "" {
		t.Fatal("expected non-empty installation home")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(gets) != 1 || gets[0] != "fast.example.cn" {
		t.Fatalf("GET hosts = %v, want [fast.example.cn]", gets)
	}
}

func TestDownloadMirrorsFailoverOnHTTPErrorAndBadChecksum(t *testing.T) {
	payload, digest := makeMirrorZip(t)
	corrupt := []byte("not-the-right-archive-bytes")
	var mu sync.Mutex
	var gets []string

	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.Method == http.MethodHead {
			// All mirrors report healthy to HEAD, forcing GET-time failover.
			return okResponse(req, payload), nil
		}
		mu.Lock()
		gets = append(gets, req.URL.Host)
		mu.Unlock()
		switch req.URL.Host {
		case "broken.example.com":
			return &http.Response{StatusCode: http.StatusBadGateway, Body: io.NopCloser(strings.NewReader("502")), Request: req}, nil
		case "corrupt.example.cn":
			return okResponse(req, corrupt), nil
		case "good.example.cn":
			return okResponse(req, payload), nil
		default:
			return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader("")), Request: req}, nil
		}
	})}

	oldGrace, oldTimeout := mirrorProbeGrace, mirrorProbeTimeout
	mirrorProbeGrace, mirrorProbeTimeout = 10*time.Millisecond, time.Second
	defer func() { mirrorProbeGrace, mirrorProbeTimeout = oldGrace, oldTimeout }()

	mgr := Manager{Root: filepath.Join(t.TempDir(), "runtimes"), Downloader: marketplace.NewArchiveDownloader(client)}
	artifact := Artifact{
		ID: "jdk", Version: "25", CacheKey: digest,
		URL: "https://broken.example.com/jdk.zip",
		Mirrors: []string{
			"https://corrupt.example.cn/jdk.zip",
			"https://good.example.cn/jdk.zip",
		},
		SHA256:      digest,
		Archive:     "zip",
		StripPrefix: "jdk",
		Executable:  "bin/java",
	}
	if _, err := mgr.Prepare(context.Background(), artifact, func(context.Context, Installation) error { return nil }, nil); err != nil {
		t.Fatalf("Prepare should succeed via good.example.cn, got: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(gets) == 0 || gets[len(gets)-1] != "good.example.cn" {
		t.Fatalf("expected final successful GET from good.example.cn, got %v", gets)
	}
}

type blockingReader struct {
	ctx context.Context
}

func (b blockingReader) Read([]byte) (int, error) {
	<-b.ctx.Done()
	return 0, b.ctx.Err()
}
func (b blockingReader) Close() error { return nil }

func TestDownloadMirrorsFailoverWhenPrimaryIsTooSlow(t *testing.T) {
	payload, digest := makeMirrorZip(t)
	var mu sync.Mutex
	var gets []string

	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		if req.Method == http.MethodHead {
			// Primary responds to HEAD first; backup lags on HEAD so primary is tried first.
			if req.URL.Host == "backup.example.cn" {
				time.Sleep(60 * time.Millisecond)
			}
			return okResponse(req, payload), nil
		}
		mu.Lock()
		gets = append(gets, req.URL.Host)
		mu.Unlock()
		if req.URL.Host == "stalling.example.com" {
			return &http.Response{
				StatusCode:    http.StatusOK,
				Header:        make(http.Header),
				Body:          blockingReader{ctx: req.Context()},
				ContentLength: int64(len(payload)),
				Request:       req,
			}, nil
		}
		return okResponse(req, payload), nil
	})}

	oldGrace, oldTimeout := mirrorProbeGrace, mirrorProbeTimeout
	oldSpeedGrace, oldSpeedWindow, oldMin := mirrorSpeedGrace, mirrorSpeedWindow, mirrorMinBytesPerSec
	mirrorProbeGrace, mirrorProbeTimeout = 100*time.Millisecond, time.Second
	mirrorSpeedGrace, mirrorSpeedWindow, mirrorMinBytesPerSec = 30*time.Millisecond, 30*time.Millisecond, 1024
	defer func() {
		mirrorProbeGrace, mirrorProbeTimeout = oldGrace, oldTimeout
		mirrorSpeedGrace, mirrorSpeedWindow, mirrorMinBytesPerSec = oldSpeedGrace, oldSpeedWindow, oldMin
	}()

	mgr := Manager{Root: filepath.Join(t.TempDir(), "runtimes"), Downloader: marketplace.NewArchiveDownloader(client)}
	artifact := Artifact{
		ID: "jdk", Version: "25", CacheKey: digest,
		URL:         "https://stalling.example.com/jdk.zip",
		Mirrors:     []string{"https://backup.example.cn/jdk.zip"},
		SHA256:      digest,
		Archive:     "zip",
		StripPrefix: "jdk",
		Executable:  "bin/java",
	}
	if _, err := mgr.Prepare(context.Background(), artifact, func(context.Context, Installation) error { return nil }, nil); err != nil {
		t.Fatalf("Prepare should fail over from slow mirror to backup, got: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(gets) != 2 || gets[0] != "stalling.example.com" || gets[1] != "backup.example.cn" {
		t.Fatalf("GET order = %v, want [stalling.example.com backup.example.cn]", gets)
	}
}

func TestDownloadMirrorsHonorsParentCancellation(t *testing.T) {
	_, digest := makeMirrorZip(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	mgr := Manager{Root: filepath.Join(t.TempDir(), "runtimes"), Downloader: marketplace.NewArchiveDownloader(&http.Client{
		Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			t.Fatalf("unexpected request after cancel: %s", req.URL)
			return nil, context.Canceled
		}),
	})}
	artifact := Artifact{
		ID: "jdk", Version: "25", CacheKey: digest,
		URL:     "https://a.example.com/jdk.zip",
		Mirrors: []string{"https://b.example.cn/jdk.zip"},
		SHA256:  digest,
		Archive: "zip",
	}
	_, err := mgr.Prepare(ctx, artifact, func(context.Context, Installation) error { return nil }, nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
}
