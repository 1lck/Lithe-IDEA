package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"slices"
	"sync/atomic"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file keeps folders of the project out of search (matrix id workspace-indexing-exclusions).
// A folder's rule goes through Core's workspace.reduceDirectoryAction, and the rule state of the
// project is stored in the client's store, one file per project folder, verbatim as Core returned
// it, with whether folders Git ignores are left out too. As the project opens, and whenever its
// rules change, the policy they make is installed in Core (workspace.configureIndexing) under
// this window's lease, which every search, index and language-server sync of the root obeys;
// closing the project releases the lease. The tree keeps showing excluded folders.

// directoryRulesFile is the stored rules of one project folder.
type directoryRulesFile struct {
	Root  string          `json:"root"`
	Rules json.RawMessage `json:"rules"`
	// GitIgnoreDisabled keeps the folders Git ignores in the indexes; by default they are left out.
	GitIgnoreDisabled bool `json:"gitIgnoreDisabled,omitempty"`
}

// projectIndexing is the policy a project installed in Core: its rules as stored, the lease the
// window holds and what Core answered.
type projectIndexing struct {
	owner     string
	rules     json.RawMessage
	gitIgnore bool
	loaded    bool
	status    core.IndexingStatus
	// generation rejects an installation a newer one replaced; warned keeps the Git warning to once.
	generation uint64
	warned     bool
}

// indexingKernel is the part of Core the exclusions use.
type indexingKernel interface {
	ExcludeDirectory(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error)
	CancelDirectoryExclusion(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error)
	ConfigureIndexing(ctx context.Context, root, owner string, policy core.IndexingPolicy, refresh bool) (core.IndexingStatus, error)
	ReleaseIndexing(ctx context.Context, root, owner string, revision uint64) (bool, error)
}

// indexingOwners numbers the leases of this process.
var indexingOwners atomic.Uint64

// installIndexing reads the project's stored rules the first time and installs the policy they
// make; refresh retires what Core had cached under the previous one.
func (a *App) installIndexing(p *project, refresh bool) {
	kernel, ok := a.kernel.(indexingKernel)
	if !ok || a.store == nil {
		return
	}
	ix := &p.indexing
	if ix.owner == "" {
		ix.owner = fmt.Sprintf("viva-%d-%d", os.Getpid(), indexingOwners.Add(1))
	}
	ix.generation++
	generation, root, owner, s := ix.generation, p.root, ix.owner, a.store
	loaded, rules, gitIgnore := ix.loaded, ix.rules, ix.gitIgnore
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		if !loaded {
			var stored directoryRulesFile
			if found, err := s.Load(directoryRulesName(root), &stored); err == nil && found {
				rules, gitIgnore = stored.Rules, !stored.GitIgnoreDisabled
			} else {
				rules, gitIgnore = nil, true
			}
		}
		status, err := kernel.ConfigureIndexing(ctx, root, owner, core.IndexingPolicyOf(rules, gitIgnore), refresh)
		return func(a *App) {
			if !loaded && !ix.loaded {
				ix.rules, ix.gitIgnore, ix.loaded = rules, gitIgnore, true
			}
			if ix.generation != generation {
				return
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_indexing", err))
				a.notifyError(i18n.Shared(a.language(), "indexing.configureFailed"))
				return
			}
			ix.status = status
			if status.GitIgnoreFailed && !ix.warned {
				ix.warned = true
				a.notifyInfo(i18n.Shared(a.language(), "indexing.gitFailed"))
			}
			// Search results cached under the previous policy are stale.
			a.searchView.reset()
		}
	})
}

// releaseIndexing gives up the project's lease as it closes. It runs past the project's end.
func (a *App) releaseIndexing(p *project) {
	kernel, ok := a.kernel.(indexingKernel)
	ix := &p.indexing
	if !ok || ix.owner == "" {
		return
	}
	ix.generation++
	root, owner, revision := p.root, ix.owner, ix.status.Revision
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
		defer cancel()
		if _, err := kernel.ReleaseIndexing(ctx, root, owner, revision); err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("workspace_indexing_release", err))
		}
	}()
}

// directoryExcluded reports whether the folder at rel is known to be left out of search, and
// whether by hand.
func (p *project) directoryExcluded(rel string) bool {
	_, ok := p.indexing.status.ExcludedDirectories[path.Clean(rel)]
	return ok || slices.Contains(core.IndexingPolicyOf(p.indexing.rules, false).ManualExcludedDirectories, path.Clean(rel))
}

// directoryRulesName is the store name of the rules of the project folder root.
func directoryRulesName(root string) string {
	sum := sha256.Sum256([]byte(root))
	return "workspace-directory-rules-" + hex.EncodeToString(sum[:8]) + ".json"
}

// excludeFromSearch leaves the folder at rel (project-relative, "/" separators) out of search;
// cancel puts it back (a folder Git ignores becomes an exception). The new rules are stored and
// installed.
func (a *App) excludeFromSearch(p *project, rel string, cancel bool) {
	kernel, ok := a.kernel.(indexingKernel)
	if !ok || a.store == nil || !p.indexing.loaded {
		return
	}
	if cancel {
		a.performed("workspace.tree.cancelExclusion", surfaceMenu)
	} else {
		a.performed("workspace.tree.excludeFromSearch", surfaceMenu)
	}
	a.changeIndexingRules(p, func(ctx context.Context, rules json.RawMessage) (bool, json.RawMessage, error) {
		if cancel {
			return kernel.CancelDirectoryExclusion(ctx, path.Clean(rel), false, rules)
		}
		return kernel.ExcludeDirectory(ctx, path.Clean(rel), false, rules)
	}, p.indexing.gitIgnore)
}

// setGitIgnoreIndexing turns the automatic exclusion of folders Git ignores on or off.
func (a *App) setGitIgnoreIndexing(p *project, on bool) {
	if !p.indexing.loaded || p.indexing.gitIgnore == on {
		return
	}
	a.performed("workspace.indexing.gitIgnore", surfaceMenu)
	a.changeIndexingRules(p, func(context.Context, json.RawMessage) (bool, json.RawMessage, error) {
		return true, p.indexing.rules, nil
	}, on)
}

// changeIndexingRules applies reduce to the project's rules off the window thread, stores the
// result with gitIgnore and installs it.
func (a *App) changeIndexingRules(p *project, reduce func(context.Context, json.RawMessage) (bool, json.RawMessage, error), gitIgnore bool) {
	root, s := p.root, a.store
	rules := p.indexing.rules
	if len(rules) == 0 {
		rules = core.EmptyDirectoryRules()
	}
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		changed, next, err := reduce(ctx, rules)
		if err == nil && changed {
			err = s.Save(directoryRulesName(root), directoryRulesFile{Root: root, Rules: next, GitIgnoreDisabled: !gitIgnore})
		}
		return func(a *App) {
			if err != nil {
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.files.excludeFailed", map[string]string{"reason": reviewReason(err)}))
				a.gitOperationFailed("workspace_exclude", err)
				return
			}
			if !changed {
				return
			}
			p.indexing.rules, p.indexing.gitIgnore = next, gitIgnore
			if a.project == p {
				a.installIndexing(p, true)
			}
		}
	})
}
