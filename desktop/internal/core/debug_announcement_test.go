package core

import (
	"encoding/json"
	"errors"
	"testing"
)

// TestDebugAnnouncementFollowsTheContractFixture reads every line of the shared
// announcement fixture through the typed wrapper: a case with a result must read
// exactly that, a case without one must fail as an invalid request. A case whose
// request does not have exactly the endpoint, stream and line fields cannot be
// sent through the wrapper, so Core's own tests cover it instead.
func TestDebugAnnouncementFollowsTheContractFixture(t *testing.T) {
	var fixture struct {
		Cases []struct {
			Name   string                     `json:"name"`
			Input  map[string]json.RawMessage `json:"input"`
			Result *DebugAnnouncement         `json:"result"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(readDebugFixture(t, "adapter-announcements-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("the announcement fixture has no cases")
	}
	ctx := debugContext(t)
	client := NewClient()
	for _, item := range fixture.Cases {
		t.Run(item.Name, func(t *testing.T) {
			var stream, line string
			endpoint, hasEndpoint := item.Input["endpoint"]
			rawStream, hasStream := item.Input["stream"]
			rawLine, hasLine := item.Input["line"]
			if len(item.Input) != 3 || !hasEndpoint || !hasStream || !hasLine ||
				json.Unmarshal(rawStream, &stream) != nil || json.Unmarshal(rawLine, &line) != nil {
				t.Skip("the wrapper always sends exactly the endpoint and the stream and line strings")
			}
			got, err := client.ReadDebugAnnouncement(ctx, endpoint, stream, line)
			if item.Result == nil {
				var coreErr *Error
				if !errors.As(err, &coreErr) || coreErr.Code != CodeInvalidRequest {
					t.Fatalf("reading = %+v, %v; want an invalid_request error", got, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != *item.Result {
				t.Fatalf("reading = %+v, want %+v", got, *item.Result)
			}
		})
	}
}
