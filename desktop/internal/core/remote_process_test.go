package core

import (
	"encoding/json"
	"errors"
	"slices"
	"testing"
)

// A host process's events reach their callbacks in order: started with its process id, then its
// output as bytes. Events that are not the process's and empty output are not delivered. Output of
// an unknown stream or that is not base64 is an error, since the console would miss it.
func TestRemoteProcessEventsReachTheirCallbacks(t *testing.T) {
	var got []string
	events := RemoteProcessEvents{
		Started: func(processID uint64, pid int) {
			if processID == 7 && pid == 4242 {
				got = append(got, "started")
			}
		},
		Output: func(stream string, data []byte) { got = append(got, stream+":"+string(data)) },
	}
	for _, raw := range []string{
		`{"type":"progress","event":"process.output","params":{"stream":"stdout","data":"aGk="}}`,
		`{"type":"remote","event":"process.started","params":{"processId":7,"pid":4242}}`,
		`{"type":"remote","event":"process.output","params":{"stream":"stdout","data":"aGk="}}`,
		`{"type":"remote","event":"process.output","params":{"stream":"stderr","data":""}}`,
		`{"type":"remote","event":"process.output","params":{"stream":"stderr","data":"b29wcw=="}}`,
		`{"type":"remote","event":"terminal.output","params":{}}`,
	} {
		if err := deliverRemoteProcessEvent(json.RawMessage(raw), events); err != nil {
			t.Fatalf("event %d: %v", len(got), err)
		}
	}
	if want := []string{"started", "stdout:hi", "stderr:oops"}; !slices.Equal(got, want) {
		t.Fatalf("delivered %d events, want %d", len(got), len(want))
	}
	for _, bad := range []string{
		`{"type":"remote","event":"process.output","params":{"stream":"stdin","data":"aGk="}}`,
		`{"type":"remote","event":"process.output","params":{"stream":"stdout","data":"not base64!"}}`,
	} {
		if err := deliverRemoteProcessEvent(json.RawMessage(bad), events); !errors.Is(err, errRemoteProcessEvent) {
			t.Fatalf("an unreadable event was %v", err)
		}
	}
}
