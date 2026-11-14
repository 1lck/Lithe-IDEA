package ai

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCommitFixture(t *testing.T) {
	var fixture struct {
		Provider  PlanProvider   `json:"provider"`
		Options   CommitOptions  `json:"options"`
		Files     []EvidenceFile `json:"files"`
		Responses []struct {
			Protocol string          `json:"protocol"`
			Body     json.RawMessage `json:"body"`
		} `json:"responses"`
		ExpectedMessage string `json:"expectedMessage"`
	}
	readCoreFixtureJSON(t, "ai/commit-generation-v1.json", &fixture)
	client := testClient()
	for i := range fixture.Files {
		n := len([]rune(fixture.Files[i].Diff))
		fixture.Files[i].OriginalCharacters = &n
	}
	request, err := client.PlanCommit(testContext(t), fixture.Provider, fixture.Options, fixture.Files)
	if err != nil {
		t.Fatal(err)
	}
	if request.URL != "https://api.example.com/v1/responses" || !strings.Contains(string(request.Body), "max_output_tokens") {
		t.Fatalf("request = %s %s", request.URL, request.Body)
	}
	for _, response := range fixture.Responses {
		message, err := client.DecodeCommitMessage(testContext(t), response.Protocol, response.Body, false)
		if err != nil || message != fixture.ExpectedMessage {
			t.Fatalf("%s decoded %q %v", response.Protocol, message, err)
		}
	}
}

func TestInlineEditFixture(t *testing.T) {
	var fixture struct {
		Edit  InlineEdit `json:"edit"`
		Plans []struct {
			Case     string             `json:"case"`
			Provider InlineEditProvider `json:"provider"`
			Model    InlineEditModel    `json:"model"`
			Expected struct {
				URL        string `json:"url"`
				Credential struct {
					Required bool   `json:"required"`
					Header   string `json:"header"`
					Scheme   string `json:"scheme"`
				} `json:"credential"`
			} `json:"expected"`
		} `json:"plans"`
	}
	readCoreFixtureJSON(t, "ai/inline-edit-v1.json", &fixture)
	client := testClient()
	checked := 0
	for _, item := range fixture.Plans {
		if item.Expected.URL == "" {
			continue
		}
		plan, err := client.PlanInlineEdit(testContext(t), item.Provider, item.Model, fixture.Edit)
		if err != nil {
			t.Fatalf("%s: %v", item.Case, err)
		}
		if plan.URL != item.Expected.URL || plan.Credential.Required != item.Expected.Credential.Required ||
			plan.Credential.Header != item.Expected.Credential.Header || plan.Credential.Scheme != item.Expected.Credential.Scheme {
			t.Fatalf("%s: plan = %#v", item.Case, plan)
		}
		checked++
	}
	if checked == 0 {
		t.Fatal("no plan checked")
	}
	text, err := client.DecodeInlineEdit(testContext(t), "chatCompletions", json.RawMessage(`{"choices":[{"message":{"content":"`+"```go\\nx := 1\\n```"+`"}}]}`))
	if err != nil || text != "x := 1" {
		t.Fatalf("decoded %q %v", text, err)
	}
}
