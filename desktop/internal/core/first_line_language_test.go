package core

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
)

func TestFirstLineLanguageSharedFixture(t *testing.T) {
	data, err := os.ReadFile(contractfixture.CoreFixture("plugins/first-line-match-v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	type matchResult struct {
		LanguageID json.RawMessage `json:"languageID"`
	}
	var fixture struct {
		SchemaVersion int
		Command       string
		Cases         []struct {
			Name      string
			Payload   json.RawMessage
			Expected  struct{ Data matchResult }
			ErrorCode ErrorCode
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.SchemaVersion != 1 || fixture.Command != "languages.matchFirstLine" || len(fixture.Cases) == 0 {
		t.Fatal("invalid first-line language fixture")
	}
	client := NewClient()
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			var result matchResult
			err := client.Execute(testContext(t), fixture.Command, c.Payload, &result)
			if c.ErrorCode != "" {
				requireCode(t, err, c.ErrorCode)
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if len(c.Expected.Data.LanguageID) == 0 || string(result.LanguageID) != string(c.Expected.Data.LanguageID) {
				t.Fatalf("languageID = %s, want %s", result.LanguageID, c.Expected.Data.LanguageID)
			}
		})
	}
}
