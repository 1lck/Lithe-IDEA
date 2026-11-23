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

func TestFileAssociationsSharedFixture(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err := os.ReadFile(contractfixture.CoreFixture("application/file-associations-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	type fixtureCase struct {
		Name, Command     string
		Payload, Expected json.RawMessage
	}
	var fixture struct{ Catalog, Plans, Errors []fixtureCase }
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	client := NewClient()
	for section, cases := range map[string][]fixtureCase{
		"application.fileAssociations.catalog": fixture.Catalog,
		"application.fileAssociations.plan":    fixture.Plans,
	} {
		for _, test := range cases {
			t.Run(test.Name, func(t *testing.T) {
				var actual, expected any
				if err := client.Execute(ctx, section, test.Payload, &actual); err != nil {
					t.Fatal(err)
				}
				if err := json.Unmarshal(test.Expected, &expected); err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(actual, expected) {
					t.Fatalf("got %+v, want %+v", actual, expected)
				}
			})
		}
	}
	for _, test := range fixture.Errors {
		t.Run(test.Name, func(t *testing.T) {
			var result any
			if err := client.Execute(ctx, test.Command, test.Payload, &result); err == nil {
				t.Fatal("invalid association plan accepted")
			}
		})
	}
}
