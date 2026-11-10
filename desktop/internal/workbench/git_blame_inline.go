package workbench

import (
	"context"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file shows the Git blame of the caret line after its text. Core reads the blame of the
// saved file (git.blame) and the subject of its commit (git.commit). The blame is read when a file
// is saved and when the history moves (a commit, a ref or HEAD); until the next read the previous
// lines stay. Only the caret line is annotated, so no line costs a frame of its own.

const (
	// blameSubjectLimit bounds the commit subjects kept for the annotations of a project.
	blameSubjectLimit = 256
	// blameMinute, blameHour and the others are the steps of the relative time.
	blameMinute = time.Minute
	blameHour   = time.Hour
	blameDay    = 24 * time.Hour
	blameMonth  = 30 * blameDay
	blameYear   = 365 * blameDay
)

// gitCommitKernel reads one commit; the blame annotation takes its subject from it.
type gitCommitKernel interface {
	GitCommit(ctx context.Context, root, commit string) (core.GitCommitDetail, error)
}

// inlineBlame is one file's blame and the caret line the annotation was last built for.
type inlineBlame struct {
	gen   int
	lines []core.GitBlameLine
	// shown is the caret line the annotation shows, -1 for none.
	shown int
	// text is the annotation shown, for the caret line; a change of it re-sets the view.
	text string
}

// gitBlameSubjects is the project's cache of commit subjects, and the hashes being read.
type gitBlameSubjects struct {
	subjects map[string]string
	pending  map[string]bool
}

// refreshInlineBlame reads the blame of one open file in the background, when the setting is on.
// Its previous lines stay until the answer arrives; a failed read keeps them too.
func (a *App) refreshInlineBlame(p *project, d *document) {
	if p == nil || d == nil || d.virtual || p.docs.find(d.id) != d {
		return
	}
	if !a.settings.InlineGitBlame {
		d.blame.lines, d.blame.shown, d.blame.text = nil, -1, ""
		d.view.SetLineAnnotations(nil)
		return
	}
	kernel, ok := a.reviewKernel()
	if !ok || !p.git.isRepository() {
		return
	}
	root := p.git.repositoryRoot(p.root)
	rel, ok := gitRelativePath(root, d.path)
	if !ok {
		return
	}
	d.blame.gen++
	gen := d.blame.gen
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		// The inline blame follows every opened file and history change, too often for the
		// console; the blame the user asks for is recorded.
		lines, err := kernel.GitBlame(core.AutomaticRefresh(ctx), root, rel)
		return func(a *App) {
			if d.blame.gen != gen || p.docs.find(d.id) != d || !a.settings.InlineGitBlame {
				return
			}
			if err != nil {
				a.gitOperationFailed("git_blame_inline", err)
				return
			}
			d.blame.lines = lines
			d.blame.shown, d.blame.text = -1, ""
			a.applyInlineBlame(p, d)
		}
	})
}

// refreshInlineBlames reads the blame of every open file of the project.
func (a *App) refreshInlineBlames(p *project) {
	for _, d := range p.docs.list {
		a.refreshInlineBlame(p, d)
	}
}

// setInlineGitBlame stores the Version Control switch and applies it to the open files at once.
func (a *App) setInlineGitBlame(on bool) {
	if a.settings.InlineGitBlame == on {
		return
	}
	a.settings.InlineGitBlame = on
	a.saveSettings()
	if p := a.project; p != nil {
		a.refreshInlineBlames(p)
	}
}

// applyInlineBlame sets the annotation of the caret line. It runs in every paint of the file, so
// it does nothing unless the caret moved or the blame changed. A file with unsaved edits shows
// none, since the blame describes the saved file.
func (a *App) applyInlineBlame(p *project, d *document) {
	if !a.settings.InlineGitBlame || d.dirty() {
		if d.blame.shown != -1 {
			d.blame.shown, d.blame.text = -1, ""
			d.view.SetLineAnnotations(nil)
		}
		return
	}
	line, _ := d.view.Caret()
	if line == d.blame.shown {
		return
	}
	d.blame.shown, d.blame.text = line, ""
	text, ok := a.blameAnnotation(p, d, line)
	if !ok {
		d.view.SetLineAnnotations(nil)
		return
	}
	d.blame.text = text
	d.view.SetLineAnnotations([]editorview.LineAnnotation{{Line: line, Text: text}})
}

// blameAnnotation is the text of the blame of a zero-based line: author, relative time and the
// commit subject. It reports false while the subject is being read, which then runs again.
func (a *App) blameAnnotation(p *project, d *document, line int) (string, bool) {
	// The blame is ordered by one-based line; the caret line is usually at its own index.
	var entry core.GitBlameLine
	found := false
	if line < len(d.blame.lines) && d.blame.lines[line].Line == line+1 {
		entry, found = d.blame.lines[line], true
	} else {
		for _, l := range d.blame.lines {
			if l.Line == line+1 {
				entry, found = l, true
				break
			}
		}
	}
	if !found {
		return "", false
	}
	language := a.language()
	if entry.Uncommitted() {
		return i18n.Shared(language, "desktop.git.blame.uncommitted"), true
	}
	subject, ok := a.blameSubject(p, entry.Hash)
	if !ok {
		return "", false
	}
	return i18n.SharedFormat(language, "desktop.git.blame.annotation", map[string]string{
		"author":  entry.AuthorName,
		"time":    relativeGitTime(language, time.Now(), time.Unix(entry.AuthorTime, 0)),
		"subject": subject,
	}), true
}

// blameSubject is the subject of a commit from the project's cache. A miss starts one read in
// the background and reports false.
func (a *App) blameSubject(p *project, hash string) (string, bool) {
	cache := &p.blame
	if subject, ok := cache.subjects[hash]; ok {
		return subject, true
	}
	kernel, ok := a.kernel.(gitCommitKernel)
	if !ok || cache.pending[hash] {
		return "", false
	}
	if cache.pending == nil {
		cache.pending = map[string]bool{}
	}
	cache.pending[hash] = true
	root := p.git.repositoryRoot(p.root)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		detail, err := kernel.GitCommit(ctx, root, hash)
		return func(a *App) {
			delete(cache.pending, hash)
			if err != nil {
				a.gitOperationFailed("git_blame_subject", err)
				return
			}
			if cache.subjects == nil || len(cache.subjects) >= blameSubjectLimit {
				cache.subjects = map[string]string{}
			}
			cache.subjects[hash] = detail.Commit.Subject
			a.invalidator.Invalidate()
		}
	})
	return "", false
}

// relativeGitTime words how long ago a commit was made, in the language of the window.
func relativeGitTime(language i18n.Language, now, then time.Time) string {
	age := now.Sub(then)
	count := func(n int64) string { return strconv.FormatInt(n, 10) }
	switch {
	case age < blameMinute:
		return i18n.Shared(language, "desktop.git.time.justNow")
	case age < blameHour:
		return i18n.SharedFormat(language, "desktop.git.time.minutesAgo", map[string]string{"count": count(int64(age / blameMinute))})
	case age < blameDay:
		return i18n.SharedFormat(language, "desktop.git.time.hoursAgo", map[string]string{"count": count(int64(age / blameHour))})
	case age < blameMonth:
		return i18n.SharedFormat(language, "desktop.git.time.daysAgo", map[string]string{"count": count(int64(age / blameDay))})
	case age < blameYear:
		return i18n.SharedFormat(language, "desktop.git.time.monthsAgo", map[string]string{"count": count(int64(age / blameMonth))})
	default:
		return i18n.SharedFormat(language, "desktop.git.time.yearsAgo", map[string]string{"count": count(int64(age / blameYear))})
	}
}
