package plugintrust

import (
	"bytes"
	"encoding/json"
)

// CompactProgram renders an opaque program declaration without adding line breaks.
func CompactProgram(program json.RawMessage) string {
	var buffer bytes.Buffer
	if err := json.Compact(&buffer, program); err != nil {
		return string(program)
	}
	return buffer.String()
}
