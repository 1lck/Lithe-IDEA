package toolchain

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/vivaui/viva/app"
)

// Each round uses at most this many native registrations, including parent
// directories used to follow atomic replacements and missing inputs.
const providerWatchDirectories = 32

type providerObservation struct {
	mu      sync.Mutex
	invalid bool
	watches []providerDirectory
	facts   map[string]os.FileInfo
}

type providerDirectory struct {
	watch *app.DirectoryWatch
	names map[string]bool
	all   bool
}

type providerWatchTarget struct {
	names map[string]bool
	all   bool
}

// Observe existing directories and the nearest existing ancestors of missing
// paths. The latter watches the next path component being created.
func observeProviderInputs(paths []string, queryStarted time.Time) (*providerObservation, error) {
	targets := make(map[string]providerWatchTarget)
	facts := make(map[string]os.FileInfo)
	for _, name := range uniqueSorted(paths) {
		name = filepath.FromSlash(name)
		if !filepath.IsAbs(name) {
			continue
		}
		path := name
		var prior os.FileInfo
		for {
			info, err := os.Stat(path)
			if err == nil {
				if path == name && !info.ModTime().Before(queryStarted) {
					return nil, errProviderGenerationChanged
				}
				prior = info
				break
			}
			if !errors.Is(err, os.ErrNotExist) {
				return nil, err
			}
			parent := filepath.Dir(path)
			if parent == path {
				return nil, nil
			}
			path = parent
		}
		facts[path] = prior
		if path != name {
			facts[name] = nil
		}
		if path == name && prior.IsDir() {
			target := targets[path]
			target.all = true
			targets[path] = target
		}
		if path == name {
			path = filepath.Dir(name)
		}
		if name != path {
			relative, err := filepath.Rel(path, name)
			if err != nil {
				return nil, err
			}
			next, _, _ := strings.Cut(relative, string(filepath.Separator))
			target := targets[path]
			if target.names == nil {
				target.names = make(map[string]bool)
			}
			target.names[nativeFileKey(next)] = true
			targets[path] = target
		}
		if len(targets) > providerWatchDirectories {
			return nil, nil
		}
	}
	observation := &providerObservation{facts: facts}
	for name, target := range targets {
		// The watcher queues input changes. Consumers drain on demand off the
		// window thread; the notification callback never blocks or closes it.
		watch, err := app.WatchDirectory(name, func() {})
		if err != nil {
			observation.close()
			return nil, err
		}
		observation.watches = append(observation.watches, providerDirectory{watch: watch, names: target.names, all: target.all})
	}
	if !observation.current() {
		observation.close()
		return nil, errProviderGenerationChanged
	}
	return observation, nil
}

func (o *providerObservation) current() bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	for path, previous := range o.facts {
		current, err := os.Stat(path)
		// log-exempt: 预期的缺失：不存在的输入也是可观察状态。
		if previous == nil && errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil || previous == nil || !os.SameFile(previous, current) || previous.Mode() != current.Mode() ||
			previous.Size() != current.Size() || !previous.ModTime().Equal(current.ModTime()) {
			o.invalid = true
			break
		}
	}
	return !o.invalid && o.drainLocked()
}

func (o *providerObservation) drainLocked() bool {
	for _, entry := range o.watches {
		changes := entry.watch.Changes(nil)
		if changes.Resync || (entry.all && len(changes.Names) != 0) {
			o.invalid = true
			return false
		}
		for _, name := range changes.Names {
			if entry.names[nativeFileKey(name)] {
				o.invalid = true
				return false
			}
		}
	}
	return true
}

func (o *providerObservation) close() {
	o.mu.Lock()
	o.drainLocked()
	watches := o.watches
	o.watches = nil
	o.mu.Unlock()
	for _, entry := range watches {
		entry.watch.Close()
	}
}

func nativeFileKey(name string) string {
	if runtime.GOOS == "windows" {
		return strings.ToLower(name)
	}
	return name
}
