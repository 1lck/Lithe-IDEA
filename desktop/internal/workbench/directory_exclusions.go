package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"path"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file excludes a folder of the project from search (matrix id workspace-indexing-exclusions):
// the folder's rule goes through Core's workspace.reduceDirectoryAction, and the rule state of the
// project is stored in the client's store, one file per project folder, verbatim as Core returned
// it. Core's search does not take these rules yet, so the exclusion is kept but not yet applied
// to search results (recorded as a Core gap).

// directoryRulesFile is the stored rules of one project folder.
type directoryRulesFile struct {
	Root  string          `json:"root"`
	Rules json.RawMessage `json:"rules"`
}

// directoryRulesName is the store name of the rules of the project folder root.
func directoryRulesName(root string) string {
	sum := sha256.Sum256([]byte(root))
	return "workspace-directory-rules-" + hex.EncodeToString(sum[:8]) + ".json"
}

// excludeFromSearch applies the exclusion of the folder at rel (project-relative, "/" separators)
// to the project's stored rules, and stores the result when Core changed it.
func (a *App) excludeFromSearch(p *project, rel string) {
	kernel, ok := a.kernel.(interface {
		ExcludeDirectory(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error)
	})
	if !ok || a.store == nil {
		return
	}
	a.performed("workspace.tree.excludeFromSearch", surfaceMenu)
	root, s := p.root, a.store
	name := directoryRulesName(root)
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		var stored directoryRulesFile
		_, loadErr := s.Load(name, &stored)
		rules := stored.Rules
		if loadErr != nil {
			rules = nil
		}
		if len(rules) == 0 {
			rules = core.EmptyDirectoryRules()
		}
		changed, next, err := kernel.ExcludeDirectory(ctx, path.Clean(rel), false, rules)
		if err == nil && changed {
			err = s.Save(name, directoryRulesFile{Root: root, Rules: next})
		}
		return func(a *App) {
			if err != nil {
				a.notify(i18n.SharedFormat(a.language(), "desktop.files.excludeFailed", map[string]string{"reason": reviewReason(err)}))
				a.gitOperationFailed("workspace_exclude", err)
			}
		}
	})
}
