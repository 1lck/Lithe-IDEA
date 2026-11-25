package pluginruntime

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
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
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type member struct {
	name, body, link string
	kind             byte
	mode             int64
}

func tarArchive(t *testing.T, members ...member) []byte {
	t.Helper()
	var buffer bytes.Buffer
	compressed := gzip.NewWriter(&buffer)
	archive := tar.NewWriter(compressed)
	for _, item := range members {
		kind := item.kind
		if kind == 0 {
			kind = tar.TypeReg
		}
		mode := item.mode
		if mode == 0 {
			mode = 0o644
		}
		size := int64(len(item.body))
		if kind != tar.TypeReg {
			size = 0
		}
		if err := archive.WriteHeader(&tar.Header{Name: item.name, Mode: mode, Size: size, Typeflag: kind, Linkname: item.link}); err != nil {
			t.Fatal(err)
		}
		if size != 0 {
			if _, err := archive.Write([]byte(item.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func zipArchive(t *testing.T, members ...member) []byte {
	t.Helper()
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	for _, item := range members {
		header := &zip.FileHeader{Name: item.name, Method: zip.Deflate}
		mode := os.FileMode(item.mode)
		if mode == 0 {
			mode = 0o644
		}
		header.SetMode(mode)
		writer, err := archive.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte(item.body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func selected(body []byte, format, version string) Artifact {
	digest := sha256.Sum256(body)
	key := sha256.Sum256(append([]byte(version), digest[:]...))
	return Artifact{ID: "worker", Version: version, CacheKey: hex.EncodeToString(key[:]), URL: "https://runtimes.example.test/worker", SHA256: hex.EncodeToString(digest[:]), Archive: format, StripPrefix: "distribution", Executable: "bin/worker"}
}

func testManager(t *testing.T, bodies map[string][]byte) (*Manager, *atomic.Int64) {
	t.Helper()
	calls := new(atomic.Int64)
	client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		body, ok := bodies[request.URL.String()]
		if !ok {
			return nil, errors.New("unexpected download")
		}
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(body)), ContentLength: int64(len(body)), Request: request}, nil
	})}
	return &Manager{Root: filepath.Join(t.TempDir(), "state with spaces", "runtimes"), Downloader: marketplace.NewArchiveDownloader(client)}, calls
}

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func validateBody(expected string) func(context.Context, Installation) error {
	return func(ctx context.Context, installation Installation) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		body, err := os.ReadFile(installation.Executable)
		if err == nil && string(body) != expected {
			err = errors.New("runtime probe rejected the installed version")
		}
		return err
	}
}

func TestPrepareReusesAcrossPluginVersionsAndRepairsOffline(t *testing.T) {
	for _, format := range []string{"tar.gz", "zip"} {
		t.Run(format, func(t *testing.T) {
			items := []member{{name: "distribution/bin/worker", body: "version one", mode: 0o755}, {name: "distribution/lib/resource", body: "payload"}}
			body := tarArchive(t, items...)
			if format == "zip" {
				body = zipArchive(t, items...)
			}
			artifact := selected(body, format, "1")
			manager, calls := testManager(t, map[string][]byte{artifact.URL: body})
			ctx := testContext(t)
			first, err := manager.Prepare(ctx, artifact, validateBody("version one"), nil)
			if err != nil || first.Reused {
				t.Fatalf("first prepare = %+v, %v", first, err)
			}
			if runtime.GOOS != "windows" {
				info, err := os.Stat(first.Executable)
				if err != nil || info.Mode().Perm()&0o111 != 0o111 {
					t.Fatalf("executable permissions = %v, %v", info, err)
				}
			}
			// A new plugin version creates a new manager, but the same Core cache
			// identity is independent of that plugin's package version.
			updated := *manager
			reused, err := updated.Prepare(ctx, artifact, validateBody("version one"), nil)
			if err != nil || !reused.Reused || reused.Directory != first.Directory || calls.Load() != 1 {
				t.Fatalf("reuse = %+v, %v, downloads %d", reused, err, calls.Load())
			}
			if err := os.WriteFile(first.Executable, []byte("version two"), 0o755); err != nil {
				t.Fatal(err)
			}
			if _, _, err := updated.Verify(ctx, artifact); !errors.Is(err, ErrCorrupt) {
				t.Fatalf("changed runtime verified: %v", err)
			}
			var repairing bool
			repaired, err := updated.Prepare(ctx, artifact, validateBody("version one"), func(p Progress) { repairing = repairing || p.Phase == "repairing" })
			if err != nil || repaired.Reused || repaired.Directory == first.Directory || calls.Load() != 1 || !repairing {
				t.Fatalf("repair = %+v, %v, downloads %d, repairing %v", repaired, err, calls.Load(), repairing)
			}
			if _, err := os.Stat(first.Executable); err != nil {
				t.Fatalf("repair removed a generation that an existing process may use: %v", err)
			}
		})
	}
}

func TestFailedDependencyUpgradeRetainsPreviousRuntime(t *testing.T) {
	oldBody := tarArchive(t, member{name: "distribution/bin/worker", body: "working"})
	newBody := tarArchive(t, member{name: "distribution/bin/worker", body: "incompatible"})
	old := selected(oldBody, "tar.gz", "1")
	next := selected(newBody, "tar.gz", "2")
	next.URL += "-new"
	manager, _ := testManager(t, map[string][]byte{old.URL: oldBody, next.URL: newBody})
	ctx := testContext(t)
	previous, err := manager.Prepare(ctx, old, validateBody("working"), nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Prepare(ctx, next, validateBody("working"), nil); err == nil {
		t.Fatal("incompatible upgrade was published")
	}
	if _, found, err := manager.Find(ctx, next); err != nil || found {
		t.Fatalf("failed upgrade has a completion marker: %v, %v", found, err)
	}
	current, found, err := manager.Verify(ctx, old)
	if err != nil || !found || current.Directory != previous.Directory {
		t.Fatalf("previous runtime was lost: %+v, %v, %v", current, found, err)
	}
}

func TestConcurrentManagersDownloadOnceAndCancellationReleasesWaiter(t *testing.T) {
	body := tarArchive(t, member{name: "distribution/bin/worker", body: "working"})
	artifact := selected(body, "tar.gz", "1")
	manager, calls := testManager(t, map[string][]byte{artifact.URL: body})
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	entered, release := make(chan struct{}), make(chan struct{})
	var firstOnce sync.Once
	validator := func(ctx context.Context, candidate Installation) error {
		firstOnce.Do(func() {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
			}
		})
		return validateBody("working")(ctx, candidate)
	}
	type outcome struct {
		installation Installation
		err          error
	}
	firstDone, secondDone := make(chan outcome, 1), make(chan outcome, 1)
	firstFinished, secondFinished := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(firstFinished)
		value, err := manager.Prepare(ctx, artifact, validator, nil)
		firstDone <- outcome{value, err}
	}()
	secondCtx, cancelSecond := context.WithCancel(ctx)
	secondStarted := make(chan struct{}, 1)
	var secondStartedOnce sync.Once
	go func() {
		defer close(secondFinished)
		select {
		case <-entered:
		case <-ctx.Done():
		}
		other := *manager
		value, err := other.Prepare(secondCtx, artifact, validateBody("working"), func(p Progress) {
			if p.Phase == "checking" {
				secondStartedOnce.Do(func() { secondStarted <- struct{}{} })
			}
		})
		secondDone <- outcome{value, err}
	}()
	t.Cleanup(func() {
		cancelSecond()
		cancel()
		for _, finished := range []<-chan struct{}{firstFinished, secondFinished} {
			select {
			case <-finished:
			case <-time.After(5 * time.Second):
				t.Error("runtime preparation worker did not stop during cleanup")
			}
		}
	})
	select {
	case <-secondStarted:
	case <-ctx.Done():
		t.Fatal("second manager did not reach the lock")
	}
	cancelSecond()
	select {
	case result := <-secondDone:
		if !errors.Is(result.err, context.Canceled) {
			t.Fatalf("waiting manager returned %v", result.err)
		}
	case <-ctx.Done():
		t.Fatal("cancelled lock waiter did not exit")
	}
	close(release)
	var first outcome
	select {
	case first = <-firstDone:
	case <-ctx.Done():
		t.Fatal("first manager did not complete")
	}
	if first.err != nil {
		t.Fatal(first.err)
	}
	other := *manager
	last, err := other.Prepare(ctx, artifact, validateBody("working"), nil)
	if err != nil || !last.Reused || last.Directory != first.installation.Directory || calls.Load() != 1 {
		t.Fatalf("final reuse = %+v, %v, downloads %d", last, err, calls.Load())
	}
}

func TestUnsafeArchivesNeverPublishOrWriteOutsideTheirGeneration(t *testing.T) {
	cases := []struct {
		name  string
		items []member
	}{
		{"parent", []member{{name: "distribution/../../escape", body: "bad"}}},
		{"absolute", []member{{name: "/escape", body: "bad"}}},
		{"drive", []member{{name: "distribution/C:/escape", body: "bad"}}},
		{"backslash", []member{{name: "distribution/a\\escape", body: "bad"}}},
		{"outside prefix", []member{{name: "another/bin/worker", body: "bad"}}},
		{"duplicate", []member{{name: "distribution/bin/worker", body: "one"}, {name: "distribution/bin/worker", body: "two"}}},
		{"case collision", []member{{name: "distribution/bin/worker", body: "one"}, {name: "distribution/BIN/WORKER", body: "two"}}},
		{"link escape", []member{{name: "distribution/bin/worker", kind: tar.TypeSymlink, link: "../../escape"}}},
		{"link parent write", []member{{name: "distribution/bin", kind: tar.TypeSymlink, link: "lib"}, {name: "distribution/bin/worker", body: "bad"}}},
		{"hardlink escape", []member{{name: "distribution/bin/worker", kind: tar.TypeLink, link: "../../escape"}}},
		{"device", []member{{name: "distribution/bin/worker", kind: tar.TypeChar}}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			body := tarArchive(t, test.items...)
			artifact := selected(body, "tar.gz", "1")
			manager, _ := testManager(t, map[string][]byte{artifact.URL: body})
			ctx := testContext(t)
			if _, err := manager.Prepare(ctx, artifact, validateBody("working"), nil); err == nil {
				t.Fatal("unsafe archive accepted")
			}
			if _, found, err := manager.Find(ctx, artifact); err != nil || found {
				t.Fatalf("unsafe archive published: %v, %v", found, err)
			}
			entries, err := os.ReadDir(filepath.Join(manager.Root, artifact.CacheKey))
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), ".staging-") || strings.HasPrefix(entry.Name(), "install-") {
					t.Fatalf("unverified extraction remains: %s", entry.Name())
				}
			}
		})
	}
}

