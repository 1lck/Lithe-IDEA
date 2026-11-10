package core

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAICommitFixture(t *testing.T) {
	var fixture struct {
		Provider  AICommitProvider `json:"provider"`
		Options   AICommitOptions  `json:"options"`
		Files     []AICommitFile   `json:"files"`
		Responses []struct {
			Protocol string          `json:"protocol"`
			Body     json.RawMessage `json:"body"`
		} `json:"responses"`
		ExpectedMessage string `json:"expectedMessage"`
	}
	readSharedJSON(t, "fixtures/ai/commit-generation-v1.json", &fixture)
	client := NewClient()
	for i := range fixture.Files {
		n := len([]rune(fixture.Files[i].Diff))
		fixture.Files[i].OriginalCharacters = &n
	}
	request, err := client.AIPlanCommit(testContext(t), fixture.Provider, fixture.Options, fixture.Files)
	if err != nil {
		t.Fatal(err)
	}
	if request.URL != "https://api.example.com/v1/responses" || !strings.Contains(string(request.Body), "max_output_tokens") {
		t.Fatalf("request = %s %s", request.URL, request.Body)
	}
	for _, response := range fixture.Responses {
		message, err := client.AIDecodeCommitMessage(testContext(t), response.Protocol, response.Body, false)
		if err != nil || message != fixture.ExpectedMessage {
			t.Fatalf("%s decoded %q %v", response.Protocol, message, err)
		}
	}
	budget, err := client.AICommitInputBudget(testContext(t), 8000, []int{100, 50000})
	if err != nil || len(budget) != 2 || budget[0].Truncated || !budget[1].Truncated {
		t.Fatalf("budget = %#v %v", budget, err)
	}
}

func TestAIInlineEditFixture(t *testing.T) {
	var fixture struct {
		Edit  AIInlineEdit `json:"edit"`
		Plans []struct {
			Case     string               `json:"case"`
			Provider AIInlineEditProvider `json:"provider"`
			Model    AIInlineEditModel    `json:"model"`
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
	readSharedJSON(t, "fixtures/ai/inline-edit-v1.json", &fixture)
	client := NewClient()
	checked := 0
	for _, item := range fixture.Plans {
		if item.Expected.URL == "" {
			continue
		}
		plan, err := client.AIInlineEditPlan(testContext(t), item.Provider, item.Model, fixture.Edit)
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
	text, err := client.AIInlineEditDecode(testContext(t), "chatCompletions", json.RawMessage(`{"choices":[{"message":{"content":"`+"```go\\nx := 1\\n```"+`"}}]}`))
	if err != nil || text != "x := 1" {
		t.Fatalf("decoded %q %v", text, err)
	}
}
