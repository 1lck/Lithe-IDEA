package ai

import (
	"context"
	"encoding/json"
	"errors"
)

// The commit message generation: Core captures the evidence of the staged changes
// (git.commitMessageContext), plans the request (ai.planCommit) and decodes the answer
// (ai.decodeCommitMessage). A generation never stages, commits or pushes: its result is a
// draft, and it is checked against the Git state again before it replaces typed text.

// PlanProvider is the credential-free provider description Core plans a commit or pull request
// request for. Credentials never cross the Core boundary.
type PlanProvider struct {
	ID                  string `json:"id"`
	Name                string `json:"name"`
	Endpoint            string `json:"endpoint"`
	Model               string `json:"model"`
	APIProtocol         string `json:"apiProtocol"`
	Authentication      string `json:"authentication"`
	Source              string `json:"source"`
	RequiresAPIKey      bool   `json:"requiresApiKey"`
	AllowsInsecureHTTP  bool   `json:"allowsInsecureHttp"`
	ChatTokenLimitField string `json:"chatTokenLimitField,omitempty"`
}

// CommitOptions are the user choices of one commit message generation.
type CommitOptions struct {
	Language              string `json:"language"`
	Format                string `json:"format"`
	CustomInstructions    string `json:"customInstructions"`
	IncludeBody           bool   `json:"includeBody"`
	SubjectMaximumLength  int    `json:"subjectMaximumLength"`
	MaximumDiffCharacters int    `json:"maximumDiffCharacters"`
	ReasoningEffort       string `json:"reasoningEffort"`
}

// NewCommitOptions are the options of a generation in language (english or simplifiedChinese),
// with or without a body and with the user's instructions, and the shared defaults of the
// contract for the rest.
func NewCommitOptions(language string, includeBody bool, instructions string) CommitOptions {
	return CommitOptions{
		Language: language, Format: "conventional", SubjectMaximumLength: 72,
		MaximumDiffCharacters: 32000, ReasoningEffort: "default", IncludeBody: includeBody,
		CustomInstructions: instructions,
	}
}

// EvidenceFile is one file of commit evidence. OriginalCharacters is the untruncated diff
// length git.commitMessageContext reported. The planner expects it on every file, with Diff
// already cut to the budget.
type EvidenceFile struct {
	Path               string `json:"path"`
	ChangeKind         string `json:"changeKind"`
	Diff               string `json:"diff"`
	OriginalCharacters *int   `json:"originalCharacters,omitempty"`
}

// HTTPRequest is a credential-free provider request. The host attaches the authentication
// headers and performs the HTTP call.
type HTTPRequest struct {
	URL  string          `json:"url"`
	Body json.RawMessage `json:"body"`
}

// ContextFile is a selected file of git.commitMessageContext.
type ContextFile struct {
	Path         string `json:"path"`
	OriginalPath string `json:"originalPath,omitempty"`
	ChangeKind   string `json:"changeKind"`
}

// ContextRepository is one repository and its selected files.
type ContextRepository struct {
	Root  string        `json:"root"`
	Files []ContextFile `json:"files"`
}

// Evidence is the bounded evidence captured for a generation and the token that says which Git
// state it was captured from.
type Evidence struct {
	Files []EvidenceFile
	Token string
}

// StagedChangeKind names the index side of a porcelain status for git.commitMessageContext.
func StagedChangeKind(status string) string {
	if status == "" {
		return "modified"
	}
	switch status[0] {
	case 'A':
		return "added"
	case 'D':
		return "deleted"
	case 'R':
		return "renamed"
	case 'C':
		return "copied"
	case 'U':
		return "unmerged"
	}
	return "modified"
}

type contextRequest struct {
	Action                string              `json:"action"`
	Mode                  string              `json:"mode"`
	Repositories          []ContextRepository `json:"repositories"`
	MaximumDiffCharacters int                 `json:"maximumDiffCharacters,omitempty"`
	Token                 string              `json:"token,omitempty"`
}