func TestInternalArchiveLinksAndHomeLayout(t *testing.T) {
	probe := t.TempDir()
	if err := os.WriteFile(filepath.Join(probe, "target"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("target", filepath.Join(probe, "link")); err != nil {
		t.Skipf("native symbolic link creation unavailable: %v", err)
	}
	body := tarArchive(t,
		member{name: "./distribution/Contents/Home/bin/worker", body: "working", mode: 0o755},
		member{name: "./distribution/Contents/Home/lib/resource", body: "resource"},
		member{name: "./distribution/Contents/Home/bin/resource", kind: tar.TypeSymlink, link: "../lib/resource"},
		member{name: "./distribution/Contents/Home/lib/alias", kind: tar.TypeLink, link: "distribution/Contents/Home/lib/resource"},
	)
	artifact := selected(body, "tar.gz", "1")
	artifact.Home = "Contents/Home"
	manager, _ := testManager(t, map[string][]byte{artifact.URL: body})
	ctx := testContext(t)
	installed, err := manager.Prepare(ctx, artifact, validateBody("working"), nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"bin/resource", "lib/alias"} {
		data, err := os.ReadFile(filepath.Join(installed.Home, filepath.FromSlash(name)))
		if err != nil || string(data) != "resource" {
			t.Fatalf("archive link %s = %q, %v", name, data, err)
		}
	}
}

func TestChecksumFailureAndCancelledValidationNeverPublish(t *testing.T) {
	body := tarArchive(t, member{name: "distribution/bin/worker", body: "working"})
	artifact := selected(body, "tar.gz", "1")
	manager, _ := testManager(t, map[string][]byte{artifact.URL: []byte("damaged download")})
	ctx := testContext(t)
	// A download that never delivered the pinned bytes says so, with the transfer's own cause.
	if _, err := manager.Prepare(ctx, artifact, validateBody("working"), nil); !errors.Is(err, ErrDownload) || !errors.Is(err, marketplace.ErrArchiveChecksum) {
		t.Fatalf("checksum failure = %v", err)
	}
	manager, _ = testManager(t, map[string][]byte{artifact.URL: body})
	cancelCtx, cancel := context.WithCancel(ctx)
	_, err := manager.Prepare(cancelCtx, artifact, func(context.Context, Installation) error { cancel(); return context.Canceled }, nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled validation = %v", err)
	}
	if _, found, err := manager.Find(ctx, artifact); err != nil || found {
		t.Fatalf("cancelled preparation published: %v, %v", found, err)
	}
}

func TestArchiveBudgetsRejectOversizedMetadataBeforeExtraction(t *testing.T) {
	ctx := testContext(t)
	valid := zipArchive(t, member{name: "distribution/bin/worker", body: "working"})
	for _, mutate := range []func([]byte){
		func(body []byte) { body[len(body)-12], body[len(body)-11] = 0xfe, 0xff },
		func(body []byte) {
			body[len(body)-10], body[len(body)-9], body[len(body)-8], body[len(body)-7] = 0xff, 0xff, 0xff, 0x7f
		},
	} {
		body := bytes.Clone(valid)
		mutate(body)
		if err := checkZIPDirectory(ctx, bytes.NewReader(body), int64(len(body))); !errors.Is(err, ErrArchive) {
			t.Fatalf("oversized ZIP metadata accepted: %v", err)
		}
	}
	var compressed bytes.Buffer
	gzipWriter := gzip.NewWriter(&compressed)
	tarWriter := tar.NewWriter(gzipWriter)
	if err := tarWriter.WriteHeader(&tar.Header{Name: "distribution/bin/worker", Mode: 0o755, Size: maxExpandedBytes + 1}); err != nil {
		t.Fatal(err)
	}
	// The deliberately truncated file has a valid gzip stream. Its oversized
	// tar declaration must be refused before any content is requested or written.
	if err := gzipWriter.Close(); err != nil {
		t.Fatal(err)
	}
	body := compressed.Bytes()
	artifact := selected(body, "tar.gz", "1")
	manager, _ := testManager(t, map[string][]byte{artifact.URL: body})
	if _, err := manager.Prepare(ctx, artifact, validateBody("working"), nil); !errors.Is(err, ErrArchive) {
		t.Fatalf("oversized tar declaration accepted: %v", err)
	}
}

type blockedBody struct {
	ctx     context.Context
	started chan struct{}
	once    sync.Once
}

func (b *blockedBody) Read([]byte) (int, error) {
	b.once.Do(func() { close(b.started) })
	<-b.ctx.Done()
	return 0, b.ctx.Err()
}
func (*blockedBody) Close() error { return nil }

func TestCancelledTransferLeavesNoCompleteOrPartialGeneration(t *testing.T) {
	body := tarArchive(t, member{name: "distribution/bin/worker", body: "working"})
	artifact := selected(body, "tar.gz", "1")
	started := make(chan struct{})
	client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: &blockedBody{ctx: request.Context(), started: started}, ContentLength: -1, Request: request}, nil
	})}
	manager := &Manager{Root: filepath.Join(t.TempDir(), "runtimes"), Downloader: marketplace.NewArchiveDownloader(client)}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	result, finished := make(chan error, 1), make(chan struct{})
	go func() {
		defer close(finished)
		_, err := manager.Prepare(ctx, artifact, validateBody("working"), nil)
		result <- err
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-finished:
		case <-time.After(5 * time.Second):
			t.Error("cancelled transfer worker did not stop")
		}
	})
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("transfer did not reach the body")
	}
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled transfer error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("transfer did not return after cancellation")
	}
	entries, err := os.ReadDir(filepath.Join(manager.Root, artifact.CacheKey))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.Name() != ".lock" {
			t.Fatalf("cancelled transfer left unverified data: %s", entry.Name())
		}
	}
}

func TestPrepareCleansAbandonedAtomicArchiveTemps(t *testing.T) {
	body := tarArchive(t, member{name: "distribution/bin/worker", body: "working", mode: 0o755})
	artifact := selected(body, "tar.gz", "1")
	manager, _ := testManager(t, map[string][]byte{artifact.URL: body})
	base := filepath.Join(manager.Root, artifact.CacheKey)
	if err := os.MkdirAll(base, 0o700); err != nil {
		t.Fatal(err)
	}
	abandoned := filepath.Join(base, ".archive.crashed-attempt")
	if err := os.WriteFile(abandoned, []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx := testContext(t)
	installed, err := manager.Prepare(ctx, artifact, validateBody("working"), nil)
	if err != nil || installed.Executable == "" {
		t.Fatalf("prepare after crash = %+v, %v", installed, err)
	}
	if _, err := os.Stat(abandoned); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("abandoned archive temp remained: %v", err)
	}
}
