package toolchain

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// ProviderScope binds a query to the host's open project context. A nil scope
// is only usable for discovery in global mode.
type ProviderScope struct {
	Context  core.ToolchainQueryContext
	RootID   func(pluginID string) string
	Validate func() error
}

// ProviderClient owns a window's provider reply cache. It stores raw replies,
// never authority to execute a tool. Every use captures fresh evidence and
// validates the reply again in Core.
type ProviderClient struct {
	Request func(context.Context, string, core.ToolchainQueryParams) (core.ToolchainProviderReply, error)
	Decode  func(context.Context, core.ToolchainQuery) (core.ToolchainProviderSnapshot, error)
	Failed  func(context.Context, error)

	mu       sync.Mutex
	revision uint64
	cache    map[providerCacheKey]*providerRound
}

const (
	providerCacheEntries = 8
	providerCacheBytes   = 1 << 20
	providerReplyBytes   = 1 << 20
	providerRoundBytes   = 2 << 20
	providerFactsLimit   = 16384
	providerRoundTimeout = 15 * time.Second
)

type providerCacheKey struct {
	registry  [sha256.Size]byte
	platform  string
	root      string
	roots     [sha256.Size]byte
	context   core.ToolchainQueryContext
	directory string
	tool      string
}

type providerAnswer struct {
	pluginID string
	request  json.RawMessage
	response json.RawMessage
}

type providerRound struct {
	generation uint64
	revision   uint64
	started    time.Time
	context    json.RawMessage
	answers    []providerAnswer
	observed   *providerObservation
}

var errProviderGenerationChanged = errors.New("toolchain: provider generation changed during discovery")

// Invalidate clears every provider round when the workspace or plugin roster
// changes. Detached observers are released by the returned cleanup function.
func (p *ProviderClient) Invalidate() func() {
	if p == nil {
		return func() {}
	}
	p.mu.Lock()
	p.revision++
	retired := p.cache
	p.cache = nil
	p.mu.Unlock()
	return func() {
		for _, round := range retired {
			round.observed.close()
		}
	}
}

func (p *ProviderClient) round(
	ctx context.Context, w *workspace, registry json.RawMessage,
	planned core.ToolchainDiscoveryPlanTool, directory string, scope *ProviderScope,
) (*providerRound, providerCacheKey, error) {
	key := providerCacheKey{
		registry: sha256.Sum256(registry), platform: w.platform, root: w.root,
		roots: sha256.Sum256([]byte(strings.Join(w.workspaceRoots, "\x00"))), directory: directory, tool: planned.Tool,
	}
	contextJSON := json.RawMessage("null")
	if w.root != "" {
		if scope == nil {
			return nil, key, nil
		}
		if err := scope.Validate(); err != nil {
			return nil, key, err
		}
		key.context = scope.Context
		data, err := json.Marshal(scope.Context)
		if err != nil {
			return nil, key, err
		}
		contextJSON = data
	}
	p.mu.Lock()
	cached := p.cache[key]
	revision := p.revision
	p.mu.Unlock()
	if cached != nil && time.Since(cached.started) < time.Minute && cached.observed.current() {
		return cached, key, nil
	}

	round := &providerRound{
		generation: loadSequence.Add(1), revision: revision, started: time.Now(), context: contextJSON,
	}
	queryCtx, cancel := context.WithTimeout(ctx, providerRoundTimeout)
	defer cancel()
	roundBytes := 0
	for index, qualified := range planned.Providers {
		pluginID, providerID, ok := strings.Cut(qualified, ":")
		if !ok || pluginID == "" || providerID == "" {
			return nil, key, errors.New("toolchain: Core returned an invalid provider identity")
		}
		params := core.ToolchainQueryParams{
			OperationID: fmt.Sprintf("toolchain-query-%d-%d", round.generation, index),
			Generation:  round.generation, ProviderID: providerID, Authority: map[string]string{"kind": "local"},
			Tools: []string{planned.Tool},
		}
		if w.root != "" {
			params.Context = &scope.Context
			params.Workspace = &core.ToolchainQueryWorkspace{RootID: scope.RootID(pluginID), Root: w.root, Directory: directory}
		}
		reply, err := p.Request(queryCtx, pluginID, params)
		if err != nil {
			return nil, key, err
		}
		roundBytes += len(reply.Response)
		if len(reply.Response) > providerReplyBytes || roundBytes > providerRoundBytes {
			return nil, key, errors.New("toolchain: provider reply exceeds the native observation budget")
		}
		request, err := json.Marshal(struct {
			JSONRPC string                    `json:"jsonrpc"`
			ID      json.RawMessage           `json:"id"`
			Method  string                    `json:"method"`
			Params  core.ToolchainQueryParams `json:"params"`
		}{"2.0", reply.ID, "toolchains/query", params})
		if err != nil {
			return nil, key, err
		}
		round.answers = append(round.answers, providerAnswer{pluginID, request, reply.Response})
	}
	return round, key, nil
}

