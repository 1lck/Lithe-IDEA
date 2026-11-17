package core

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

// The shared fixtures run through the real kernel, so a bridge type that drifted from the JSON
// Core emits fails here.
func TestQueryReferencesSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("lsp/references-query-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name     string           `json:"name"`
			Request  ReferencesQuery  `json:"request"`
			Response ReferencesResult `json:"response"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			got, err := client.QueryReferences(testContext(t), c.Request)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, c.Response) {
				t.Fatalf("result = %+v, want %+v", got, c.Response)
			}
		})
	}
}

func TestReferenceLinesSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("lsp/references-lines-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name     string                `json:"name"`
			Request  ReferenceLinesRequest `json:"request"`
			Response struct {
				Lines []ReferenceLine `json:"lines"`
			} `json:"response"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			got, err := client.ReferenceLines(testContext(t), c.Request)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, c.Response.Lines) {
				t.Fatalf("lines = %+v, want %+v", got, c.Response.Lines)
			}
		})
	}
}
