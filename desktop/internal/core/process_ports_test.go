package core

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"
)

// portsFixture mirrors rust/fixtures/process-lifecycle/listening-ports-v1.json in Core.
type portsFixture struct {
	Cases []struct {
		Name     string                 `json:"name"`
		Request  json.RawMessage        `json:"request"`
		Expected ListeningPortsResponse `json:"expected"`
	} `json:"cases"`
	Invalid []struct {
		Name    string          `json:"name"`
		Request json.RawMessage `json:"request"`
	} `json:"invalid"`
}

func typedPortsRequest(t *testing.T, raw json.RawMessage) (ListeningPortsRequest, bool) {
	t.Helper()
	var request ListeningPortsRequest
	if json.Unmarshal(raw, &request) != nil {
		return ListeningPortsRequest{}, false
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var want, got map[string]any
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &got); err != nil {
		t.Fatal(err)
	}
	// Core's request schema defaults missing sockets/processes arrays to empty; client sends [].
	if _, ok := want["sockets"]; !ok {
		want["sockets"] = []any{}
	}
	return request, reflect.DeepEqual(got, want)
}

// TestProcessListeningPortsFollowsTheContractFixture replays every valid and invalid case in
// listening-ports-v1.json through the linked Core FFI.
func TestProcessListeningPortsFollowsTheContractFixture(t *testing.T) {
	var fixture portsFixture
	if err := json.Unmarshal(readLifecycleFixture(t, "listening-ports-v1.json"), &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 || len(fixture.Invalid) == 0 {
		t.Fatal("listening-ports-v1.json has no cases")
	}
	ctx := debugContext(t)
	client := NewClient()
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			request, exact := typedPortsRequest(t, test.Request)
			if !exact {
				t.Fatalf("the client cannot encode request %s losslessly", test.Request)
			}
			got, err := client.ProcessListeningPorts(ctx, request)
			if err != nil {
				t.Fatal(err)
			}
			test.Expected.Ports = nonNil(test.Expected.Ports)
			if !reflect.DeepEqual(got, test.Expected) {
				t.Fatalf("ports = %+v, want %+v", got, test.Expected)
			}
		})
	}
	sent := 0
	for _, test := range fixture.Invalid {
		request, exact := typedPortsRequest(t, test.Request)
		if !exact {
			continue
		}
		sent++
		t.Run(test.Name, func(t *testing.T) {
			_, err := client.ProcessListeningPorts(ctx, request)
			var coreErr *Error
			if !errors.As(err, &coreErr) || coreErr.Code != CodeInvalidRequest {
				t.Fatalf("error = %v, want %s", err, CodeInvalidRequest)
			}
		})
	}
	if sent == 0 {
		t.Fatal("no invalid listening-ports request was exercised")
	}
}
