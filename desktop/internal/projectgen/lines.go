package projectgen

import (
	"os/exec"
	"strings"
	"sync"
)

func lookPath(command string) (string, error) { return exec.LookPath(command) }

// maxLine bounds one reported line, so a binary or minified output cannot grow a window row without limit.
const maxLine = 2048

// lineSplitter turns the output chunks of a process into lines and keeps the
// last few kilobytes for a failure message. Both pipes of a process write to it
// from two goroutines, hence the lock.
type lineSplitter struct {
	mu      sync.Mutex
	emit    func(string)
	pending strings.Builder
	last    []string
	size    int
}

func newLineSplitter(emit func(string)) *lineSplitter { return &lineSplitter{emit: emit} }

func (s *lineSplitter) write(chunk string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		index := strings.IndexAny(chunk, "\r\n")
		if index < 0 {
			if s.pending.Len() < maxLine {
				s.pending.WriteString(chunk)
			}
			return
		}
		if s.pending.Len() < maxLine {
			s.pending.WriteString(chunk[:index])
		}
		s.line()
		chunk = chunk[index+1:]
	}
}

func (s *lineSplitter) line() {
	text := strings.TrimRight(s.pending.String(), " \t")
	s.pending.Reset()
	if text == "" {
		return
	}
	if len(text) > maxLine {
		text = text[:maxLine]
	}
	s.last = append(s.last, text)
	s.size += len(text)
	for s.size > outputTail && len(s.last) > 1 {
		s.size -= len(s.last[0])
		s.last = s.last[1:]
	}
	s.emit(text)
}

func (s *lineSplitter) flush() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending.Len() > 0 {
		s.line()
	}
}

func (s *lineSplitter) tail() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.last, "\n")
}
