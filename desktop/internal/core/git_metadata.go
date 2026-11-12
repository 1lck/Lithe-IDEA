package core

import "context"

// GitWatchContext is the absolute metadata roots a native file watcher observes for the
// repository around a folder.
type GitWatchContext struct {
	RepositoryRoot     string `json:"repositoryRoot"`
	GitDirectory       string `json:"gitDirectory"`
	GitCommonDirectory string `json:"gitCommonDirectory"`
}

// GitWatchContextOf resolves the repository metadata roots of root. It reports false when root
// is not inside a Git repository.
//
// GitWatchContextOf reads the file system and blocks; call it from a background goroutine.
func (c *Client) GitWatchContextOf(ctx context.Context, root string) (GitWatchContext, bool, error) {
	var response *GitWatchContext
	if err := c.Execute(ctx, "git.watchContext", gitRootRequest{Root: root}, &response); err != nil {
		return GitWatchContext{}, false, err
	}
	if response == nil {
		return GitWatchContext{}, false, nil
	}
	return *response, true, nil
}

// GitMetadataContext tells Core where a repository's metadata lives, for classification.
type GitMetadataContext struct {
	RepositoryRoot     string   `json:"repositoryRoot"`
	GitDirectory       string   `json:"gitDirectory"`
	GitCommonDirectory string   `json:"gitCommonDirectory"`
	WorkspaceRoot      string   `json:"workspaceRoot,omitempty"`
	RuleDirectories    []string `json:"ruleDirectories"`
}

// GitMetadataEvent is Core's reading of one watcher path: Kind is context, ignoreRule,
// metadata, ignored or other, and IndexOnly says only the index file changed.
type GitMetadataEvent struct {
	Kind      string `json:"kind"`
	IndexOnly bool   `json:"indexOnly"`
}

// maxMetadataPaths is the most paths one git.classifyMetadataChanges call takes.
const maxMetadataPaths = 256

// GitClassifyMetadataChanges classifies coalesced watcher paths, in order, without touching the
// file system. Paths are sent in batches of at most 256. A failure means the caller must
// conservatively scan the repository again.
func (c *Client) GitClassifyMetadataChanges(ctx context.Context, context GitMetadataContext, paths []string) ([]GitMetadataEvent, error) {
	context.RuleDirectories = nonNil(context.RuleDirectories)
	events := make([]GitMetadataEvent, 0, len(paths))
	for start := 0; start < len(paths); start += maxMetadataPaths {
		end := min(start+maxMetadataPaths, len(paths))
		var response struct {
			Events []GitMetadataEvent `json:"events"`
		}
		payload := struct {
			Context GitMetadataContext `json:"context"`
			Paths   []string           `json:"paths"`
		}{context, paths[start:end]}
		if err := c.Execute(ctx, "git.classifyMetadataChanges", payload, &response); err != nil {
			return nil, err
		}
		events = append(events, response.Events...)
	}
	return events, nil
}
