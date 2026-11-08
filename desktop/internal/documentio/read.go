package documentio

import (
	"errors"
	"io"
)

// ReadFile opens the object without following the final symlink, verifies that
// the opened object is a regular file, and bounds the bytes actually read. It
// permits hard links: their effect matters only when a later write is requested.
func ReadFile(path string) (data []byte, err error) {
	source, info, err := openReadable(path)
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, source.Close()) }()
	if info.Size() > maxBytes {
		return nil, ErrTooLarge
	}
	return readBounded(source, info.Size())
}

// readBounded enforces the budget even when a file grows after its size check.
// The stat-sized first read avoids repeated allocations for ordinary files.
func readBounded(source io.Reader, size int64) ([]byte, error) {
	if size > maxBytes {
		return nil, ErrTooLarge
	}
	initial := max(int64(512), size+1)
	buffer := make([]byte, int(initial))
	n, err := io.ReadFull(source, buffer)
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return buffer[:n], nil
	}
	if err != nil {
		return nil, err
	}
	if n > maxBytes {
		return nil, ErrTooLarge
	}
	more, err := io.ReadAll(io.LimitReader(source, int64(maxBytes+1-n)))
	if err != nil {
		return nil, err
	}
	if n+len(more) > maxBytes {
		return nil, ErrTooLarge
	}
	return append(buffer[:n], more...), nil
}
