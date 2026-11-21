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
// again. A remote workspace's repository is on its host, where the file is written
// (remoteDocuments.appendInfoExclude).
func (a *App) excludeLocally(p *project, change core.GitChange) {
	kernel, ok := a.kernel.(gitObserveKernel)
	if !ok {
		return
	}
	a.performed("git.excludeLocally", surfaceContextMenu)
	root := p.git.repositoryRoot(p.root)
	pattern := excludeLocallyPattern(change.Path)
	host := a.remoteDocuments(p)
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		watch, found, err := kernel.GitWatchContextOf(ctx, root)
		if err == nil && !found {
			err = errors.New("not a Git repository")
		}
		if err == nil && host != nil {
			err = host.appendInfoExclude(ctx, watch.GitCommonDirectory, pattern)
		} else if err == nil {
			err = appendInfoExclude(watch.GitCommonDirectory, pattern)
		}
		return func(a *App) {
			if err != nil {
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.git.excludeFailed", map[string]string{"reason": a.excludeFailureReason(err)}))
				a.operationFailed("git_exclude", p.logError(documentLogError(err)))
			}
			a.reloadGit(p)
		}
	})
}

// excludeFailureReason is the words for a failed exclusion: a remote workspace's own reasons, such
// as a lost connection, or the error itself.
func (a *App) excludeFailureReason(err error) string {
	if reason, ok := a.remoteDocumentReason(err); ok {
		return reason
	}
	return reviewReason(err)
}

// infoExcludeAddition is the text that adds pattern to an info/exclude that holds existing; ok is
// false when the file already has that line.
func infoExcludeAddition(existing []byte, pattern string) (addition string, ok bool) {
	for _, line := range strings.Split(string(existing), "\n") {
		if line == pattern {
			return "", false
		}
	}
	if len(existing) > 0 && !strings.HasSuffix(string(existing), "\n") {
		return "\n" + pattern + "\n", true
	}
	return pattern + "\n", true
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
	addition, ok := infoExcludeAddition(existing, pattern)
	if !ok {
		return nil
	}
	out, err := os.OpenFile(file, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	if _, err := out.WriteString(addition); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
