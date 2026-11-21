package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/vivaui/viva/app"
)

const (
	methodBuildGetOptions         = pluginhost.MethodPrefix + "build/getOptions"
	methodBuildWatchConfiguration = pluginhost.MethodPrefix + "build/watchConfiguration"
	maxBuildConfigurationFiles    = 4
	maxBuildConfigurationWatches  = 16
)

func (s *Service) buildCaller(ctx context.Context) (pluginhost.Caller, *BackendSession, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return caller, nil, failure(pluginhost.CodeHostFailure, "The request has no calling plugin.")
	}
	session := s.Host.Running(caller.PluginID)
	if session == nil || session.Session.ID != caller.SessionID {
		return caller, nil, failure(pluginhost.CodeCancelled, "The requesting backend session ended.")
	}
	return caller, session, nil
}

func (s *Service) handleBuildGetOptions(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context       ContextRef `json:"context"`
		BuildSystemID string     `json:"buildSystemID"`
		Root          string     `json:"root"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	_, session, refusal := s.buildCaller(ctx)
	if refusal != nil {
		return nil, refusal
	}
	workspace, err := s.Contexts.Lookup(request.Context)
	if err != nil {
		return nil, contextFailure(err)
	}
	resolver, ok := s.kernel.(interface {
		ResolveStoredInstanceOptions(context.Context, json.RawMessage, string, string, json.RawMessage, json.RawMessage) (json.RawMessage, error)
	})
	if !ok {
		return nil, failure(pluginhost.CodeHostFailure, "Build option resolution is unavailable.")
	}
	docs, err := buildprefs.Read(ctx, s.preferences, workspace.Path)
	if err != nil {
		return nil, failure(pluginhost.CodeHostFailure, "Build preferences could not be read.")
	}
	options, err := resolver.ResolveStoredInstanceOptions(ctx, session.manifest, request.BuildSystemID, request.Root, docs.Team, docs.Local)
	if err != nil {
		var rejected *core.MarketplaceRejection
		if errors.As(err, &rejected) {
			switch rejected.Code {
			case "plugin.build.unavailable":
				return nil, failure("plugin.host.foreignContribution", "The calling plugin does not declare this build system.")
			case "plugin.build.invalidRoot":
				return nil, failure("plugin.host.invalidParams", "The root must be a workspace-relative path.")
			}
		}
		return nil, failure(pluginhost.CodeHostFailure, "Build preferences could not be resolved.")
	}
	if _, err := s.Contexts.Lookup(request.Context); err != nil {
		return nil, contextFailure(err)
	}
	return marshalResult(map[string]json.RawMessage{"options": options})
}

func (s *Service) handleBuildWatchConfiguration(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context ContextRef `json:"context"`
		Files   []string   `json:"files"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	if len(request.Files) > maxBuildConfigurationFiles {
		return nil, failure("plugin.host.limitExceeded", "A build configuration watch accepts at most four extra files.")
	}
	caller, session, refusal := s.buildCaller(ctx)
	if refusal != nil {
		return nil, refusal
	}
	workspace, err := s.Contexts.Lookup(request.Context)
	if err != nil {
		return nil, contextFailure(err)
	}
	paths := []string{filepath.Join(workspace.Path, buildprefs.TeamFile), s.preferences.Path(buildprefs.LocalFile)}
	for _, file := range request.Files {
		if len(file) > 4096 || !filepath.IsAbs(file) || filepath.Clean(file) != file || filepath.Dir(file) == file || strings.ContainsRune(file, 0) {
			return nil, failure("plugin.host.invalidParams", "Each configuration file must be a normalized absolute file path.")
		}
		info, err := os.Stat(file)
		if err == nil && !info.Mode().IsRegular() {
			return nil, failure("plugin.host.invalidParams", "A configuration watch only accepts files.")
		}
		paths = append(paths, file)
	}

	lifetime, stop := context.WithCancel(context.Background())
	id := s.resources.addLimited(caller, workspace.ContextID, stop, maxBuildConfigurationWatches)
	if id == "" {
		stop()
		return nil, failure("plugin.host.limitExceeded", "The backend has reached its build configuration watch limit.")
	}
	if _, err := s.Contexts.Lookup(request.Context); err != nil || session.isEnded() {
		s.resources.dispose(caller, id)
		return nil, failure(pluginhost.CodeCancelled, "The workspace or backend session ended.")
	}
	wake := make(chan struct{}, 1)
	signal := func() {
		select {
		case wake <- struct{}{}:
		default:
		}
	}
	watches, err := watchBuildConfiguration(paths, signal)
	if err != nil && s.BuildConfigurationIssue != nil {
		s.BuildConfigurationIssue(ctx, err)
	}
	if err != nil || lifetime.Err() != nil {
		closeBuildWatches(watches)
		s.resources.dispose(caller, id)
		return nil, failure(pluginhost.CodeHostFailure, "Build configuration could not be watched.")
	}
	go func() {
		defer s.resources.dispose(caller, id)
		defer func() { closeBuildWatches(watches) }()
		var sequence uint64
		for {
			select {
			case <-lifetime.Done():
				return
			case <-wake:
			}
			changed, resync := drainBuildWatches(watches)
			if changed {
				targets, err := buildWatchTargets(paths)
				if err == nil && (resync || !sameBuildTargets(watches.targets, targets)) {
					var replacement buildConfigurationWatches
					replacement, err = watchBuildConfiguration(paths, signal)
					if err == nil {
						closeBuildWatches(watches)
						watches = replacement
					}
				}
				if err != nil {
					if s.BuildConfigurationIssue != nil {
						s.BuildConfigurationIssue(lifetime, err)
					}
					s.resources.dispose(caller, id)
					if _, contextErr := s.Contexts.Lookup(request.Context); contextErr == nil && !session.isEnded() {
						s.sendBuildChange(context.Background(), caller.SessionID, id, sequence+1, "watchFailed")
					}
					return
				}
			}
			if changed {
				sequence++
				s.sendBuildChange(lifetime, caller.SessionID, id, sequence, "changed")
			}
		}
	}()
	return marshalResult(map[string]string{"subscriptionID": id})
}

