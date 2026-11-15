package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// outputLinkResolveTimeout bounds a matcher's resolve function. The user is
// waiting on a click, so a backend that does not answer is given up on.
const outputLinkResolveTimeout = 10 * time.Second

// OutputLinkSources reads the output link matchers of every enabled plugin.
//
// The declarations come from the installed manifests, which Core validated at
// install; Core checks each pattern again when it matches, so a source here is
// only data to hand back. A plugin that declares no matcher is left out, and a
// broken manifest is reported without hiding the others.
func (s *Service) OutputLinkSources(ctx context.Context, entries []pluginmanager.Entry) ([]core.OutputLinkSource, error) {
	var sources []core.OutputLinkSource
	var failures []error
	selected, selectionErr := s.selectInstalled(ctx, entries, false)
	if selectionErr != nil {
		failures = append(failures, selectionErr)
	}
	for _, entry := range selected {
		manifest, err := readBounded(filepath.Join(entry.Installed.Path, pluginpkg.ManifestFile), MaxManifestBytes)
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		var declared struct {
			Matchers []core.OutputLinkMatcher `json:"outputLinkMatchers"`
		}
		if err := json.Unmarshal(manifest, &declared); err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", entry.Installed.ID, err))
			continue
		}
		if len(declared.Matchers) > 0 {
			sources = append(sources, core.OutputLinkSource{PluginID: entry.Installed.ID, Matchers: declared.Matchers})
		}
	}
	return sources, errors.Join(failures...)
}

// ResolveOutputLink asks the plugin's backend function a matcher names to turn
// the captured groups into a location, and lets Core check the answer. A nil
// location means the backend found nothing to open.
func (s *Service) ResolveOutputLink(ctx context.Context, pluginID, function string, groups json.RawMessage, workspacePath string) (*core.OutputLocation, error) {
	workspace, ok := s.Contexts.ByPath(workspacePath)
	if !ok {
		return nil, ErrContextExpired
	}
	reference, err := json.Marshal(workspace.ContextRef)
	if err != nil {
		return nil, err
	}
	params, err := json.Marshal(map[string]json.RawMessage{"groups": groups})
	if err != nil {
		return nil, err
	}
	answer, err := s.Host.Call(ctx, pluginID, function, params, reference, outputLinkResolveTimeout)
	if err != nil {
		return nil, err
	}
	return s.kernel.DecodeOutputLinkResolution(ctx, answer)
}
