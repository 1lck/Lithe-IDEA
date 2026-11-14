package ai

import (
	"context"
	"encoding/json"
)

// The pull request description draft (Lithe-core-rust rust/contracts/ai-generation-requests.md):
// Core shapes the prompt, applies the sensitive-path policy and the diff budget, and decodes
// the model's answer; this package sends the planned request with the provider's credential.

// PullRequestOptions are the options of a description: the language, the format and template,
// the diff budget and the reasoning effort ("default" omits the field).
type PullRequestOptions struct {
	Language              string `json:"language"`
	Format                string `json:"format"`
	CustomTemplate        string `json:"customTemplate,omitempty"`
	MaximumDiffCharacters int    `json:"maximumDiffCharacters"`
	ReasoningEffort       string `json:"reasoningEffort"`
}

// PullRequestOptionsFor are the options of a description written in the language and with the
// diff budget and reasoning effort of a commit message generation.
func PullRequestOptionsFor(commit CommitOptions) PullRequestOptions {
	return PullRequestOptions{
		Language: commit.Language, Format: "standard", MaximumDiffCharacters: commit.MaximumDiffCharacters,
		ReasoningEffort: commit.ReasoningEffort,
	}
}

// PullRequestFile is one changed file of the comparison: its path, its change kind, and its
// textual patch, empty for a file without one.
type PullRequestFile struct {
	Path       string `json:"path"`
	ChangeKind string `json:"changeKind"`
	Diff       string `json:"diff"`
}

// PullRequestComparison is the base...head comparison a description is drafted from.
type PullRequestComparison struct {
	Repository     string            `json:"repository"`
	Base           string            `json:"base"`
	Head           string            `json:"head"`
	CommitMessages []string          `json:"commitMessages"`
	Files          []PullRequestFile `json:"files"`
}

// PlanPullRequest builds the provider request for a pull request description
// (ai.pullRequest.plan).
func (c *Client) PlanPullRequest(ctx context.Context, provider PlanProvider, options PullRequestOptions, comparison PullRequestComparison) (HTTPRequest, error) {
	var result HTTPRequest
	err := c.core.Execute(ctx, "ai.pullRequest.plan", struct {
		Provider   PlanProvider          `json:"provider"`
		Options    PullRequestOptions    `json:"options"`
		Comparison PullRequestComparison `json:"comparison"`
	}{provider, options, comparison}, &result)
	return result, err
}

// DecodePullRequest extracts the title and the Markdown description from a provider answer
// (ai.pullRequest.decode).
func (c *Client) DecodePullRequest(ctx context.Context, protocol string, response json.RawMessage) (title, description string, err error) {
	var result struct {
		Title       string `json:"title"`
		Description string `json:"description"`
	}
	err = c.core.Execute(ctx, "ai.pullRequest.decode", struct {
		Protocol string          `json:"protocol"`
		Response json.RawMessage `json:"response"`
	}{protocol, response}, &result)
	return result.Title, result.Description, err
}

// DraftPullRequest plans, sends and decodes one description of comparison with provider, which
// the caller chose before it fetched the comparison.
func DraftPullRequest(ctx context.Context, k Kernel, provider Provider, options PullRequestOptions, comparison PullRequestComparison) (title, description string, err error) {
	plan, err := k.PlanPullRequest(ctx, provider.plan(), options, comparison)
	if err != nil {
		return "", "", err
	}
	answer, err := post(ctx, plan.URL, headers(provider.Protocol, provider.Authentication, provider.APIKey), plan.Body)
	if err != nil {
		return "", "", err
	}
	return k.DecodePullRequest(ctx, provider.Protocol, answer)
}
