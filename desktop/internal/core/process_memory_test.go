package core

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"
)

// memoryFixture is rust/fixtures/process-lifecycle/memory-summary-v1.json of the linked Core.
type memoryFixture struct {
	Cases []struct {
		Name     string          `json:"name"`
		Request  json.RawMessage `json:"request"`
		Expected MemorySummary   `json:"expected"`
	} `json:"cases"`
	Invalid []struct {
		Name    string          `json:"name"`
		Request json.RawMessage `json:"request"`
	} `json:"invalid"`
}

// typedMemoryRequest decodes raw into the client's request and reports whether encoding it
// again gives the same document, so the client sends what the fixture holds.
func typedMemoryRequest(t *testing.T, raw json.RawMessage) (MemoryRequest, bool) {
	t.Helper()
	var request MemoryRequest
	if json.Unmarshal(raw, &request) != nil {
		return MemoryRequest{}, false
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var want, got any
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &got); err != nil {
		t.Fatal(err)
	}
	return request, reflect.DeepEqual(got, want)
}

// TestProcessMemorySummarizeFollowsTheContractFixture replays every summary: Core attributes
// and sums, the client only carries the table and the roles.
func TestProcessMemorySummarizeFollowsTheContractFixture(t *testing.T) {
	var fixture memoryFixture
	if err := json.Unmarshal(readLifecycleFixture(t, "memory-summary-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 || len(fixture.Invalid) == 0 {
		t.Fatal("the fixture has no cases")
	}
	ctx := debugContext(t)
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			request, exact := typedMemoryRequest(t, test.Request)
			if !exact {
				t.Fatalf("the client cannot send the request %s as it is", test.Request)
			}
			got, err := NewClient().SummarizeProcessMemory(ctx, request)
			if err != nil {
				t.Fatal(err)
			}
			test.Expected.Categories = nonNil(test.Expected.Categories)
			test.Expected.Entries = nonNil(test.Expected.Entries)
			if !reflect.DeepEqual(got, test.Expected) {
				t.Fatalf("summary = %+v, want %+v", got, test.Expected)
			}
		})
	}
	// Some invalid requests, such as negative bytes, cannot be written with the client's
	// types; the ones that can are rejected as invalid.
	sent := 0
	for _, test := range fixture.Invalid {
		request, exact := typedMemoryRequest(t, test.Request)
		if !exact {
			continue
		}
		sent++
		t.Run(test.Name, func(t *testing.T) {
			_, err := NewClient().SummarizeProcessMemory(ctx, request)
			var coreErr *Error
			if !errors.As(err, &coreErr) || coreErr.Code != CodeInvalidRequest {
				t.Fatalf("error = %v, want %s", err, CodeInvalidRequest)
			}
		})
	}
	if sent == 0 {
		t.Fatal("no invalid request could be sent")
	}
}
