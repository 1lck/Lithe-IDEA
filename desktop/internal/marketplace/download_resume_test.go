package marketplace

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

var errConnectionReset = errors.New("connection reset by peer")

// brokenReader is the rest of a response body whose connection dropped.
type brokenReader struct{}

func (brokenReader) Read([]byte) (int, error) { return 0, errConnectionReset }

// How a rangeServer answers a request that asks for the rest of the body.
const (
	rangeHonored = iota // 206 with the bytes from where the request asked
	rangeIgnored        // 200 with the whole body
	rangeShifted        // 206 with the whole body, which is not the range asked for
	rangeRefused        // 416
)

// rangeServer serves body the way an archive host does, answering a Range request as mode
// says. It records the Range header of every request and how many bytes each response
// carried; cut, when not zero, ends the first response after that many bytes as a dropped
// connection does.
type rangeServer struct {
	body string
	cut  int
	mode int

	mu     sync.Mutex
	ranges []string
	sent   []int
}

func (s *rangeServer) client() *http.Client {
	return &http.Client{Transport: transportFunc(s.serve)}
}

func (s *rangeServer) serve(request *http.Request) (*http.Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	asked := request.Header.Get("Range")
	s.ranges = append(s.ranges, asked)
	response := &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Request: request}
	rest := s.body
	if asked != "" {
		from, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(asked, "bytes="), "-"))
		if err != nil {
			return nil, fmt.Errorf("unexpected Range %q", asked)
		}
		switch s.mode {
		case rangeHonored:
			rest = s.body[from:]
			response.StatusCode = http.StatusPartialContent
			response.Header.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", from, len(s.body)-1, len(s.body)))
		case rangeShifted:
			response.StatusCode = http.StatusPartialContent
			response.Header.Set("Content-Range", fmt.Sprintf("bytes 0-%d/%d", len(s.body)-1, len(s.body)))
		case rangeRefused:
			response.StatusCode = http.StatusRequestedRangeNotSatisfiable
			rest = ""
		}
	}
	response.ContentLength = int64(len(rest))
	if len(s.ranges) == 1 && s.cut > 0 {
		response.Body = io.NopCloser(io.MultiReader(strings.NewReader(rest[:s.cut]), brokenReader{}))
		s.sent = append(s.sent, s.cut)
		return response, nil
	}
	response.Body = io.NopCloser(strings.NewReader(rest))
	s.sent = append(s.sent, len(rest))
	return response, nil
}

// requests returns the Range header of each request so far and the bytes each response carried.
func (s *rangeServer) requests() ([]string, []int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.ranges), slices.Clone(s.sent)
}

// keptArchive returns the path and the bytes of the one transfer the temporary root holds.
func keptArchive(t *testing.T, root string) (string, string) {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("the temporary root holds %d transfers, want the one that was cut off", len(entries))
	}
	path := filepath.Join(root, entries[0].Name(), "archive.zip")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return path, string(data)
}

// closeSession closes session at the end of the test, which removes what it kept.
func closeSession(t *testing.T, session *ArchiveSession) {
	t.Cleanup(func() {
		if err := session.Close(); err != nil {
			t.Error(err)
		}
	})
}

// cutOff starts the session's first transfer of body, which the server cuts off after 400 bytes.
func cutOff(t *testing.T, ctx context.Context, session *ArchiveSession, body string) {
	t.Helper()
	if archive, err := session.Download(ctx, archiveSelection(body), nil); archive != nil || !errors.Is(err, errConnectionReset) {
		t.Fatalf("the cut-off transfer returned %v, %v", archive, err)
	}
}

