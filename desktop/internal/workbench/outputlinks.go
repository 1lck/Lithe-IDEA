package workbench

import (
	"context"
	"encoding/json"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

const (
	// outputLinkBatch is the most lines one match request carries; Core refuses more.
	outputLinkBatch = 256
	// outputLinkCacheLimit bounds the remembered answers. A console is bounded
	// too, so the cache is dropped as a whole rather than aged.
	outputLinkCacheLimit = 4000
	// outputLinkTimeout bounds one Core match or one open of a link.
	outputLinkTimeout = 15 * time.Second

	outputScopeRun  = "run"
	outputScopeTest = "test"
)

// outputLinkState is one project's output link matchers and what Core answered
// for the console lines shown so far. Core decides what is a link, the web
// addresses a line prints too, so lines are matched without any plugin; this only
// remembers the answers so a line is matched once, not on every frame.
type outputLinkState struct {
	sources []core.OutputLinkSource
	loaded  bool
	loading bool
	// links holds the answer for a scope and line; an empty slice is "no link".
	links map[string][]core.OutputLink
	// wanted collects the lines of one frame that have no answer yet.
	wanted   map[string]outputLinkWant
	inFlight bool
}

type outputLinkWant struct{ scope, line string }

func outputLinkKey(scope, line string) string { return scope + "\x00" + line }

// reloadOutputLinks drops the matchers and answers, for after the plugin set or a
// run's plugin changed.
func (p *project) reloadOutputLinks() {
	p.links = outputLinkState{}
}

// outputLinksFor returns the links of one console line, or none while the
// answer is still being asked for. It runs while the panel is drawn and never
// blocks: a line without an answer is queued and the panel redraws when it
// arrives.
func (a *App) outputLinksFor(p *project, scope, line string) []core.OutputLink {
	l := &p.links
	if !l.loaded {
		if !l.loading {
			a.loadOutputLinkSources(p)
		}
		return nil
	}
	// Core links web addresses with no matcher, so a window without plugins asks too,
	// but only for a line that could hold one.
	if line == "" || len(l.sources) == 0 && !strings.Contains(line, "://") {
		return nil
	}
	key := outputLinkKey(scope, line)
	if links, ok := l.links[key]; ok {
		return links
	}
	if l.wanted == nil {
		l.wanted = make(map[string]outputLinkWant)
	}
	l.wanted[key] = outputLinkWant{scope: scope, line: line}
	return nil
}

// loadOutputLinkSources reads the matchers of the enabled plugins in the
// background. A window without plugins has none.
func (a *App) loadOutputLinkSources(p *project) {
	if a.plugins == nil {
		p.links.loaded = true
		return
	}
	p.links.loading = true
	a.background(p, outputLinkTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			return func(a *App) { a.finishOutputLinkSources(p, nil, err) }
		}
		sources, err := a.plugins.OutputLinkSources(ctx, entries)
		return func(a *App) { a.finishOutputLinkSources(p, sources, err) }
	})
}

func (a *App) finishOutputLinkSources(p *project, sources []core.OutputLinkSource, err error) {
	p.links.loading = false
	p.links.loaded = true
	p.links.sources = sources
	if err != nil {
		a.backgroundFailed("output_links", err)
	}
}

// flushOutputLinks sends the lines drawn this frame that have no answer to Core,
// one request per scope. Matching runs on a background goroutine; the answers
// are applied on the window thread, which asks for a redraw.
func (a *App) flushOutputLinks(p *project) {
	l := &p.links
	if len(l.wanted) == 0 || l.inFlight {
		return
	}
	byScope := make(map[string][]string)
	for _, want := range l.wanted {
		byScope[want.scope] = append(byScope[want.scope], want.line)
	}
	l.wanted = nil
	l.inFlight = true
	// A window without plugins still asks for the web addresses, with an empty list Core
	// accepts rather than null.
	sources := l.sources
	if sources == nil {
		sources = []core.OutputLinkSource{}
	}
	roots, platform := []string{p.root}, buildPlatform()
	if p.remote != nil {
		// A remote workspace's programs print host paths: Core matches them against the host
		// folder, as paths of a Unix host (Linux and macOS name paths alike here).
		roots, platform = []string{p.remote.binding.RemoteRoot()}, "linux"
	}
	kernel := a.kernel
	a.background(p, outputLinkTimeout, func(ctx context.Context) func(*App) {
		answers := make(map[string][]core.OutputLink)
		var failure error
		for scope, lines := range byScope {
			sort.Strings(lines)
			for start := 0; start < len(lines); start += outputLinkBatch {
				batch := lines[start:min(start+outputLinkBatch, len(lines))]
				links, err := kernel.MatchOutputLinks(ctx, core.OutputLinkRequest{
					Scope: scope, Platform: platform, WorkspaceRoots: roots, Sources: sources, Lines: batch,
				})
				if err != nil {
					failure = err
					// Remember "no link" so a failing request is not repeated every frame.
					for _, line := range batch {
						answers[outputLinkKey(scope, line)] = nil
					}
					continue
				}
				for _, line := range batch {
					answers[outputLinkKey(scope, line)] = nil
				}
				for _, link := range links {
					if link.Line < 0 || link.Line >= len(batch) {
						continue
					}
					key := outputLinkKey(scope, batch[link.Line])
					answers[key] = append(answers[key], link)
				}
			}
		}
		return func(a *App) {
			l := &p.links
			l.inFlight = false
			if len(l.links)+len(answers) > outputLinkCacheLimit {
				l.links = nil
			}
			if l.links == nil {
				l.links = make(map[string][]core.OutputLink, len(answers))
			}
			for key, links := range answers {
				l.links[key] = links
			}
			if failure != nil {
				a.backgroundFailed("output_links", failure)
			}
		}
	})
}

