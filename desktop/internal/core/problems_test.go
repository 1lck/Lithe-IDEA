package core

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// The shared fixture is the contract between Core and every host. Running it
// through the real kernel catches a bridge type that drifted from the JSON the
// kernel actually emits.
func TestQueryProblemsSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/lsp/problems-query-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name     string         `json:"name"`
			Request  ProblemsQuery  `json:"request"`
			Response ProblemsResult `json:"response"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			got, err := client.QueryProblems(testContext(t), c.Request)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, c.Response) {
				t.Fatalf("result = %+v, want %+v", got, c.Response)
			}
		})
	}
}
