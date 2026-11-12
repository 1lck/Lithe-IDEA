package core

import (
	"context"
	"encoding/json"
)

// This file wraps the AI pull-request description commands (shared/contracts/ai-generation-requests.md).
// Core shapes the prompt, applies the sensitive-path policy and the diff budget, and decodes the
// model's answer; the host sends the planned request with the provider's credentials.

// AIPullRequestOptions are the options of a description: the language, the format and template,
// the diff budget and the reasoning effort ("default" omits the field).
type AIPullRequestOptions struct {
	Language              string `json:"language"`
	Format                string `json:"format"`
	CustomTemplate        string `json:"customTemplate,omitempty"`
	MaximumDiffCharacters int    `json:"maximumDiffCharacters"`
	ReasoningEffort       string `json:"reasoningEffort"`
}

// PullRequestComparisonFile is one changed file of the comparison: its path, its change kind, and its
// textual patch, empty for a file without one.
type PullRequestComparisonFile struct {
	Path       string `json:"path"`
	ChangeKind string `json:"changeKind"`
	Diff       string `json:"diff"`
}

// PullRequestComparison is the base...head comparison a description is drafted from.
type PullRequestComparison struct {
	Repository     string                      `json:"repository"`
	Base           string                      `json:"base"`
	Head           string                      `json:"head"`
	CommitMessages []string                    `json:"commitMessages"`
	Files          []PullRequestComparisonFile `json:"files"`
}

// AIPlanPullRequest builds the provider request for a pull request description.
func (c *Client) AIPlanPullRequest(ctx context.Context, provider AICommitProvider, options AIPullRequestOptions, comparison PullRequestComparison) (AIHTTPRequest, error) {
	var result AIHTTPRequest
	err := c.Execute(ctx, "ai.pullRequest.plan", struct {
		Provider   AICommitProvider      `json:"provider"`
		Options    AIPullRequestOptions  `json:"options"`
		Comparison PullRequestComparison `json:"comparison"`
	}{provider, options, comparison}, &result)
	return result, err
}

// AIDecodePullRequest extracts the title and the Markdown description from a provider response.
func (c *Client) AIDecodePullRequest(ctx context.Context, protocol string, response json.RawMessage) (title, description string, err error) {
	var result struct {
		Title       string `json:"title"`
		Description string `json:"description"`
	}
	err = c.Execute(ctx, "ai.pullRequest.decode", struct {
		Protocol string          `json:"protocol"`
		Response json.RawMessage `json:"response"`
	}{protocol, response}, &result)
	return result.Title, result.Description, err
}