// readArchive returns the bytes of archive and discards it.
func readArchive(t *testing.T, archive *DownloadedArchive) string {
	t.Helper()
	data, err := os.ReadFile(archive.Path())
	if err != nil {
		t.Fatal(err)
	}
	if err := archive.Discard(); err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// TestArchiveSessionContinuesAnInterruptedTransfer cuts a transfer off part way: the session
// keeps what arrived, the next download of the same archive asks only for the rest and
// reports progress from the kept bytes, and closing the session removes the archive.
func TestArchiveSessionContinuesAnInterruptedTransfer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root := t.TempDir()
	body := strings.Repeat("0123456789", 100)
	server := &rangeServer{body: body, cut: 400}
	session := NewArchiveSession(newArchiveDownloader(server.client(), root))
	closeSession(t, session)

	cutOff(t, ctx, session, body)
	if _, kept := keptArchive(t, root); kept != body[:400] {
		t.Fatalf("kept %d bytes, want the 400 that arrived", len(kept))
	}
	var events []ArchiveProgress
	archive, err := session.Download(ctx, archiveSelection(body), func(p ArchiveProgress) { events = append(events, p) })
	if err != nil {
		t.Fatal(err)
	}
	if got := readArchive(t, archive); got != body {
		t.Fatalf("the continued archive holds %d bytes, want the %d of the original", len(got), len(body))
	}
	if ranges, sent := server.requests(); !slices.Equal(ranges, []string{"", "bytes=400-"}) || !slices.Equal(sent, []int{400, 600}) {
		t.Fatalf("the requests asked for %q and carried %v bytes, want the rest alone the second time", ranges, sent)
	}
	if len(events) < 2 || events[0] != (ArchiveProgress{400, 1000}) || events[len(events)-1] != (ArchiveProgress{1000, 1000}) {
		t.Fatalf("progress %+v, want it to count from the kept bytes", events)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	assertArchiveRootEmpty(t, root)
}

// TestArchiveSessionStartsOverWhenTheRangeIsNotServed continues a cut-off transfer from a
// server that ignores the Range request, answers with another range, or refuses it: each
// time the archive is fetched whole and matches.
func TestArchiveSessionStartsOverWhenTheRangeIsNotServed(t *testing.T) {
	for name, mode := range map[string]int{"ignored": rangeIgnored, "shifted": rangeShifted, "refused": rangeRefused} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			root := t.TempDir()
			body := strings.Repeat("0123456789", 100)
			server := &rangeServer{body: body, cut: 400, mode: mode}
			session := NewArchiveSession(newArchiveDownloader(server.client(), root))
			closeSession(t, session)

			cutOff(t, ctx, session, body)
			archive, err := session.Download(ctx, archiveSelection(body), nil)
			if err != nil {
				t.Fatal(err)
			}
			if got := readArchive(t, archive); got != body {
				t.Fatalf("the archive holds %d bytes, want the %d of the original", len(got), len(body))
			}
			if ranges, _ := server.requests(); len(ranges) < 2 || ranges[1] != "bytes=400-" {
				t.Fatalf("the requests asked for %q, want the second to ask for the rest", ranges)
			}
		})
	}
}

// TestArchiveSessionDropsKeptBytesThatAreWrong damages what a cut-off transfer kept: the
// continued archive does not match the index, so it is refused and the kept bytes go, and
// the next download fetches the archive from the start.
func TestArchiveSessionDropsKeptBytesThatAreWrong(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root := t.TempDir()
	body := strings.Repeat("0123456789", 100)
	server := &rangeServer{body: body, cut: 400}
	session := NewArchiveSession(newArchiveDownloader(server.client(), root))
	closeSession(t, session)

	cutOff(t, ctx, session, body)
	path, _ := keptArchive(t, root)
	if err := os.WriteFile(path, []byte(strings.Repeat("x", 400)), 0o600); err != nil {
		t.Fatal(err)
	}
	if archive, err := session.Download(ctx, archiveSelection(body), nil); archive != nil || !errors.Is(err, ErrArchiveChecksum) {
		t.Fatalf("the continued archive returned %v, %v, want it refused", archive, err)
	}
	assertArchiveRootEmpty(t, root)
	archive, err := session.Download(ctx, archiveSelection(body), nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := readArchive(t, archive); got != body {
		t.Fatalf("the archive holds %q..., want the original", got[:min(len(got), 20)])
	}
	if ranges, _ := server.requests(); !slices.Equal(ranges, []string{"", "bytes=400-", ""}) {
		t.Fatalf("the requests asked for %q, want the rest and then the whole archive", ranges)
	}
}

// TestArchiveSessionKeepsOneTransfer starts another archive after one was cut off, and closes
// a session holding a cut-off transfer: the kept bytes are removed both times, so a window
// holds one transfer at most.
func TestArchiveSessionKeepsOneTransfer(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	root := t.TempDir()
	body := strings.Repeat("0123456789", 100)
	server := &rangeServer{body: body, cut: 400}
	session := NewArchiveSession(newArchiveDownloader(server.client(), root))
	closeSession(t, session)

	cutOff(t, ctx, session, body)
	if _, err := session.Download(ctx, archiveSelection("another archive"), nil); !errors.Is(err, ErrArchiveChecksum) {
		t.Fatalf("another archive: %v", err)
	}
	if ranges, _ := server.requests(); !slices.Equal(ranges, []string{"", ""}) {
		t.Fatalf("the requests asked for %q, want another archive fetched from the start", ranges)
	}
	assertArchiveRootEmpty(t, root)

	closing := NewArchiveSession(newArchiveDownloader((&rangeServer{body: body, cut: 400}).client(), root))
	cutOff(t, ctx, closing, body)
	if err := closing.Close(); err != nil {
		t.Fatal(err)
	}
	assertArchiveRootEmpty(t, root)
}

// manualStall stands in for the stall timer. It counts only the time a test adds with
// advance, and fires once that reaches the stall time since it was last reset.
type manualStall struct {
	mu      sync.Mutex
	limit   time.Duration
	elapsed time.Duration
	fire    func()
	stopped bool
}

func (m *manualStall) start(limit time.Duration, fire func()) stallTimer {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.limit, m.elapsed, m.fire, m.stopped = limit, 0, fire, false
	return m
}

func (m *manualStall) Reset(limit time.Duration) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	active := !m.stopped
	m.limit, m.elapsed, m.stopped = limit, 0, false
	return active
}

