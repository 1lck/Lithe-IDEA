package legacyimport

import (
	"bytes"
	"errors"
)

// errTooLarge says a source is bigger than an earlier client ever wrote.
var errTooLarge = errors.New("the earlier preferences are too large to read")

// limitedBuffer fails a write past limit bytes, which ends the command writing it.
type limitedBuffer struct {
	buffer *bytes.Buffer
	limit  int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.buffer.Len()+len(p) > b.limit {
		return 0, errTooLarge
	}
	return b.buffer.Write(p)
}