func (s *Service) sendBuildChange(parent context.Context, sessionID, id string, sequence uint64, kind string) {
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	params, _ := json.Marshal(map[string]any{
		"subscriptionID": id, "sequence": sequence, "event": map[string]string{"type": kind},
	})
	// Core records the terminal outcome of lsp.hostNotify at the request boundary.
	_, _ = s.kernel.SendPluginHostNotification(ctx, sessionID, notifySubscription, params)
}

type buildWatchTarget struct {
	info  os.FileInfo
	names map[string]struct{}
}

type buildConfigurationWatches struct {
	targets     map[string]buildWatchTarget
	directories map[string]*app.DirectoryWatch
}

func buildWatchName(name string) string {
	if runtime.GOOS == "windows" {
		return strings.ToLower(name)
	}
	return name
}

// A file is watched from its parent so saves by rename stay visible. For a
// missing parent, the nearest directory follows the next component's creation.
// Existing symbolic links also need a watch of the target's parent.
func buildWatchTargets(paths []string) (map[string]buildWatchTarget, error) {
	targets := make(map[string]buildWatchTarget)
	for _, path := range paths {
		resolved, err := filepath.EvalSymlinks(path)
		if errors.Is(err, os.ErrNotExist) {
			// Follow a dangling leaf link so creation of its target is visible.
			if link, linkErr := os.Readlink(path); linkErr == nil {
				resolved = link
				if !filepath.IsAbs(link) {
					resolved = filepath.Join(filepath.Dir(path), link)
				}
			}
		}
		for _, target := range []string{path, resolved} {
			if target == "" {
				continue
			}
			child, dir := target, filepath.Dir(target)
			for {
				info, statErr := os.Stat(dir)
				if statErr == nil && info.IsDir() {
					entry, exists := targets[dir]
					if !exists {
						entry = buildWatchTarget{info, make(map[string]struct{})}
						targets[dir] = entry
					}
					entry.names[buildWatchName(filepath.Base(child))] = struct{}{}
					break
				}
				parent := filepath.Dir(dir)
				if parent == dir || (statErr != nil && !errors.Is(statErr, os.ErrNotExist)) {
					return nil, errors.New("configuration parent cannot be watched")
				}
				child, dir = dir, parent
			}
		}
	}
	return targets, nil
}

func sameBuildTargets(first, second map[string]buildWatchTarget) bool {
	return maps.EqualFunc(first, second, func(a, b buildWatchTarget) bool {
		return os.SameFile(a.info, b.info) && maps.Equal(a.names, b.names)
	})
}

func watchBuildConfiguration(paths []string, wake func()) (buildConfigurationWatches, error) {
	for range 3 {
		targets, err := buildWatchTargets(paths)
		if err != nil {
			return buildConfigurationWatches{}, err
		}
		watches := buildConfigurationWatches{targets, make(map[string]*app.DirectoryWatch)}
		for dir := range targets {
			watch, err := app.WatchDirectory(dir, wake)
			if err != nil {
				closeBuildWatches(watches)
				return buildConfigurationWatches{}, err
			}
			watches.directories[dir] = watch
		}
		current, err := buildWatchTargets(paths)
		if err == nil && sameBuildTargets(targets, current) {
			return watches, nil
		}
		closeBuildWatches(watches)
		if err != nil {
			return buildConfigurationWatches{}, err
		}
	}
	return buildConfigurationWatches{}, errors.New("configuration locations changed during watch registration")
}

func drainBuildWatches(watches buildConfigurationWatches) (changed, resync bool) {
	for dir, watch := range watches.directories {
		changes := watch.Changes(nil)
		changed = changed || changes.Resync
		resync = resync || changes.Resync
		for _, name := range changes.Names {
			if _, ok := watches.targets[dir].names[buildWatchName(name)]; ok {
				changed = true
			}
		}
	}
	return
}

func closeBuildWatches(watches buildConfigurationWatches) {
	for _, watch := range watches.directories {
		watch.Close()
	}
}
