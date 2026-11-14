package core

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// TestDecodeOutputStyleFollowsTheCoreFixture replays every case of the shared
// fixture through the client, passing each answer's state to the next chunk:
// Core decides the text and ranges, the client only carries them.
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
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client := NewClient()
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			var state json.RawMessage
			lines := []OutputLine{}
			var open OutputLine
			for _, chunk := range test.Chunks {
				decoded, err := client.DecodeOutputStyle(ctx, chunk, state)
				if err != nil {
					t.Fatal(err)
				}
				lines = append(lines, decoded.Lines...)
				open, state = decoded.Open, decoded.State
			}
			want := test.Lines
			if want == nil {
				want = []OutputLine{}
			}
			if !reflect.DeepEqual(lines, want) {
				got, _ := json.Marshal(lines)
				expected, _ := json.Marshal(want)
				t.Fatalf("lines = %s, want %s", got, expected)
			}
			if !reflect.DeepEqual(open, test.Open) {
				got, _ := json.Marshal(open)
				expected, _ := json.Marshal(test.Open)
				t.Fatalf("open = %s, want %s", got, expected)
			}
		})
	}
}

// TestDecodeOutputStyleRejectsAForeignState: a state Core never returned is an
// invalid request, so a console cannot carry another console's or a stale state.
func TestDecodeOutputStyleRejectsAForeignState(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := NewClient().DecodeOutputStyle(ctx, "x", json.RawMessage(`{"line":{"text":"ab","spans":[{"start":1,"length":5,"style":{"bold":true}}]}}`)); err == nil {
		t.Fatal("a state whose range runs past its line was accepted")
	}
}
