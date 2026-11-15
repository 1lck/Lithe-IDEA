package documentio

import (
	"errors"
	"io"
)

// ReadFile opens the object without following the final symlink, verifies that
// the opened object is a regular file, and bounds the bytes actually read. It
// permits hard links: their effect matters only when a later write is requested.
func ReadFile(path string) (data []byte, err error) {
	return ReadFileLimit(path, maxBytes)
}

// ReadFileLimit reads a regular file without following its final symlink and
// refuses content beyond limit, including bytes added after the size check.
// It is intended for small native metadata whose limit comes from a Core contract.
func ReadFileLimit(path string, limit int64) (data []byte, err error) {
	if limit < 0 || limit > maxBytes {
		return nil, ErrTooLarge
	}
	source, info, err := openReadable(path)
	if err != nil {
		return nil, err
	}
	defer func() { err = errors.Join(err, source.Close()) }()
	if info.Size() > limit {
		return nil, ErrTooLarge
	}
	return readBoundedLimit(source, info.Size(), limit)
}

// readBoundedLimit enforces the budget even when a file grows after its size check.
// The stat-sized first read avoids repeated allocations for ordinary files.
func readBoundedLimit(source io.Reader, size, limit int64) ([]byte, error) {
	if size > limit {
		return nil, ErrTooLarge
	}
	initial := min(max(int64(512), size+1), limit+1)
	buffer := make([]byte, int(initial))
	n, err := io.ReadFull(source, buffer)
	if int64(n) > limit {
		return nil, ErrTooLarge
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return buffer[:n], nil
	}
	if err != nil {
		return nil, err
	}
	more, err := io.ReadAll(io.LimitReader(source, limit+1-int64(n)))
	if err != nil {
		return nil, err
	}
	if int64(n+len(more)) > limit {
		return nil, ErrTooLarge
	}
	return append(buffer[:n], more...), nil
}
