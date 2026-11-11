package core

import (
	"context"
	"encoding/json"
)

// IndexingPolicy is what a project leaves out of its search indexes, installed with
// workspace.configureIndexing: the folders excluded by hand, the folders kept although
// Git ignores them, and whether folders Git ignores are left out on their own.
// Folders are workspace-relative with "/" separators.
type IndexingPolicy struct {
	ManualExcludedDirectories []string `json:"manualExcludedDirectories"`
	IncludedDirectories       []string `json:"includedDirectories"`
	GitIgnoreEnabled          bool     `json:"gitIgnoreEnabled"`
}

// IndexingStatus is the policy Core holds for a root: its release token, the reasons of
// the folders resolved so far (not every folder), and whether Git's answers are
// incomplete, in which case only the manual exclusions are sure to apply.
type IndexingStatus struct {
	Revision            uint64            `json:"revision"`
	ExcludedDirectories map[string]string `json:"excludedDirectories"`
	GitIgnoreFailed     bool              `json:"gitIgnoreFailed"`
}

// IndexingPolicyOf derives the policy of a root from its persisted directory rules (the
// state workspace.reduceDirectoryAction returns): the folders whose role is "excluded"
// and the include exceptions.
func IndexingPolicyOf(rules json.RawMessage, gitIgnore bool) IndexingPolicy {
	var state struct {
		Marks               map[string]string `json:"marks"`
		IncludedDirectories []string          `json:"includedDirectories"`
	}
	_ = json.Unmarshal(rules, &state)
	policy := IndexingPolicy{ManualExcludedDirectories: []string{}, IncludedDirectories: []string{}, GitIgnoreEnabled: gitIgnore}
	for path, role := range state.Marks {
		if role == "excluded" {
			policy.ManualExcludedDirectories = append(policy.ManualExcludedDirectories, path)
		}
	}
	policy.IncludedDirectories = append(policy.IncludedDirectories, state.IncludedDirectories...)
	return policy
}

// ConfigureIndexing installs policy for root under owner, the identity of one project
// window's lifetime. refresh retires the previous generation and its caches.
func (c *Client) ConfigureIndexing(ctx context.Context, root, owner string, policy IndexingPolicy, refresh bool) (IndexingStatus, error) {
	payload := struct {
		Root    string `json:"root"`
		OwnerID string `json:"ownerId,omitempty"`
		IndexingPolicy
		Refresh bool `json:"refresh"`
	}{root, owner, policy, refresh}
	var status IndexingStatus
	err := c.Execute(ctx, "workspace.configureIndexing", payload, &status)
	return status, err
}

// ReleaseIndexing gives up owner's lease on root, given the revision it last saw. The
// last lease to go retires the policy and clears the root's indexes.
func (c *Client) ReleaseIndexing(ctx context.Context, root, owner string, revision uint64) (bool, error) {
	payload := struct {
		Root     string `json:"root"`
		OwnerID  string `json:"ownerId,omitempty"`
		Revision uint64 `json:"revision"`
	}{root, owner, revision}
	var response struct {
		Released bool `json:"released"`
	}
	err := c.Execute(ctx, "workspace.releaseIndexing", payload, &response)
	return response.Released, err
}
