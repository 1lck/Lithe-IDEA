package core

import "context"

// WorkspaceRepositoryReferences is one repository of a folder with several, with the references
// its git.references call returned, passed back to Core unchanged.
type WorkspaceRepositoryReferences struct {
	// ID is the repository's workspace.repositories ID.
	ID         string         `json:"id"`
	References []GitReference `json:"references"`
}

// WorkspaceCommonReferences are the branches every repository of a folder has, as IntelliJ IDEA's
// Common Local Branches and Common Remote Branches list them, in the first repository's order.
// Each is a git.references entry: IsCurrent when every repository has it checked out,
// UpstreamShortName when every repository tracks the same remote branch with it, and Ahead and
// Behind added up over the repositories.
type WorkspaceCommonReferences struct {
	Local  []GitReference `json:"local"`
	Remote []GitReference `json:"remote"`
}

// GitWorkspaceCommonReferences asks Core which local and remote branches every repository has
// (git.workspaceCommonReferences). It runs no process.
func (c *Client) GitWorkspaceCommonReferences(ctx context.Context, repositories []WorkspaceRepositoryReferences) (WorkspaceCommonReferences, error) {
	request := struct {
		Repositories []WorkspaceRepositoryReferences `json:"repositories"`
	}{workspaceRepositoryReferences(repositories)}
	var common WorkspaceCommonReferences
	if err := c.Execute(ctx, "git.workspaceCommonReferences", request, &common); err != nil {
		return WorkspaceCommonReferences{}, err
	}
	common.Local, common.Remote = nonNil(common.Local), nonNil(common.Remote)
	return common, nil
}

// WorkspaceBranchOperation is the branch action chosen on a common branch.
type WorkspaceBranchOperation string

const (
	// WorkspaceBranchCheckout switches every repository to the common branch.
	WorkspaceBranchCheckout WorkspaceBranchOperation = "checkout"
	// WorkspaceBranchCreate creates a new local branch at the common branch in every repository.
	WorkspaceBranchCreate WorkspaceBranchOperation = "createBranch"
)

// WorkspaceBranchPlanRequest asks Core how a branch action on a common branch runs across the
// repositories.
type WorkspaceBranchPlanRequest struct {
	Operation WorkspaceBranchOperation `json:"operation"`
	// Reference is the full name of the common local or remote branch.
	Reference string `json:"reference"`
	// Name is the new branch's name for WorkspaceBranchCreate, as git.branchNamePreview cleaned it.
	Name string `json:"name,omitempty"`
	// Checkout switches every repository to the new branch of WorkspaceBranchCreate.
	Checkout bool `json:"checkout,omitempty"`
	// Repositories are the repositories the action runs in, in the order it runs.
	Repositories []WorkspaceRepositoryReferences `json:"repositories"`
}

// WorkspaceBranchPlan is Core's plan of a branch action across the repositories.
type WorkspaceBranchPlan struct {
	// Steps are the writes in the order they run; the first that fails stops the action.
	Steps []WorkspaceBranchStep `json:"steps"`
	// Skipped are the IDs of the repositories a checkout leaves alone because they are already on
	// the branch.
	Skipped []string `json:"skipped"`
}

// WorkspaceBranchStep is the write of one repository: a checkout of Reference, or a new branch
// at it.
type WorkspaceBranchStep struct {
	Repository string `json:"repository"`
	// Reference is this repository's fullName, shortName and kind of the common branch.
	Reference GitReference `json:"reference"`
	// Rollback are the writes that undo the step, in the order they run; nil when nothing can,
	// because HEAD was detached or unborn before the step switched it.
	Rollback []WorkspaceBranchRollback `json:"rollback"`
}

// WorkspaceBranchRollbackOperation is the git.write operation of a rollback action.
type WorkspaceBranchRollbackOperation string

const (
	// WorkspaceRollbackCheckout checks the previous local branch out again.
	WorkspaceRollbackCheckout WorkspaceBranchRollbackOperation = "checkout"
	// WorkspaceRollbackDeleteBranch deletes the branch the step created.
	WorkspaceRollbackDeleteBranch WorkspaceBranchRollbackOperation = "deleteBranch"
)

// WorkspaceBranchRollback is one write that undoes part of a step.
type WorkspaceBranchRollback struct {
	Operation WorkspaceBranchRollbackOperation `json:"operation"`
	Reference GitReference                     `json:"reference"`
}

// GitWorkspaceBranchPlan asks Core which writes a branch action on a common branch runs in each
// repository, which repositories it skips, and what undoes each write (git.workspaceBranchPlan).
// It runs no process; the caller runs the writes.
func (c *Client) GitWorkspaceBranchPlan(ctx context.Context, request WorkspaceBranchPlanRequest) (WorkspaceBranchPlan, error) {
	request.Repositories = workspaceRepositoryReferences(request.Repositories)
	var plan WorkspaceBranchPlan
	if err := c.Execute(ctx, "git.workspaceBranchPlan", request, &plan); err != nil {
		return WorkspaceBranchPlan{}, err
	}
	plan.Steps, plan.Skipped = nonNil(plan.Steps), nonNil(plan.Skipped)
	return plan, nil
}

// workspaceRepositoryReferences is repositories with every list present, as Core requires.
func workspaceRepositoryReferences(repositories []WorkspaceRepositoryReferences) []WorkspaceRepositoryReferences {
	out := make([]WorkspaceRepositoryReferences, len(repositories))
	for i, repository := range repositories {
		out[i] = WorkspaceRepositoryReferences{ID: repository.ID, References: nonNil(repository.References)}
	}
	return out
}
