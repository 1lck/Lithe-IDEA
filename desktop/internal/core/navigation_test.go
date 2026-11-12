package core

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestParseNavigationInputSharedFixtures(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/editor/navigation-input-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name, Input string
			Target      *NavigationTarget
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			got, err := client.ParseNavigationInput(testContext(t), c.Input)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, c.Target) {
				t.Fatalf("target = %+v, want %+v", got, c.Target)
			}
		})
	}
}
