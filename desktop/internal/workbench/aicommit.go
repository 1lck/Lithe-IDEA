package workbench

import (
	"context"
	"errors"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/ai"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// This file is the Commit panel's "generate message" action (matrix id ai-commit-generation).
// The ai package runs the generation with Core; this file keeps the panel's state, hands the
// staged changes of the active ChangeList to it and puts the answer in the message field. A
// generation never stages, commits or pushes: its result is a draft.

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
	repositories []ai.ContextRepository
}

// aiCommitOptions are the options of a generation: the language, the body and the instructions
// the settings chose.
func (a *App) aiCommitOptions() ai.CommitOptions {
	generation := a.aiGenerationSettings()
	language := "english"
	if a.language() == i18n.Chinese {
		language = "simplifiedChinese"
	}
	if generation.Language != "" {
		language = generation.Language
	}
	return ai.NewCommitOptions(language, generation.IncludeBody, strings.TrimSpace(generation.CustomInstructions))
}

// canGenerateCommit reports that the button may start a generation.
func (a *App) canGenerateCommit(p *project) bool {
	c := &p.commit
	return a.aiKernelReady() && p.git.isRepository() && !c.busy && !c.ai.running && c.review == nil &&
		p.listsReady() && p.activeStagedCount() > 0 && !p.otherStaged()
}

// stagedCommitRepositories are the repositories and staged files the generation reads,
// matching what a commit takes: the staged changes of the active ChangeList.
func (p *project) stagedCommitRepositories() []ai.ContextRepository {
	var files []ai.ContextFile
	for _, change := range p.activeChanges() {
		if !change.Staged {
			continue
		}
		files = append(files, ai.ContextFile{Path: change.Path, OriginalPath: change.OriginalPath, ChangeKind: ai.StagedChangeKind(change.Status)})
	}
	return []ai.ContextRepository{{Root: p.git.repositoryRoot(p.root), Files: files}}
}

// generateCommitMessage starts a generation for the staged changes.
func (a *App) generateCommitMessage(p *project) {
	c := &p.commit
	if !a.canGenerateCommit(p) {
		return
	}
	a.performed("ai.commitMessage", surfaceButton)
	ctx, cancel := context.WithCancel(p.ctx)
	c.ai.running, c.ai.cancel = true, cancel
	kernel, repositories := a.aiKernel, p.stagedCommitRepositories()
	options := a.aiCommitOptions()
	sources := a.aiGenerationSources()
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		message, token, err := ai.GenerateCommitMessage(ctx, kernel, repositories, options, sources)
		return func(a *App) {
			c.ai.running, c.ai.cancel = false, nil
			a.finishCommitGeneration(p, message, token, repositories, err)
		}
	})
}

// finishCommitGeneration applies a generated message, or reports why there is none. The
// message replaces an empty field at once and a typed one only after the user confirms.
func (a *App) finishCommitGeneration(p *project, message, token string, repositories []ai.ContextRepository, err error) {
	c := &p.commit
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		a.notifyError(a.aiCommitFailure(err))
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
	var status *ai.HTTPError
	switch {
	case errors.Is(err, ai.ErrNoProvider):
		return t.NoProvider
	case errors.Is(err, ai.ErrStale):
		return t.Stale
	case errors.Is(err, ai.ErrResponseTooLarge):
		return t.Failed(t.ResponseTooLarge)
	case errors.Is(err, ai.ErrTimeout):
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
	kernel := a.aiKernel
	if !replace || kernel == nil {
		return
	}
	typed := c.message()
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		current, err := kernel.CommitContextIsCurrent(ctx, "staged", repositories, token)
		return func(a *App) {
			switch {
			case err != nil:
				a.notifyError(a.aiCommitFailure(err))
			case !current:
				a.notifyError(a.aiCommitFailure(ai.ErrStale))
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