func (m *manualStall) Stop() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	active := !m.stopped
	m.stopped = true
	return active
}

func (m *manualStall) advance(by time.Duration) {
	m.mu.Lock()
	m.elapsed += by
	fire := m.fire
	due := fire != nil && !m.stopped && m.elapsed >= m.limit
	if due {
		m.stopped = true
	}
	m.mu.Unlock()
	if due {
		fire()
	}
}

// TestArchiveDownloadEndsATransferThatGoesSilent lets a transfer deliver a few bytes and then
// nothing for the stall time: it ends as a timeout, before the caller's deadline, and the
// session keeps the bytes that arrived.
func TestArchiveDownloadEndsATransferThatGoesSilent(t *testing.T) {
	root := t.TempDir()
	started := make(chan struct{})
	client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: &cancelledArchiveBody{ctx: request.Context(), started: started}, ContentLength: -1, Request: request}, nil
	})}
	timer := &manualStall{}
	downloader := newArchiveDownloader(client, root)
	downloader.stallTimer = timer.start
	session := NewArchiveSession(downloader)
	closeSession(t, session)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := session.Download(ctx, archiveSelection("expected"), nil)
		result <- err
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-result:
		case <-time.After(5 * time.Second):
			t.Error("the download goroutine did not exit during cleanup")
		}
	})
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("the transfer did not start before the deadline")
	}
	timer.advance(downloader.stall)
	select {
	case err := <-result:
		result <- err
		if !errors.Is(err, ErrArchiveStalled) || !errors.Is(err, context.DeadlineExceeded) || ctx.Err() != nil {
			t.Fatalf("the silent transfer ended with %v, want a stall before the caller's deadline", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the silent transfer did not end")
	}
	if _, kept := keptArchive(t, root); kept != "partial" {
		t.Fatalf("kept %q, want the bytes that arrived", kept)
	}
}

// tricklingBody delivers its chunks one read at a time, and before each one lets three
// quarters of the stall time pass.
type tricklingBody struct {
	timer  *manualStall
	stall  time.Duration
	chunks []string
}

func (b *tricklingBody) Read(buffer []byte) (int, error) {
	if len(b.chunks) == 0 {
		return 0, io.EOF
	}
	b.timer.advance(b.stall * 3 / 4)
	n := copy(buffer, b.chunks[0])
	b.chunks = b.chunks[1:]
	return n, nil
}

func (*tricklingBody) Close() error { return nil }

// TestArchiveDownloadIsNotBoundedByItsLength downloads an archive that keeps arriving for
// several times the stall time: it is not cut off, and its request carries no deadline the
// caller did not set.
func TestArchiveDownloadIsNotBoundedByItsLength(t *testing.T) {
	timer := &manualStall{}
	chunks := []string{"one ", "two ", "three ", "four ", "five ", "six ", "seven ", "eight"}
	var deadlines []bool
	var downloader *ArchiveDownloader
	client := &http.Client{Transport: transportFunc(func(request *http.Request) (*http.Response, error) {
		_, has := request.Context().Deadline()
		deadlines = append(deadlines, has)
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: &tricklingBody{timer: timer, stall: downloader.stall, chunks: slices.Clone(chunks)}, ContentLength: -1, Request: request}, nil
	})}
	downloader = newArchiveDownloader(client, t.TempDir())
	downloader.stallTimer = timer.start
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	archive, err := downloader.Download(ctx, archiveSelection(strings.Join(chunks, "")))
	if err != nil {
		t.Fatalf("an archive that kept arriving ended with %v", err)
	}
	if got := readArchive(t, archive); got != strings.Join(chunks, "") {
		t.Fatalf("the archive holds %q", got)
	}
	if !slices.Equal(deadlines, []bool{false}) {
		t.Fatalf("the requests carried deadlines %v, want one request with none", deadlines)
	}
}
