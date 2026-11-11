package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/githubapi"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file creates a pull request from the checkout (matrix id ai-pull-request-description): the
// dialog takes a title, a Markdown description, the base and the head branch, and whether the pull
// request starts as a draft. The description can be drafted by the configured AI provider from the
// comparison of the two branches: GitHub supplies the commits and the patches, Core shapes the
// prompt, the provider answers, and Core decodes the title and description. The draft is only text
// in the dialog; the pull request is created only when the user confirms. A branch that has not
// been published, or a detached HEAD, blocks creation; publishing from here is not offered yet.

// prCreateState is the create dialog of the pull-request panel.
type prCreateState struct {
	open bool
	gen  int
	busy bool
	// generating says an AI draft runs; a second draft is not started meanwhile.
	generating bool
	err        string
	repo       *core.GitHubRepo
	branches   []string
	base       string
	head       string
	draft      bool
	// blocked is why creation cannot start from this checkout, empty when it can.
	blocked    string
	title      ui.Field
	body       ui.Field
	baseChoice ui.ListState
}

// openCreatePullRequest opens the create dialog for the project's checkout: it reads the
// repository, the branches, and the facts Core needs to decide whether creation can start.
func (a *App) openCreatePullRequest(p *project) {
	cr := &a.prCreate
	kernel, ok := a.kernel.(interface {
		GitRemoteURL(ctx context.Context, root, remote string) (*string, error)
		GitHubParseRemote(ctx context.Context, remoteURL string) (core.GitHubRepo, error)
		GitPullRequestContext(ctx context.Context, root string) (core.PullRequestContext, error)
	})
	client := a.githubAPI()
	token := a.githubToken()
	cr.gen++
	gen := cr.gen
	*cr = prCreateState{open: true, gen: gen, busy: true, head: p.git.branch()}
	if !ok || client == nil || token == "" {
		cr.err = i18n.Shared(a.language(), "desktop.github.signInFirst")
		cr.busy = false
		return
	}
	a.performed("github.createPullRequest.open", surfaceMenu)
	root := p.git.repositoryRoot(p.root)
	a.background(p, githubReadTimeout, func(ctx context.Context) func(*App) {
		url, err := kernel.GitRemoteURL(ctx, root, "origin")
		var repo core.GitHubRepo
		var facts core.PullRequestContext
		var raw json.RawMessage
		if err == nil && url == nil {
			err = errNoOrigin
		}
		if err == nil {
			repo, err = kernel.GitHubParseRemote(ctx, *url)
		}
		if err == nil {
			facts, err = kernel.GitPullRequestContext(ctx, root)
		}
		if err == nil {
			raw, err = client.Do(ctx, core.GitHubRequest{Operation: "listBranches", Repository: &repo}, token)
		}
		var branches []githubapi.Branch
		if err == nil {
			branches, err = githubapi.DecodeBranches(raw)
		}
		return func(a *App) {
			cr := &a.prCreate
			if !cr.open || cr.gen != gen {
				return
			}
			cr.busy = false
			if err != nil {
				cr.err = githubFailure(a.language(), err)
				return
			}
			cr.repo = &repo
			for _, b := range branches {
				cr.branches = append(cr.branches, b.Name)
			}
			cr.base = defaultBaseBranch(cr.branches, facts.SuggestedBaseBranch)
			cr.blocked = creationBlockedReason(a.language(), facts)
			if facts.CurrentBranch != nil {
				cr.head = *facts.CurrentBranch
			}
		}
	})
}

// defaultBaseBranch is the suggested base when it is a branch the repository has, else main, master
// or the first branch.
func defaultBaseBranch(branches []string, suggested *string) string {
	if suggested != nil {
		for _, b := range branches {
			if b == *suggested {
				return b
			}
		}
	}
	for _, preferred := range []string{"main", "master"} {
		for _, b := range branches {
			if b == preferred {
				return b
			}
		}
	}
	if len(branches) > 0 {
		return branches[0]
	}
	return ""
}

// creationBlockedReason is why the checkout cannot be the head of a pull request yet, empty when
// it can.
func creationBlockedReason(language i18n.Language, facts core.PullRequestContext) string {
	switch {
	case facts.Detached:
		return i18n.Shared(language, "desktop.github.createDetached")
	case facts.RequiresPublish:
		return i18n.Shared(language, "desktop.github.createUnpublished")
	}
	return ""
}

// closeCreatePullRequest closes the dialog and drops the reads it waits for.
func (a *App) closeCreatePullRequest() {
	a.prCreate.open = false
	a.prCreate.gen++
}

// submitCreatePullRequest creates the pull request from the dialog's fields and opens it in the
// panel.
func (a *App) submitCreatePullRequest(p *project) {
	cr := &a.prCreate
	client := a.githubAPI()
	token := a.githubToken()
	title := strings.TrimSpace(cr.title.Text())
	if client == nil || token == "" || cr.repo == nil || cr.busy || cr.blocked != "" || title == "" || cr.base == "" || cr.head == "" {
		return
	}
	repo, base, head, draft := *cr.repo, cr.base, cr.head, cr.draft
	body := cr.body.Text()
	cr.busy = true
	a.performed("github.createPullRequest.submit", surfaceButton)
	a.background(p, githubReadTimeout, func(ctx context.Context) func(*App) {
		raw, err := client.Do(ctx, core.GitHubRequest{
			Operation: "createPullRequest", Repository: &repo, Title: &title, Body: &body,
			Head: head, Base: base, Draft: &draft,
		}, token)
		var created githubapi.PullRequest
		if err == nil {
			created, err = githubapi.DecodePullRequest(raw)
		}
		return func(a *App) {
			cr := &a.prCreate
			cr.busy = false
			if err != nil {
				cr.err = githubFailure(a.language(), err)
				return
			}
			cr.open = false
			cr.gen++
			a.openCreatedPullRequest(p, created.Number)
		}
	})
}

