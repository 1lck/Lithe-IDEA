package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file excludes an untracked file or folder from Git on this machine only (matrix id
// workspace-indexing-exclusions): the pattern is added to the common directory's info/exclude,
// which Git reads like .gitignore but which is never committed. The repository's common
// directory comes from Core's watch context, so a linked worktree or a submodule writes to the
// right place. Directory exclusions from the search index are not implemented.

// excludeLocallyPattern is the info/exclude pattern of the change at repository path rel: anchored
// at the repository root, with a trailing slash for a folder, and special characters escaped.
func excludeLocallyPattern(rel string) string {
	folder := strings.HasSuffix(rel, "/")
	body := strings.TrimSuffix(rel, "/")
	var b strings.Builder
	b.WriteByte('/')
	for i, r := range body {
		if (i == 0 && (r == '#' || r == '!')) || r == '*' || r == '?' || r == '[' || r == '\\' {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	if folder {
		b.WriteByte('/')
	}
	return b.String()
}

// excludeLocally adds the change's pattern to the repository's info/exclude and reads the status
// again.
func (a *App) excludeLocally(p *project, change core.GitChange) {
	kernel, ok := a.kernel.(gitObserveKernel)
	if !ok {
		return
	}
	a.performed("git.excludeLocally", surfaceMenu)
	root := p.git.repositoryRoot(p.root)
	pattern := excludeLocallyPattern(change.Path)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		watch, found, err := kernel.GitWatchContextOf(ctx, root)
		if err == nil && !found {
			err = errors.New("not a Git repository")
		}
		if err == nil {
			err = appendInfoExclude(watch.GitCommonDirectory, pattern)
		}
		return func(a *App) {
			if err != nil {
				a.notify(i18n.SharedFormat(a.language(), "desktop.git.excludeFailed", map[string]string{"reason": reviewReason(err)}))
				a.gitOperationFailed("git_exclude", err)
			}
			a.loadGit(p)
		}
	})
}

// appendInfoExclude appends pattern to commonDir/info/exclude unless the file already has that
// line. The file is created with its directory when missing.
func appendInfoExclude(commonDir, pattern string) error {
	dir := filepath.Join(commonDir, "info")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	file := filepath.Join(dir, "exclude")
	existing, err := os.ReadFile(file)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	for _, line := range strings.Split(string(existing), "\n") {
		if line == pattern {
			return nil
		}
	}
	prefix := ""
	if len(existing) > 0 && !strings.HasSuffix(string(existing), "\n") {
		prefix = "\n"
	}
	out, err := os.OpenFile(file, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	if _, err := out.WriteString(prefix + pattern + "\n"); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
