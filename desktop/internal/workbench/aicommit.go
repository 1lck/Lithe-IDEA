package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// This file is the Commit panel's "generate message" action (matrix id ai-commit-generation).
// Core owns the evidence (git.commitMessageContext), the request plan (ai.planCommit) and the
// decoding (ai.decodeCommitMessage); this file only picks the provider and its credential from
// the Codex or Claude configuration, makes the HTTP call, and puts the answer in the message
// field. A generation never stages, commits or pushes: its result is a draft.

// aiCommitKernel is the part of the kernel the generation uses. *core.Client implements it; a
// kernel that does not (a test double) turns the button off.
type aiCommitKernel interface {
	CommitMessageContext(ctx context.Context, mode string, repositories []core.CommitContextRepository, maximumDiffCharacters int) (core.CommitContextEvidence, error)
	CommitMessageContextIsCurrent(ctx context.Context, mode string, repositories []core.CommitContextRepository, token string) (bool, error)
	AIPlanCommit(ctx context.Context, provider core.AICommitProvider, options core.AICommitOptions, files []core.AICommitFile) (core.AIHTTPRequest, error)
	AIDecodeCommitMessage(ctx context.Context, protocol string, response json.RawMessage, includeBody bool) (string, error)
}

// aiCommitState is what the commit area keeps of a generation.
type aiCommitState struct {
	// running is set from the click until the answer is applied or dropped.
	running bool
	cancel  context.CancelFunc
	// pending is a generated message waiting for the user to confirm replacing the text
	// already typed.
	pending    string
	hasPending bool
	// token and repositories are the evidence the pending message was generated from; they
	// are checked again before it replaces the typed text.
	token        string
	repositories []core.CommitContextRepository
}

// aiCommitDefaults are the options of a generation. The Viva settings do not offer them yet, so
// they are the shared defaults of the contract.
func (a *App) aiCommitOptions() core.AICommitOptions {
	language := "english"
	if a.language() == i18n.Chinese {
		language = "simplifiedChinese"
	}
	return core.AICommitOptions{
		Language: language, Format: "conventional", SubjectMaximumLength: 72,
		MaximumDiffCharacters: 32000, ReasoningEffort: "default",
	}
}

// canGenerateCommit reports that the button may start a generation.
func (a *App) canGenerateCommit(p *project) bool {
	_, ok := a.kernel.(aiCommitKernel)
	c := &p.commit
	return ok && a.agentKernelReady() && p.git.isRepository() && !c.busy && !c.ai.running && c.review == nil && p.git.stagedCount() > 0
}

// stagedCommitRepositories are the repositories and staged files the generation reads,
// matching what a commit takes.
func (p *project) stagedCommitRepositories() []core.CommitContextRepository {
	var files []core.CommitContextFile
	for _, change := range p.git.status.Changes {
		if !change.Staged {
			continue
		}
		files = append(files, core.CommitContextFile{Path: change.Path, OriginalPath: change.OriginalPath, ChangeKind: stagedChangeKind(change.Status)})
	}
	return []core.CommitContextRepository{{Root: p.git.repositoryRoot(p.root), Files: files}}
}

// stagedChangeKind names the index side of a porcelain status for Core.
func stagedChangeKind(status string) string {
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

// pickAIProvider is the first provider of the Codex then the Claude configuration that can
// be used: it has no issue and holds a credential.
func pickAIProvider(providers map[string][]agentProvider) (agentProvider, bool) {
	for _, source := range agentProviderSources() {
		for _, provider := range providers[source] {
			if provider.Issue == "" && !provider.MissingKey && provider.APIKey != "" && provider.Endpoint != "" {
				return provider, true
			}
		}
	}
	return agentProvider{}, false
}

// errAINoProvider reports that no configured provider can be used.
var errAINoProvider = errors.New("no AI provider")

// generateCommitMessage starts a generation for the staged changes.
func (a *App) generateCommitMessage(p *project) {
	kernel, ok := a.kernel.(aiCommitKernel)
	c := &p.commit
	if !ok || !a.canGenerateCommit(p) {
		return
	}
	a.performed("ai.commitMessage", surfaceButton)
	ctx, cancel := context.WithCancel(p.ctx)
	c.ai.running, c.ai.cancel = true, cancel
	repositories := p.stagedCommitRepositories()
	options := a.aiCommitOptions()
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		message, token, err := a.runCommitGeneration(ctx, kernel, repositories, options)
		return func(a *App) {
			c.ai.running, c.ai.cancel = false, nil
			a.finishCommitGeneration(p, message, token, repositories, err)
		}
	})
}

