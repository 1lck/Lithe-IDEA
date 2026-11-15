package workbench

import (
	"context"
	"errors"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// debugAnnouncementLineLimit bounds the unfinished line kept per output stream
// while the announcement is awaited. A longer line goes to the console unread.
const debugAnnouncementLineLimit = 64 << 10

// openAnnouncedTransport starts a tcpAnnounced adapter: its process, whose
// output Core reads line by line until a line announces the loopback endpoint
// the adapter listens on, and the stream Core's transport lifecycle drives to
// that endpoint. Core owns which line is the announcement, which endpoints may
// be connected to and every deadline; the host splits lines, keeps the process
// and the socket, and runs the effects Core returns. Output that is not the
// announcement, and all output after it, is the debug console's.
func (a *App) openAnnouncedTransport(ctx context.Context, p *project, session *debugSession, prepared preparedDebugLaunch, messages i18n.DebugMessages) error {
	reader := newDebugAnnouncementReader(
		func(stream, line string) (core.DebugAnnouncement, error) {
			readContext, cancel := context.WithTimeout(session.ctx, debugOperationTimeout)
			defer cancel()
			return a.kernel.ReadDebugAnnouncement(readContext, prepared.Endpoint, stream, line)
		},
		func(text string) { a.post(func(a *App) { a.appendDebugOutput(p, session, text) }) },
		errors.New(messages.InvalidEndpoint),
	)
	hooks := a.debugStreamHooks(p, session, messages)
	hooks.Discover = reader.wait
	transport := newDebugTransport(a.kernel, session.id+"-transport", hooks)
	if !session.setTransport(transport) {
		return context.Canceled
	}
	session.hosted = transport
	// The stream starts before the process: Core's default discovery limit then
	// bounds the process start and its announcement together, and a process that
	// exits at once finds a started stream to stop.
	if err := transport.Start(nil); err != nil {
		return err
	}
	return a.startAdapterProcess(ctx, p, session, prepared, nil, reader.observe, errors.New(messages.NotAnnounced))
}

// debugAnnouncedEndpoint is the result of waiting for an announcement: the
// endpoint to connect to, or why there is none.
type debugAnnouncedEndpoint struct {
	host string
	port int
	err  error
}

// debugAnnouncementReader splits a tcpAnnounced adapter's output into lines
// and asks Core about each one until one decides the endpoint. The process's
// two output streams call observe concurrently, so a mutex orders them.
type debugAnnouncementReader struct {
	// read asks Core whether one line, without its line break, announces the endpoint.
	read func(stream, line string) (core.DebugAnnouncement, error)
	// console shows output that is not the announcement.
	console func(text string)
	// invalid is what an announced endpoint Core refuses reports.
	invalid error
	// found receives the one result once a line decided it.
	found chan debugAnnouncedEndpoint

	mu   sync.Mutex
	done bool
	// pending is each stream's unfinished line; overlong marks a stream whose
	// current line passed the limit and goes to the console unread to its end.
	pending  map[buildprocess.Stream]string
	overlong map[buildprocess.Stream]bool
}

func newDebugAnnouncementReader(read func(stream, line string) (core.DebugAnnouncement, error), console func(text string), invalid error) *debugAnnouncementReader {
	return &debugAnnouncementReader{
		read:     read,
		console:  console,
		invalid:  invalid,
		found:    make(chan debugAnnouncedEndpoint, 1),
		pending:  make(map[buildprocess.Stream]string),
		overlong: make(map[buildprocess.Stream]bool),
	}
}

// wait is the transport's Discover: it returns once a line decided the
// endpoint, or when the transport stops waiting.
func (r *debugAnnouncementReader) wait(ctx context.Context) (string, int, error) {
	select {
	case endpoint := <-r.found:
		return endpoint.host, endpoint.port, endpoint.err
	case <-ctx.Done():
		return "", 0, ctx.Err()
	}
}

// observe receives one chunk of the process's output, which may hold part of
// a line or several lines.
func (r *debugAnnouncementReader) observe(stream buildprocess.Stream, text string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.done {
		r.console(text)
		return
	}
	text = r.pending[stream] + text
	delete(r.pending, stream)
	var shown strings.Builder
	for !r.done {
		end := strings.IndexByte(text, '\n')
		if end < 0 {
			break
		}
		line := text[:end+1]
		text = text[end+1:]
		if r.overlong[stream] {
			delete(r.overlong, stream)
			shown.WriteString(line)
			continue
		}
		if !r.announces(stream, strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")) {
			shown.WriteString(line)
		}
	}
	switch {
	case r.done || r.overlong[stream]:
		shown.WriteString(text)
	case len(text) > debugAnnouncementLineLimit:
		r.overlong[stream] = true
		shown.WriteString(text)
	default:
		r.pending[stream] = text
	}
	if shown.Len() > 0 {
		r.console(shown.String())
	}
}

// announces asks Core about one complete line and reports whether the line is
// the announcement itself, which the console does not show. A line that
// announces an endpoint Core refuses, or a failed reading, also ends the wait.
func (r *debugAnnouncementReader) announces(stream buildprocess.Stream, line string) bool {
	reading, err := r.read(string(stream), line)
	switch {
	case err != nil:
		r.finish(debugAnnouncedEndpoint{err: err})
	case reading.Status == "announced":
		r.finish(debugAnnouncedEndpoint{host: reading.Host, port: reading.Port})
		return true
	case reading.Status == "invalid":
		r.finish(debugAnnouncedEndpoint{err: r.invalid})
	}
	return false
}

func (r *debugAnnouncementReader) finish(endpoint debugAnnouncedEndpoint) {
	r.done = true
	r.found <- endpoint
	// Everything left unread is the debuggee's output now.
	for stream, text := range r.pending {
		if text != "" {
			r.console(text)
		}
		delete(r.pending, stream)
	}
}