// openCreatedPullRequest shows the pull request just created in the panel.
func (a *App) openCreatedPullRequest(p *project, number uint64) {
	pr := &a.pullRequests
	pr.open = true
	pr.repo = a.prCreate.repo
	pr.filter = "open"
	pr.root = p.git.repositoryRoot(p.root)
	a.loadPullRequests(p)
	a.selectPullRequest(p, number)
}

// generatePullRequestDescription drafts the title and description from the comparison of base and
// head through the configured AI provider. The text the user typed is replaced by the draft, which
// the user edits; a failure says why and keeps what was typed.
func (a *App) generatePullRequestDescription(p *project) {
	cr := &a.prCreate
	client := a.githubAPI()
	token := a.githubToken()
	kernel, ok := a.kernel.(interface {
		AIPlanPullRequest(ctx context.Context, provider core.AICommitProvider, options core.AIPullRequestOptions, comparison core.PullRequestComparison) (core.AIHTTPRequest, error)
		AIDecodePullRequest(ctx context.Context, protocol string, response json.RawMessage) (string, string, error)
	})
	if !ok || client == nil || token == "" || cr.repo == nil || cr.generating || cr.base == "" || cr.head == "" || !a.agentKernelReady() {
		return
	}
	repo, base, head := *cr.repo, cr.base, cr.head
	cr.generating, cr.err = true, ""
	a.performed("ai.pullRequestDescription", surfaceButton)
	options := a.aiCommitOptions()
	sources := a.aiGenerationSources()
	a.background(p, aiRequestTimeoutPR, func(ctx context.Context) func(*App) {
		providers, _ := a.discoverAgentProviders(ctx)
		provider, found := pickAIProviderFrom(providers, sources)
		if !found {
			return a.finishPullRequestDraft("", "", errAINoProvider)
		}
		raw, err := client.Do(ctx, core.GitHubRequest{Operation: "compareBranches", Repository: &repo, Base: base, Head: head}, token)
		var comparison githubapi.Comparison
		if err == nil {
			comparison, err = githubapi.DecodeComparison(raw)
		}
		if err != nil {
			return a.finishPullRequestDraft("", "", err)
		}
		plan, err := kernel.AIPlanPullRequest(ctx, core.AICommitProvider{
			ID: provider.Source, Name: provider.Name, Endpoint: provider.Endpoint, Model: provider.Model,
			APIProtocol: provider.Protocol, Authentication: provider.Authentication, Source: provider.Source, RequiresAPIKey: true,
		}, core.AIPullRequestOptions{
			Language: options.Language, Format: "standard", MaximumDiffCharacters: options.MaximumDiffCharacters,
			ReasoningEffort: options.ReasoningEffort,
		}, comparisonForCore(repo, base, head, comparison))
		if err != nil {
			return a.finishPullRequestDraft("", "", err)
		}
		answer, err := aiPost(ctx, plan.URL, aiHeaders(provider.Protocol, provider.Authentication, provider.APIKey), plan.Body)
		if err != nil {
			return a.finishPullRequestDraft("", "", err)
		}
		title, description, err := kernel.AIDecodePullRequest(ctx, provider.Protocol, answer)
		return a.finishPullRequestDraft(title, description, err)
	})
}

// aiRequestTimeoutPR bounds a whole draft: the comparison, the provider call and the decode.
const aiRequestTimeoutPR = aiRequestTimeout

// comparisonForCore is the comparison Core plans from: the repository as owner/name, the branches,
// the commit messages, and each file with its patch (an empty patch for a file without one).
func comparisonForCore(repo core.GitHubRepo, base, head string, comparison githubapi.Comparison) core.PullRequestComparison {
	out := core.PullRequestComparison{Repository: repo.Owner + "/" + repo.Name, Base: base, Head: head}
	for _, commit := range comparison.Commits {
		out.CommitMessages = append(out.CommitMessages, commit.Message)
	}
	for _, file := range comparison.Files {
		diff := ""
		if file.Patch != nil {
			diff = *file.Patch
		}
		out.Files = append(out.Files, core.PullRequestComparisonFile{Path: file.Path, ChangeKind: file.Status, Diff: diff})
	}
	return out
}

// finishPullRequestDraft applies a drafted title and description on the window thread, or reports
// why there is none.
func (a *App) finishPullRequestDraft(title, description string, err error) func(*App) {
	return func(a *App) {
		cr := &a.prCreate
		cr.generating = false
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return
			}
			cr.err = aiPullRequestFailure(a.language(), err)
			a.gitOperationFailed("ai_pull_request_description", err)
			return
		}
		cr.title.SetText(strings.TrimSpace(title))
		cr.body.SetText(description)
	}
}

// aiPullRequestFailure is the text a failed description draft shows.
func aiPullRequestFailure(language i18n.Language, err error) string {
	if errors.Is(err, errAINoProvider) {
		return i18n.Shared(language, "desktop.github.draftNoProvider")
	}
	return i18n.SharedFormat(language, "desktop.github.draftFailed", map[string]string{"reason": err.Error()})
}