// Observe only the inert paths required by the contract. Core still verifies
// each path and type, each installation and statement, and the reply envelope.
func (a providerAnswer) observe(w *workspace, definition core.ToolchainToolDefinition) ([]string, error) {
	var envelope struct {
		Result struct {
			Installations []struct {
				Tool string `json:"tool"`
				Home string `json:"home"`
			} `json:"installations"`
			Statements []struct {
				Tool   string `json:"tool"`
				Source string `json:"source"`
			} `json:"statements"`
			Watch []string `json:"watch"`
		} `json:"result"`
	}
	if err := json.Unmarshal(a.response, &envelope); err != nil {
		return nil, err
	}
	result := envelope.Result
	if len(result.Installations) > 512 || len(result.Statements) > 256 || len(result.Watch) > 256 {
		return nil, errors.New("toolchain: provider reply exceeds native path observation limits")
	}
	paths := make([]string, 0, len(result.Watch)+len(result.Statements))
	for _, value := range result.Installations {
		if value.Tool == definition.ID && providerAbsolutePath(value.Home) {
			w.observeToolHome(value.Home, definition)
			if len(w.facts) > providerFactsLimit {
				return nil, errors.New("toolchain: provider reply exceeds native filesystem fact limits")
			}
		}
	}
	for _, value := range result.Statements {
		if value.Tool == definition.ID && providerAbsolutePath(value.Source) {
			w.observe(value.Source)
			paths = append(paths, value.Source)
		}
	}
	for _, name := range result.Watch {
		if providerAbsolutePath(name) {
			w.observe(name)
			paths = append(paths, name)
		}
	}
	if len(w.facts) > providerFactsLimit {
		return nil, errors.New("toolchain: provider reply exceeds native filesystem fact limits")
	}
	return paths, nil
}

func providerAbsolutePath(path string) bool {
	return len(path) <= 4096 && !strings.ContainsRune(path, 0) &&
		filepath.IsAbs(path) && filepath.Clean(path) == filepath.FromSlash(path)
}

func (w *workspace) observeToolHome(home string, definition core.ToolchainToolDefinition) {
	w.observe(home)
	for _, layout := range definition.ExecutableLayouts {
		if platformMatches(layout.Platforms, w.platform) {
			w.observe(filepath.Join(home, filepath.FromSlash(layout.Path)))
		}
	}
	for _, template := range definition.PathPrepend {
		if name, ok := prependPath(home, template); ok {
			w.observe(name)
		}
	}
}

func (p *ProviderClient) capture(
	ctx context.Context, w *workspace, registry json.RawMessage, directory string,
	planned core.ToolchainDiscoveryPlanTool, definition core.ToolchainToolDefinition, scope *ProviderScope,
) (*providerRound, []core.ToolchainQuery, []core.ToolchainProviderInstallation, error) {
	round, key, err := p.round(ctx, w, registry, planned, directory, scope)
	if err != nil || round == nil {
		return nil, nil, nil, err
	}
	if w.root != "" && directory != "." {
		w.observe(filepath.Join(w.root, filepath.FromSlash(directory)))
	}
	var paths []string
	for _, answer := range round.answers {
		observed, err := answer.observe(w, definition)
		if err != nil {
			return nil, nil, nil, err
		}
		paths = append(paths, observed...)
	}
	facts := w.all()
	var queries []core.ToolchainQuery
	var installations []core.ToolchainProviderInstallation
	cacheable := true
	for _, answer := range round.answers {
		query := core.ToolchainQuery{
			Registry: registry, PluginID: answer.pluginID,
			Request: answer.request, Response: answer.response,
			CurrentGeneration: round.generation, Filesystem: facts,
			Platform: w.platform, WorkspaceRoots: w.workspaceRoots,
		}
		snapshot, err := p.Decode(ctx, query)
		if err != nil {
			var rejection *core.MarketplaceRejection
			if !errors.As(err, &rejection) || (rejection.Code != core.ToolchainProviderUnavailable && rejection.Code != core.ToolchainProviderTimeout) {
				return nil, nil, nil, err
			}
			if p.Failed != nil {
				p.Failed(ctx, err)
			}
			cacheable = false
		}
		paths = append(paths, snapshot.Watch...)
		installations = append(installations, snapshot.Installations...)
		queries = append(queries, query)
	}
	if err := p.check(ctx, round, scope); err != nil {
		return nil, nil, nil, err
	}
	if cacheable && round.observed == nil {
		if err := p.remember(ctx, key, round, paths); err != nil {
			return nil, nil, nil, err
		}
	}
	return round, queries, installations, nil
}

func (p *ProviderClient) check(ctx context.Context, round *providerRound, scope *ProviderScope) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if scope != nil {
		if err := scope.Validate(); err != nil {
			return err
		}
	}
	if round == nil {
		return nil
	}
	p.mu.Lock()
	current := p.revision == round.revision
	p.mu.Unlock()
	if !current || (round.observed != nil && !round.observed.current()) {
		return errProviderGenerationChanged
	}
	return nil
}

func (p *ProviderClient) remember(ctx context.Context, key providerCacheKey, round *providerRound, paths []string) error {
	bytes := 0
	for _, answer := range round.answers {
		bytes += len(answer.request) + len(answer.response)
	}
	if bytes > providerCacheBytes {
		return nil
	}
	observed, err := observeProviderInputs(paths, round.started)
	if errors.Is(err, errProviderGenerationChanged) {
		return err
	}
	if err != nil {
		if p.Failed != nil {
			p.Failed(ctx, err)
		}
		return nil
	}
	if observed == nil {
		return nil
	}
	round.observed = observed
	p.mu.Lock()
	if p.revision != round.revision {
		p.mu.Unlock()
		observed.close()
		return nil
	}
	if p.cache == nil {
		p.cache = make(map[providerCacheKey]*providerRound)
	}
	retired := p.cache[key]
	if retired != nil && retired.generation > round.generation {
		p.mu.Unlock()
		observed.close()
		return nil
	}
	if retired == nil && len(p.cache) >= providerCacheEntries {
		var oldest providerCacheKey
		for key, cached := range p.cache {
			if retired == nil || cached.generation < retired.generation {
				oldest, retired = key, cached
			}
		}
		delete(p.cache, oldest)
	}
	p.cache[key] = round
	p.mu.Unlock()
	if retired != nil {
		retired.observed.close()
	}
	return nil
}