// openOutputLink opens what a clicked link points at. A web address opens in the
// browser. A location names candidate files and opens the first that exists; a
// link that needs its plugin asks the plugin's backend first. Both run off the
// window thread, and a file that does not exist is a notice, not a navigation.
func (a *App) openOutputLink(p *project, link core.OutputLink) {
	messages := a.text.Run
	switch {
	case link.URL != "":
		a.performed("output.link.openURL", surfaceButton)
		if err := openURL(link.URL); err != nil {
			a.operationFailed("output_link_open_url", err)
			a.notifyError(i18n.SharedFormat(a.language(), "desktop.editor.linkOpenFailed", map[string]string{"reason": err.Error()}))
		}
	case link.Location != nil:
		location := *link.Location
		find := firstExistingFile
		if p.remote != nil {
			find = p.remoteFileFinder(a.kernel)
		}
		a.background(p, outputLinkTimeout, func(ctx context.Context) func(*App) {
			path := find(ctx, location.Paths)
			if path == "" {
				return func(a *App) {
					a.operationRejected("output_link_open", "target_missing")
					a.notifyError(messages.LinkMissing)
				}
			}
			return func(a *App) { a.openFileAtPosition(p, path, zeroBased(location.Line), zeroBased(location.Column)) }
		})
	case link.Resolve != nil && p.remote != nil:
		// The plugin that resolves the link reads this computer's files, not the host's.
		a.refuseRemote(p, "output_link_resolve")
	case link.Resolve != nil && a.plugins != nil:
		function, groups, pluginID := link.Resolve.Function, link.Resolve.Groups, link.PluginID
		a.background(p, outputLinkTimeout, func(ctx context.Context) func(*App) {
			location, err := a.plugins.ResolveOutputLink(ctx, pluginID, function, json.RawMessage(groups), p.root)
			if err != nil {
				return func(a *App) {
					a.operationFailed("output_link_resolve", err)
					a.notifyError(messages.LinkUnresolved)
				}
			}
			if location == nil {
				return func(a *App) {
					a.operationRejected("output_link_open", "unresolved")
					a.notifyError(messages.LinkUnresolved)
				}
			}
			path := firstExistingFile(ctx, []string{location.Path})
			if path == "" {
				return func(a *App) {
					a.operationRejected("output_link_open", "target_missing")
					a.notifyError(messages.LinkMissing)
				}
			}
			return func(a *App) { a.openFileAtPosition(p, path, zeroBased(location.Line), zeroBased(location.Column)) }
		})
	}
}

// zeroBased converts Core's 1-based position to the editor's 0-based one; an
// absent position is the start of the file.
func zeroBased(position int) int {
	if position <= 1 {
		return 0
	}
	return position - 1
}

// firstExistingFile returns the first candidate that is a regular file of this computer.
func firstExistingFile(_ context.Context, candidates []string) string {
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
			return candidate
		}
	}
	return ""
}

// remoteFileFinder finds, for a remote workspace, the first candidate host path that is a file
// on the host, and returns its path in the workspace's placeholder, which the editor opens
// through the host (remoteplaceholder.LocalPath). A host that does not answer finds none. It is
// taken on the window thread and runs off it.
func (p *project) remoteFileFinder(kernel Kernel) func(context.Context, []string) string {
	root, binding := p.root, p.remote.binding
	remoteRoot := binding.RemoteRoot()
	return func(ctx context.Context, candidates []string) string {
		session := binding.SessionID()
		if session == "" {
			return ""
		}
		for _, candidate := range candidates {
			local, ok := remoteplaceholder.LocalPath(root, remoteRoot, candidate)
			if !ok {
				continue
			}
			if metadata, err := kernel.RemoteStat(ctx, session, candidate); err == nil && metadata.Kind == core.RemoteFileKindFile {
				return local
			}
		}
		return ""
	}
}
