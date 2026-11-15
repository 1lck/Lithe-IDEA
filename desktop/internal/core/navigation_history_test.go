package core

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestReduceNavigationHistorySharedFixtures(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("editor/navigation-history-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name    string
			Request struct {
				State NavigationHistory
				Event NavigationHistoryEvent
			}
			ExpectedError string
			Expected      struct {
				State       NavigationHistory
				Destination *NavigationLocation
			}
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			state, destination, err := client.ReduceNavigationHistory(testContext(t), c.Request.State, c.Request.Event)
			if c.ExpectedError != "" {
				if err == nil {
					t.Fatalf("no error, want %s", c.ExpectedError)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			got, _ := json.Marshal(struct {
				State       NavigationHistory
				Destination *NavigationLocation
			}{state, destination})
			want, _ := json.Marshal(c.Expected)
			var g, w any
			_ = json.Unmarshal(got, &g)
			_ = json.Unmarshal(want, &w)
			gj, _ := json.Marshal(g)
			wj, _ := json.Marshal(w)
			if string(gj) != string(wj) {
				t.Fatalf("got %s\nwant %s", gj, wj)
			}
		})
	}
}
