package plugintrust

import (
	"encoding/json"
	"testing"
)

func TestCompactProgramFitsOneLine(t *testing.T) {
	program := json.RawMessage("{\n  \"kind\": \"runtime\",\n  \"command\": \"java\"\n}")
	if got := CompactProgram(program); got != `{"kind":"runtime","command":"java"}` {
		t.Fatalf("compact = %q", got)
	}
	if got := CompactProgram(json.RawMessage("{broken")); got != "{broken" {
		t.Fatalf("compact = %q", got)
	}
}