// CommitContext captures the evidence without modifying the index (git.commitMessageContext).
// mode is staged or worktree and must match the commit operation. It runs Git.
func (c *Client) CommitContext(ctx context.Context, mode string, repositories []ContextRepository, maximumDiffCharacters int) (Evidence, error) {
	var raw struct {
		Files []struct {
			Path               string `json:"path"`
			ChangeKind         string `json:"changeKind"`
			Diff               string `json:"diff"`
			OriginalCharacters int    `json:"originalCharacters"`
		} `json:"files"`
		Token string `json:"token"`
	}
	err := c.core.Execute(ctx, "git.commitMessageContext", contextRequest{
		Action: "capture", Mode: mode, Repositories: repositories, MaximumDiffCharacters: maximumDiffCharacters,
	}, &raw)
	out := Evidence{Token: raw.Token}
	for _, f := range raw.Files {
		n := f.OriginalCharacters
		out.Files = append(out.Files, EvidenceFile{Path: f.Path, ChangeKind: f.ChangeKind, Diff: f.Diff, OriginalCharacters: &n})
	}
	return out, err
}

// CommitContextIsCurrent checks the evidence token against the current Git state. Generated
// text applies only when it returns true.
func (c *Client) CommitContextIsCurrent(ctx context.Context, mode string, repositories []ContextRepository, token string) (bool, error) {
	var result struct {
		IsCurrent bool `json:"isCurrent"`
	}
	err := c.core.Execute(ctx, "git.commitMessageContext", contextRequest{
		Action: "check", Mode: mode, Repositories: repositories, Token: token,
	}, &result)
	return result.IsCurrent, err
}

// PlanCommit builds the provider request for a commit message (ai.planCommit).
func (c *Client) PlanCommit(ctx context.Context, provider PlanProvider, options CommitOptions, files []EvidenceFile) (HTTPRequest, error) {
	var result HTTPRequest
	err := c.core.Execute(ctx, "ai.planCommit", struct {
		Provider PlanProvider   `json:"provider"`
		Options  CommitOptions  `json:"options"`
		Files    []EvidenceFile `json:"files"`
	}{provider, options, files}, &result)
	return result, err
}

// DecodeCommitMessage extracts the message from a provider answer (ai.decodeCommitMessage).
// Answers over 2 MiB are refused before it is called.
func (c *Client) DecodeCommitMessage(ctx context.Context, protocol string, response json.RawMessage, includeBody bool) (string, error) {
	var result struct {
		Message string `json:"message"`
	}
	err := c.core.Execute(ctx, "ai.decodeCommitMessage", struct {
		Protocol    string          `json:"protocol"`
		Response    json.RawMessage `json:"response"`
		IncludeBody bool            `json:"includeBody"`
	}{protocol, response, includeBody}, &result)
	return result.Message, err
}

// ErrStale reports that the staged changes moved while the message was generated.
var ErrStale = errors.New("staged changes changed")

// GenerateCommitMessage generates a message for the staged files of repositories with the
// first usable provider of sources: it captures the evidence, plans and sends the request,
// decodes the answer and checks that the staged changes did not move meanwhile. It returns the
// message and the evidence token the caller checks again before the message replaces typed
// text.
func GenerateCommitMessage(ctx context.Context, k Kernel, repositories []ContextRepository, options CommitOptions, sources []string) (message, token string, err error) {
	provider, err := Choose(ctx, k, sources)
	if err != nil {
		return "", "", err
	}
	evidence, err := k.CommitContext(ctx, "staged", repositories, options.MaximumDiffCharacters)
	if err != nil {
		return "", "", err
	}
	plan, err := k.PlanCommit(ctx, provider.plan(), options, evidence.Files)
	if err != nil {
		return "", "", err
	}
	answer, err := post(ctx, plan.URL, headers(provider.Protocol, provider.Authentication, provider.APIKey), plan.Body)
	if err != nil {
		return "", "", err
	}
	if !json.Valid(answer) {
		return "", "", errors.New("AI_COMMIT_INVALID_RESPONSE")
	}
	message, err = k.DecodeCommitMessage(ctx, provider.Protocol, answer, options.IncludeBody)
	if err != nil {
		return "", "", err
	}
	current, err := k.CommitContextIsCurrent(ctx, "staged", repositories, evidence.Token)
	if err != nil {
		return "", "", err
	}
	if !current {
		return "", "", ErrStale
	}
	return message, evidence.Token, nil
}
