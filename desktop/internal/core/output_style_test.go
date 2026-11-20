package core

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// TestDecodeOutputStyleFollowsTheCoreFixture replays every case of the shared
// style fixture through the client as process output bytes, passing each
// answer's state to the next chunk: Core decides the text and ranges, the
// client only carries them. The chunks are UTF-8, so no policy decodes them
// the same as text.
func TestDecodeOutputStyleFollowsTheCoreFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("terminal/output-style-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name   string       `json:"name"`
			Chunks []string     `json:"chunks"`
			Lines  []OutputLine `json:"lines"`
			Open   OutputLine   `json:"open"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("the fixture has no cases")
	}
	client := NewClient()
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			chunks := make([][]byte, len(test.Chunks))
			for index, chunk := range test.Chunks {
				chunks[index] = []byte(chunk)
			}
			lines, open := replayOutputDecode(t, client, chunks, OutputEncodingPolicy{})
			assertOutputDecode(t, lines, open, test.Lines, test.Open)
		})
	}
}

// TestDecodeOutputStyleFollowsTheEncodingFixture replays the shared encoding
// fixture: each case's hexadecimal chunks go to Core as bytes with the case's
// policy, so the client's policy fields must be the ones Core reads.
func TestDecodeOutputStyleFollowsTheEncodingFixture(t *testing.T) {
	fixture := readOutputEncodingFixture(t)
	if len(fixture.Decode) == 0 {
		t.Fatal("the fixture has no decode cases")
	}
	client := NewClient()
	for _, test := range fixture.Decode {
		t.Run(test.Name, func(t *testing.T) {
			policy := strictOutputEncodingPolicy(t, test.Encoding)
			chunks := make([][]byte, len(test.Chunks))
			for index, chunk := range test.Chunks {
				decoded, err := hex.DecodeString(chunk)
				if err != nil {
					t.Fatal(err)
				}
				chunks[index] = decoded
			}
			lines, open := replayOutputDecode(t, client, chunks, policy)
			assertOutputDecode(t, lines, open, test.Lines, test.Open)
		})
	}
}

// TestResolveOutputEncodingFollowsTheFixture checks the candidates and selectable
// encodings. Invalid policy members are sent verbatim to exercise Core's rejection.
func TestResolveOutputEncodingFollowsTheFixture(t *testing.T) {
	fixture := readOutputEncodingFixture(t)
	if len(fixture.Resolve) == 0 {
		t.Fatal("the fixture has no resolve cases")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client := NewClient()
	for _, test := range fixture.Resolve {
		t.Run(test.Name, func(t *testing.T) {
			// encoding/json matches struct fields without regard to case. Send unknown
			// keys verbatim so "Windows" is not silently turned into "windows".
			var members map[string]json.RawMessage
			if err := json.Unmarshal(test.Policy, &members); err != nil {
				t.Fatal(err)
			}
			unknown := false
			for key := range members {
				unknown = unknown || (key != "setting" && key != "declared" && key != "windows")
			}
			var resolved OutputEncodings
			var err error
			if unknown {
				err = client.Execute(ctx, "outputEncoding.resolve", test.Policy, &resolved)
			} else {
				resolved, err = client.ResolveOutputEncoding(ctx, strictOutputEncodingPolicy(t, test.Policy))
			}
			if test.Error != "" {
				var coreErr *Error
				if !errors.As(err, &coreErr) || string(coreErr.Code) != test.Error {
					t.Fatalf("err = %v, want %s", err, test.Error)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(resolved.Candidates, test.Candidates) {
				t.Fatalf("candidates = %q, want %q", resolved.Candidates, test.Candidates)
			}
			if !reflect.DeepEqual(resolved.Encodings, fixture.Encodings) {
				t.Fatalf("encodings = %q, want %q", resolved.Encodings, fixture.Encodings)
			}
		})
	}
}

// TestDecodeOutputStyleRejectsAForeignState: a state Core never returned is an
// invalid request, so a console cannot carry another console's or a stale state.
func TestDecodeOutputStyleRejectsAForeignState(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := NewClient().DecodeOutputStyle(ctx, []byte("x"), OutputEncodingPolicy{}, json.RawMessage(`{"line":{"text":"ab","spans":[{"start":1,"length":5,"style":{"bold":true}}]}}`)); err == nil {
		t.Fatal("a state whose range runs past its line was accepted")
	}
}

type outputEncodingFixture struct {
	Encodings []string `json:"encodings"`
	Decode    []struct {
		Name     string          `json:"name"`
		Encoding json.RawMessage `json:"encoding"`
		Chunks   []string        `json:"chunks"`
		Lines    []OutputLine    `json:"lines"`
		Open     OutputLine      `json:"open"`
	} `json:"decode"`
	Resolve []struct {
		Name       string          `json:"name"`
		Policy     json.RawMessage `json:"policy"`
		Candidates []string        `json:"candidates"`
		Error      string          `json:"error"`
	} `json:"resolve"`
}

func readOutputEncodingFixture(t *testing.T) outputEncodingFixture {
	t.Helper()
	data, err := os.ReadFile(contractfixture.CoreFixture("terminal/output-encoding-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture outputEncodingFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	return fixture
}

// strictOutputEncodingPolicy reads a fixture policy, failing on a member the
// client has no field for; an absent policy is the empty one.
func strictOutputEncodingPolicy(t *testing.T, raw json.RawMessage) OutputEncodingPolicy {
	t.Helper()
	var policy OutputEncodingPolicy
	if len(raw) == 0 {
		return policy
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&policy); err != nil {
		t.Fatalf("policy %s: %v", raw, err)
	}
	return policy
}

// replayOutputDecode sends chunks in order, passing back each answer's state,
// and returns every finished line and the last open line.
func replayOutputDecode(t *testing.T, client *Client, chunks [][]byte, policy OutputEncodingPolicy) ([]OutputLine, OutputLine) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var state json.RawMessage
	lines := []OutputLine{}
	var open OutputLine
	for _, chunk := range chunks {
		decoded, err := client.DecodeOutputStyle(ctx, chunk, policy, state)
		if err != nil {
			t.Fatal(err)
		}
		lines = append(lines, decoded.Lines...)
		open, state = decoded.Open, decoded.State
	}
	return lines, open
}

func assertOutputDecode(t *testing.T, lines []OutputLine, open OutputLine, wantLines []OutputLine, wantOpen OutputLine) {
	t.Helper()
	if wantLines == nil {
		wantLines = []OutputLine{}
	}
	if !reflect.DeepEqual(lines, wantLines) {
		got, _ := json.Marshal(lines)
		expected, _ := json.Marshal(wantLines)
		t.Fatalf("lines = %s, want %s", got, expected)
	}
	if !reflect.DeepEqual(open, wantOpen) {
		got, _ := json.Marshal(open)
		expected, _ := json.Marshal(wantOpen)
		t.Fatalf("open = %s, want %s", got, expected)
	}
}