// runCommitGeneration captures the evidence, plans and sends the request and decodes the
// answer. It runs off the window thread.
func (a *App) runCommitGeneration(ctx context.Context, kernel aiCommitKernel, repositories []core.CommitContextRepository, options core.AICommitOptions) (string, string, error) {
	providers, _ := a.discoverAgentProviders(ctx)
	provider, ok := pickAIProvider(providers)
	if !ok {
		return "", "", errAINoProvider
	}
	evidence, err := kernel.CommitMessageContext(ctx, "staged", repositories, options.MaximumDiffCharacters)
	if err != nil {
		return "", "", err
	}
	plan, err := kernel.AIPlanCommit(ctx, core.AICommitProvider{
		ID: provider.Source, Name: provider.Name, Endpoint: provider.Endpoint, Model: provider.Model,
		APIProtocol: provider.Protocol, Authentication: provider.Authentication, Source: provider.Source, RequiresAPIKey: true,
	}, options, evidence.Files)
	if err != nil {
		return "", "", err
	}
	answer, err := aiPost(ctx, plan.URL, aiHeaders(provider.Protocol, provider.Authentication, provider.APIKey), plan.Body)
	if err != nil {
		return "", "", err
	}
	if !json.Valid(answer) {
		return "", "", errors.New("AI_COMMIT_INVALID_RESPONSE")
	}
	message, err := kernel.AIDecodeCommitMessage(ctx, provider.Protocol, answer, options.IncludeBody)
	if err != nil {
		return "", "", err
	}
	current, err := kernel.CommitMessageContextIsCurrent(ctx, "staged", repositories, evidence.Token)
	if err != nil {
		return "", "", err
	}
	if !current {
		return "", "", errAIStale
	}
	return message, evidence.Token, nil
}

// errAIStale reports that the staged changes moved while the message was generated.
var errAIStale = errors.New("staged changes changed")

// finishCommitGeneration applies a generated message, or reports why there is none. The
// message replaces an empty field at once and a typed one only after the user confirms.
func (a *App) finishCommitGeneration(p *project, message, token string, repositories []core.CommitContextRepository, err error) {
	c := &p.commit
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		a.notify(a.aiCommitFailure(err))
		a.gitOperationFailed("ai_commit_generation", err)
		return
	}
	message = strings.TrimSpace(message)
	if c.message() == "" {
		c.setMessage(message)
		return
	}
	c.ai.pending, c.ai.hasPending, c.ai.token, c.ai.repositories = message, true, token, repositories
}

// aiCommitFailure is the notification for a failed generation.
func (a *App) aiCommitFailure(err error) string {
	t := a.text.AI.Commit
	var status *aiHTTPError
	switch {
	case errors.Is(err, errAINoProvider):
		return t.NoProvider
	case errors.Is(err, errAIStale):
		return t.Stale
	case errors.Is(err, errAIResponseTooLarge):
		return t.Failed(t.ResponseTooLarge)
	case errors.Is(err, errAITimeout):
		return t.Failed(t.Timeout)
	case errors.As(err, &status):
		return t.Failed(t.HTTPStatus(status.Status))
	}
	return t.Failed(err.Error())
}

// cancelCommitGeneration stops a running generation; its answer is dropped.
func (a *App) cancelCommitGeneration(p *project) {
	if cancel := p.commit.ai.cancel; cancel != nil {
		cancel()
	}
}

// confirmGeneratedMessage settles the replacement the user was asked about. A replacement is
// checked against the Git state once more, as the contract asks, and keeps the text typed
// while the check ran.
func (a *App) confirmGeneratedMessage(p *project, replace bool) {
	c := &p.commit
	if !c.ai.hasPending {
		return
	}
	pending, token, repositories := c.ai.pending, c.ai.token, c.ai.repositories
	c.ai.pending, c.ai.hasPending, c.ai.token, c.ai.repositories = "", false, "", nil
	kernel, ok := a.kernel.(aiCommitKernel)
	if !replace || !ok {
		return
	}
	typed := c.message()
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		current, err := kernel.CommitMessageContextIsCurrent(ctx, "staged", repositories, token)
		return func(a *App) {
			switch {
			case err != nil:
				a.notify(a.aiCommitFailure(err))
			case !current:
				a.notify(a.aiCommitFailure(errAIStale))
			case c.message() != typed:
				// The user kept typing: the draft is theirs, not ours.
			default:
				c.setMessage(pending)
			}
		}
	})
}

// setMessage replaces the commit message with value and puts the cursor after it.
func (c *commitState) setMessage(value string) {
	c.editor = text.NewEditor(value)
	c.messageField = ui.Field{}
	c.messageField.Bind(c.editor)
}
