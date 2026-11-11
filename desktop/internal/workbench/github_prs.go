package workbench

import (
	"context"
	"errors"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/githubapi"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// This file is the pull-request panel of the Git log (matrix ids github-prs,
// github-pull-request-checkout, github-reviews-comments). The repository comes from origin through
// Core; every request is planned by Core and sent with the signed-in account's token. The panel
// lists open, closed or the account's own pull requests, shows one's description, state and
// conversation, opens it in the browser, and checks its head branch out after the user reviewed
// Core's preview. Line review threads and check runs are outside the contract, so they are not
// listed.

// pullRequestFilters are the lists the panel offers, in the order its buttons show them.
var pullRequestFilters = []string{"open", "closed", "mine"}

// pullRequestState is the panel's state: the repository, the list and the selected pull request,
// and the checkout being reviewed.
type pullRequestState struct {
	open bool
	// gen counts the reads of the list; an answer of an older read is dropped.
	gen    int
	root   string
	repo   *core.GitHubRepo
	err    string
	filter string
	loaded bool
	items  []githubapi.PullRequest
	list   ui.ListState
	// selected is the number of the pull request shown in detail; zero for none.
	selected     uint64
	detail       *githubapi.PullRequest
	comments     []githubapi.Comment
	detailErr    string
	detailGen    int
	replyField   ui.Field
	replyPending bool
	// preview is the checkout Core proposed for the selected pull request, reviewed by the user
	// before it runs; nil when none is reviewed.
	preview    *core.PullRequestCheckoutPreview
	checkoutOK bool
	busy       bool
}

// submitPullRequestReview submits a review of the selected pull request with the text typed in the
// reply box: a comment, an approval, or a request for changes, which needs the text.
func (a *App) submitPullRequestReview(p *project, event string) {
	pr := &a.pullRequests
	client := a.githubAPI()
	token := a.githubToken()
	body := strings.TrimSpace(pr.replyField.Text())
	if client == nil || token == "" || pr.repo == nil || pr.selected == 0 || pr.replyPending {
		return
	}
	if event == "REQUEST_CHANGES" && body == "" {
		pr.detailErr = i18n.Shared(a.language(), "desktop.github.reviewNeedsBody")
		return
	}
	repo, number := *pr.repo, pr.selected
	pr.replyPending = true
	a.performed("github.pullRequest.review", surfaceButton)
	a.background(p, githubReadTimeout, func(ctx context.Context) func(*App) {
		_, err := client.Do(ctx, core.GitHubRequest{Operation: "createPullRequestReview", Repository: &repo, PullNumber: number, Event: event, Body: &body}, token)
		return func(a *App) {
			pr := &a.pullRequests
			pr.replyPending = false
			if err != nil {
				pr.detailErr = githubFailure(a.language(), err)
				return
			}
			pr.replyField.SetText("")
			a.selectPullRequest(p, number)
		}
	})
}

// githubReadTimeout bounds one GitHub read or write of the panel.
const githubReadTimeout = githubAccountTimeout

// githubToken is the signed-in account's token, empty when none is connected.
func (a *App) githubToken() string {
	g := &a.github
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.token
}

// githubLogin is the signed-in login, empty when none is connected.
func (a *App) githubLogin() string {
	g := &a.github
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.connected {
		return ""
	}
	return g.login
}

// openPullRequests opens the panel for the project's repository and reads the repository identity
// from origin.
func (a *App) openPullRequests(p *project) {
	a.performed("github.pullRequests.open", surfaceMenu)
	client := a.githubAPI()
	kernel, ok := a.kernel.(interface {
		GitRemoteURL(ctx context.Context, root, remote string) (*string, error)
		GitHubParseRemote(ctx context.Context, remoteURL string) (core.GitHubRepo, error)
	})
	pr := &a.pullRequests
	pr.gen++
	gen := pr.gen
	*pr = pullRequestState{open: true, gen: gen, root: p.git.repositoryRoot(p.root), filter: "open"}
	if client == nil || !ok {
		pr.err = i18n.Shared(a.language(), "desktop.github.unavailable")
		return
	}
	root := pr.root
	a.background(p, githubReadTimeout, func(ctx context.Context) func(*App) {
		url, err := kernel.GitRemoteURL(ctx, root, "origin")
		var repo core.GitHubRepo
		if err == nil {
			if url == nil {
				err = errNoOrigin
			} else {
				repo, err = kernel.GitHubParseRemote(ctx, *url)
			}
		}
		return func(a *App) {
			pr := &a.pullRequests
			if !pr.open || pr.gen != gen {
				return
			}
			if err != nil {
				pr.err = githubFailure(a.language(), err)
				return
			}
			pr.repo = &repo
			a.loadPullRequests(p)
		}
	})
}

// errNoOrigin reports that the repository has no origin remote to name the GitHub repository.
var errNoOrigin = errors.New("the repository has no origin remote")

// closePullRequests closes the panel and drops the reads it waits for.
func (a *App) closePullRequests() {
	pr := &a.pullRequests
	pr.open = false
	pr.gen++
	pr.detailGen++
}

// setPullRequestFilter changes the list shown and reads it again.
func (a *App) setPullRequestFilter(p *project, filter string) {
	pr := &a.pullRequests
	if pr.filter == filter {
		return
	}
	pr.filter = filter
	a.loadPullRequests(p)
}

// loadPullRequests reads the list of the current filter. The account's own pull requests are the
// list of all states filtered by author, which GitHub's list cannot ask for directly.
func (a *App) loadPullRequests(p *project) {
	pr := &a.pullRequests
	if pr.repo == nil {
		return
	}
	client := a.githubAPI()
	token := a.githubToken()
	if client == nil || token == "" {
		pr.err = i18n.Shared(a.language(), "desktop.github.signInFirst")
		pr.loaded, pr.items = true, nil
		return
	}
	pr.gen++
	gen := pr.gen
	pr.err, pr.loaded = "", false
	repo, filter := *pr.repo, pr.filter
	login := a.githubLogin()
	a.background(p, githubReadTimeout, func(ctx context.Context) func(*App) {
		state := filter
		if filter == "mine" {
			state = "all"
		}
		raw, err := client.Do(ctx, core.GitHubRequest{Operation: "listPullRequests", Repository: &repo, State: state}, token)
		var items []githubapi.PullRequest
		if err == nil {
			items, err = githubapi.DecodePullRequests(raw)
		}
		if err == nil && filter == "mine" {
			mine := items[:0]
			for _, item := range items {
				if strings.EqualFold(item.Author.Login, login) {
					mine = append(mine, item)
				}
			}
			items = mine
		}
		return func(a *App) {
			pr := &a.pullRequests
			if pr.gen != gen || !pr.open {
				return
			}
			pr.loaded = true
			if err != nil {
				pr.err = githubFailure(a.language(), err)
				pr.items = nil
				a.gitOperationFailed("github_pull_requests", err)
				return
			}
			pr.items = items
		}
	})
}

// selectPullRequest shows the pull request number: its detail and its conversation.
func (a *App) selectPullRequest(p *project, number uint64) {
	pr := &a.pullRequests
	client := a.githubAPI()
	token := a.githubToken()
	if pr.repo == nil || client == nil || token == "" {
		return
	}
	pr.detailGen++
	gen := pr.detailGen
	pr.selected, pr.detail, pr.comments, pr.detailErr, pr.preview, pr.checkoutOK = number, nil, nil, "", nil, false
	repo := *pr.repo
	a.performed("github.pullRequest.select", surfaceButton)
	a.background(p, githubReadTimeout, func(ctx context.Context) func(*App) {
		raw, err := client.Do(ctx, core.GitHubRequest{Operation: "getPullRequest", Repository: &repo, PullNumber: number}, token)
		var detail githubapi.PullRequest
		if err == nil {
			detail, err = githubapi.DecodePullRequest(raw)
		}
		var comments []githubapi.Comment
		if err == nil {
			commentsRaw, cerr := client.Do(ctx, core.GitHubRequest{Operation: "listPullRequestComments", Repository: &repo, PullNumber: number}, token)
			if cerr != nil {
				err = cerr
			} else {
				comments, err = githubapi.DecodeComments(commentsRaw)
			}
		}
		return func(a *App) {
			pr := &a.pullRequests
			if pr.detailGen != gen || !pr.open {
				return
			}
			if err != nil {
				pr.detailErr = githubFailure(a.language(), err)
				return
			}
			pr.detail, pr.comments = &detail, comments
		}
	})
}

// openPullRequestInBrowser opens the pull request's page on GitHub.
func (a *App) openPullRequestInBrowser(url string) {
	if url == "" {
		return
	}
	a.performed("github.pullRequest.openBrowser", surfaceButton)
	if err := app.OpenURL(url); err != nil {
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.github.openFailed", map[string]string{"reason": err.Error()}))
	}
}

// previewPullRequestCheckout asks Core for the checkout of the selected pull request and keeps the
// answer for the user to review. A conflicting branch name is reported as Core's error.
func (a *App) previewPullRequestCheckout(p *project) {
	pr := &a.pullRequests
	kernel, ok := a.kernel.(interface {
		GitPullRequestCheckoutPreview(ctx context.Context, root string, number uint64, headRef string, repo *core.GitHubRepo) (core.PullRequestCheckoutPreview, error)
	})
	if !ok || pr.detail == nil || pr.busy || pr.repo == nil {
		return
	}
	number, head, repo, root := pr.detail.Number, pr.detail.HeadRef, *pr.repo, pr.root
	pr.busy = true
	a.performed("github.pullRequest.previewCheckout", surfaceButton)
	a.background(p, githubReadTimeout, func(ctx context.Context) func(*App) {
		preview, err := kernel.GitPullRequestCheckoutPreview(ctx, root, number, head, &repo)
		return func(a *App) {
			pr := &a.pullRequests
			pr.busy = false
			if pr.selected != number {
				return
			}
			if err != nil {
				pr.detailErr = githubFailure(a.language(), err)
				pr.preview = nil
				return
			}
			pr.preview = &preview
		}
	})
}

// checkoutPullRequest checks out the reviewed preview. Core refuses a preview the checkout has
// moved away from; the user is then asked to review again.
func (a *App) checkoutPullRequest(p *project) {
	pr := &a.pullRequests
	kernel, ok := a.kernel.(interface {
		GitPullRequestCheckout(ctx context.Context, root string, number uint64, headRef string, reviewed core.PullRequestCheckoutPreview, repo *core.GitHubRepo) error
	})
	if !ok || pr.preview == nil || pr.detail == nil || pr.busy || pr.repo == nil || !pr.preview.Plan.Allowed {
		return
	}
	number, head, repo, root := pr.detail.Number, pr.detail.HeadRef, *pr.repo, pr.root
	reviewed := *pr.preview
	pr.busy = true
	a.performed("github.pullRequest.checkout", surfaceButton)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		err := kernel.GitPullRequestCheckout(ctx, root, number, head, reviewed, &repo)
		return func(a *App) {
			pr := &a.pullRequests
			pr.busy = false
			pr.preview = nil
			if err != nil {
				pr.detailErr = githubFailure(a.language(), err)
				a.gitOperationFailed("github_pull_request_checkout", err)
				return
			}
			pr.checkoutOK = true
			a.checkoutWritten(p, root)
			a.notifySuccess(i18n.SharedFormat(a.language(), "desktop.github.checkedOut", map[string]string{"branch": reviewed.Plan.Branch}))
		}
	})
}

// postPullRequestComment adds a conversation comment to the selected pull request and reads the
// conversation again.
func (a *App) postPullRequestComment(p *project) {
	pr := &a.pullRequests
	client := a.githubAPI()
	token := a.githubToken()
	body := strings.TrimSpace(pr.replyField.Text())
	if client == nil || token == "" || body == "" || pr.repo == nil || pr.selected == 0 || pr.replyPending {
		return
	}
	repo, number := *pr.repo, pr.selected
	pr.replyPending = true
	a.performed("github.pullRequest.comment", surfaceButton)
	a.background(p, githubReadTimeout, func(ctx context.Context) func(*App) {
		_, err := client.Do(ctx, core.GitHubRequest{Operation: "createPullRequestComment", Repository: &repo, PullNumber: number, Body: &body}, token)
		return func(a *App) {
			pr := &a.pullRequests
			pr.replyPending = false
			if err != nil {
				pr.detailErr = githubFailure(a.language(), err)
				return
			}
			pr.replyField.SetText("")
			a.selectPullRequest(p, number)
		}
	})
}
