package webpreview

import (
	"bytes"
	"container/list"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// errTooLarge is a file or download over the page's limit.
var errTooLarge = errors.New("webpreview: resource is too large")

// errNotRegular is a path that is not a regular file, or one that became a link.
var errNotRegular = errors.New("webpreview: resource is not a regular file")

// readFile reads a regular file of at most limit bytes. Unless follow is set, the path itself
// must not be a link, and must still be the file that was opened.
func readFile(path string, limit int64, follow bool) ([]byte, error) {
	if !follow {
		info, err := os.Lstat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() {
			return nil, errNotRegular
		}
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !opened.Mode().IsRegular() {
		return nil, errNotRegular
	}
	if !follow {
		linked, err := os.Lstat(path)
		if err != nil || !os.SameFile(opened, linked) {
			return nil, errNotRegular
		}
	}
	if limit > 0 && opened.Size() > limit {
		return nil, errTooLarge
	}
	reader := io.Reader(file)
	if limit > 0 {
		reader = io.LimitReader(file, limit+1)
	}
	data, err := io.ReadAll(reader)
	if err != nil {
		return nil, err
	}
	if limit > 0 && int64(len(data)) > limit {
		return nil, errTooLarge
	}
	return data, nil
}

const (
	// remoteEntries and remoteBytes bound what Remote keeps.
	remoteEntries = 64
	remoteBytes   = 48 << 20
	// remoteFailure is how long a failed address is not fetched again, so a page laid out on
	// each keystroke does not fetch it each time.
	remoteFailure = 30 * time.Second
)

// Remote fetches the http and https images of Markdown pages and keeps the latest of them, for
// all pages: a page shown again, or laid out again, does not fetch its images again. A fetch is
// shared by the requests that wait for it.
type Remote struct {
	// Fetch downloads one address, bounded in time and size; it follows the application's proxy.
	Fetch func(ctx context.Context, address string) ([]byte, error)
	// Now is the clock; nil is time.Now.
	Now func() time.Time

	mu      sync.Mutex
	entries map[string]*list.Element
	order   list.List
	bytes   int
	calls   map[string]*remoteCall
}

// remoteEntry is one kept answer.
type remoteEntry struct {
	address string
	data    []byte
	mime    string
	err     error
	expires time.Time
}

// remoteCall is one fetch in flight.
type remoteCall struct {
	done chan struct{}
	data []byte
	mime string
	err  error
}

// Get is the image at address and its type, fetched or kept.
func (r *Remote) Get(ctx context.Context, address string) ([]byte, string, error) {
	r.mu.Lock()
	if entry, ok := r.lookup(address); ok {
		r.mu.Unlock()
		return entry.data, entry.mime, entry.err
	}
	call, waiting := r.calls[address]
	if !waiting {
		call = &remoteCall{done: make(chan struct{})}
		if r.calls == nil {
			r.calls = map[string]*remoteCall{}
		}
		r.calls[address] = call
	}
	r.mu.Unlock()
	if !waiting {
		// The fetch belongs to every request waiting for it, so one page closing does not end it.
		go r.fetch(address, call)
	}
	select {
	case <-call.done:
		return call.data, call.mime, call.err
	case <-ctx.Done():
		return nil, "", ctx.Err()
	}
}

func (r *Remote) fetch(address string, call *remoteCall) {
	data, err := r.Fetch(context.Background(), address)
	mime := ""
	if err == nil {
		mime, err = imageType(data)
	}
	if err != nil {
		data = nil
	}
	call.data, call.mime, call.err = data, mime, err
	r.mu.Lock()
	delete(r.calls, address)
	r.store(&remoteEntry{address: address, data: data, mime: mime, err: err})
	r.mu.Unlock()
	close(call.done)
}

// lookup is the kept answer for address, moved to the front; a failure is kept for a while.
func (r *Remote) lookup(address string) (*remoteEntry, bool) {
	element, ok := r.entries[address]
	if !ok {
		return nil, false
	}
	entry := element.Value.(*remoteEntry)
	if entry.err != nil && !r.now().Before(entry.expires) {
		r.remove(element)
		return nil, false
	}
	r.order.MoveToFront(element)
	return entry, true
}

func (r *Remote) store(entry *remoteEntry) {
	if r.entries == nil {
		r.entries = map[string]*list.Element{}
	}
	if element, ok := r.entries[entry.address]; ok {
		r.remove(element)
	}
	if entry.err != nil {
		entry.expires = r.now().Add(remoteFailure)
	}
	if len(entry.data) > remoteBytes {
		return
	}
	r.entries[entry.address] = r.order.PushFront(entry)
	r.bytes += len(entry.data)
	for r.order.Len() > remoteEntries || r.bytes > remoteBytes {
		r.remove(r.order.Back())
	}
}

func (r *Remote) remove(element *list.Element) {
	entry := element.Value.(*remoteEntry)
	r.order.Remove(element)
	delete(r.entries, entry.address)
	r.bytes -= len(entry.data)
}

func (r *Remote) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

// imageType is the type of downloaded bytes, which must be an image: the server's word for it is
// not taken.
func imageType(data []byte) (string, error) {
	sniffed := http.DetectContentType(data)
	if strings.HasPrefix(sniffed, "image/") {
		return sniffed, nil
	}
	if isSVG(data) {
		return "image/svg+xml", nil
	}
	return "", fmt.Errorf("webpreview: download is not an image (%s)", sniffed)
}

// isSVG reports whether data starts as an SVG document: an svg element, after an optional XML
// declaration, comments and a doctype.
func isSVG(data []byte) bool {
	head := data[:min(len(data), 4096)]
	head = bytes.TrimPrefix(head, []byte("\xef\xbb\xbf"))
	for {
		head = bytes.TrimLeft(head, " \t\r\n")
		switch {
		case bytes.HasPrefix(head, []byte("<?")):
			end := bytes.Index(head, []byte("?>"))
			if end < 0 {
				return false
			}
			head = head[end+2:]
		case bytes.HasPrefix(head, []byte("<!--")):
			end := bytes.Index(head, []byte("-->"))
			if end < 0 {
				return false
			}
			head = head[end+3:]
		case bytes.HasPrefix(head, []byte("<!")):
			end := bytes.IndexByte(head, '>')
			if end < 0 {
				return false
			}
			head = head[end+1:]
		default:
			return bytes.HasPrefix(head, []byte("<svg")) && len(head) > 4 && strings.ContainsRune(" \t\r\n>/", rune(head[4]))
		}
	}
}
