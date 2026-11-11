package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// Editor language-feature providers: a plugin adds a feature the file's language server does not
// supply. The host routes only the feature types it presents; Core refuses a registration of any
// other type, so nothing is registered that the host would never call. Today the routed type is
// definition, shown through the same presentation as a language server's answer, and only when no
// language server serves the document, since the server's answer comes first.
const (
	methodRegisterEditorProviders = pluginhost.MethodPrefix + "editor/registerProviders"

	// editorProviderTimeout bounds one provider call.
	editorProviderTimeout = 15 * time.Second
	// maxEditorProviderBindings is the most registrations one plugin keeps across contexts.
	maxEditorProviderBindings = 32
)

// routedProviderTypes are the provider types this host routes, in the order Core is told them.
var routedProviderTypes = core.EditorHost.ProviderTypes

// editorProviderDecoder is the part of Core that validates provider messages.
type editorProviderDecoder interface {
	DecodeEditorProviders(ctx context.Context, payload any) (json.RawMessage, error)
}

type editorProviderBinding struct {
	pluginID  string
	sessionID string
	contextID string
	reference json.RawMessage
	id        string
	// definition is the function that answers definition requests; empty when not declared.
	definition string
	languages  map[string]bool
	extensions map[string]bool
	names      map[string]bool
}

type editorProviderBindings struct {
	mu   sync.Mutex
	list []*editorProviderBinding
}

// registerEditorProviders attaches the provider registration method to a window.
func (s *Service) registerEditorProviders() error {
	s.providers2 = &editorProviderBindings{}
	return s.HostServices.Register(methodRegisterEditorProviders, s.handleRegisterEditorProviders)
}

func (s *Service) handleRegisterEditorProviders(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context  ContextRef `json:"context"`
		ID       string     `json:"id"`
		Selector struct {
			Languages      []string `json:"languages"`
			FileExtensions []string `json:"fileExtensions"`
			FileNames      []string `json:"fileNames"`
		} `json:"selector"`
		Providers map[string]struct {
			Function string `json:"function"`
		} `json:"providers"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if request.ID == "" || len(request.ID) > 128 {
		return nil, failure(codeInvalidParams, "The registration needs an ID.")
	}
	if n := len(request.Selector.Languages) + len(request.Selector.FileExtensions) + len(request.Selector.FileNames); n < 1 || n > 32 {
		return nil, failure(codeInvalidParams, "The selector needs one to 32 entries.")
	}
	if decoder, ok := s.kernel.(editorProviderDecoder); ok {
		if _, err := decoder.DecodeEditorProviders(ctx, map[string]any{"kind": "registration", "value": json.RawMessage(params), "types": routedProviderTypes}); err != nil {
			return nil, failure(codeInvalidParams, err.Error())
		}
	}
	binding := &editorProviderBinding{
		pluginID: caller.PluginID, sessionID: caller.SessionID, contextID: workspace.ContextID,
		reference: mustMarshal(workspace.ContextRef), id: request.ID,
		languages: map[string]bool{}, extensions: map[string]bool{}, names: map[string]bool{},
	}
	if definition, ok := request.Providers["definition"]; ok {
		if !validFunctionID(definition.Function) {
			return nil, failure(codeInvalidParams, "The definition provider needs a function ID.")
		}
		session := s.Host.Running(caller.PluginID)
		if session == nil || session.Session.ID != caller.SessionID || !session.hasFunction(definition.Function) {
			return nil, failure(CodePreconditionFailed, "The function is not registered on this session.")
		}
		binding.definition = definition.Function
	}
	if binding.definition == "" {
		return nil, failure(codeInvalidParams, "The registration provides no routed provider type.")
	}
	for _, language := range request.Selector.Languages {
		binding.languages[strings.ToLower(language)] = true
	}
	for _, extension := range request.Selector.FileExtensions {
		binding.extensions[strings.ToLower(strings.TrimPrefix(extension, "."))] = true
	}
	for _, name := range request.Selector.FileNames {
		binding.names[strings.ToLower(name)] = true
	}
	s.providers2.mu.Lock()
	count := 0
	for _, existing := range s.providers2.list {
		if existing.pluginID == caller.PluginID {
			count++
		}
		if existing.pluginID == binding.pluginID && existing.contextID == binding.contextID && existing.id == binding.id {
			s.providers2.mu.Unlock()
			return nil, failure(CodePreconditionFailed, "The registration ID is already registered in this context.")
		}
	}
	if count >= maxEditorProviderBindings {
		s.providers2.mu.Unlock()
		return nil, failure(CodePreconditionFailed, "The plugin has too many editor provider registrations.")
	}
	s.providers2.list = append(s.providers2.list, binding)
	s.providers2.mu.Unlock()
	id := s.resources.add(caller, workspace.ContextID, func() {
		s.providers2.mu.Lock()
		defer s.providers2.mu.Unlock()
		s.providers2.list = removeProviderBinding(s.providers2.list, binding)
	})
	return marshalResult(map[string]string{"subscriptionID": id})
}

func removeProviderBinding(list []*editorProviderBinding, target *editorProviderBinding) []*editorProviderBinding {
	kept := list[:0]
	for _, binding := range list {
		if binding != target {
			kept = append(kept, binding)
		}
	}
	return kept
}

// matchesDocument reports whether a document is in a provider's selector.
func (b *editorProviderBinding) matchesDocument(languageID, name string) bool {
	if languageID != "" && b.languages[strings.ToLower(languageID)] {
		return true
	}
	lower := strings.ToLower(name)
	if b.names[lower] {
		return true
	}
	extension := strings.TrimPrefix(filepath.Ext(lower), ".")
	return extension != "" && b.extensions[extension]
}

// HasDefinitionProvider reports whether a plugin's definition provider serves the document.
func (s *Service) HasDefinitionProvider(root, path, languageID string) bool {
	return s.definitionBinding(root, path, languageID) != nil
}

func (s *Service) definitionBinding(root, path, languageID string) *editorProviderBinding {
	if s == nil || s.providers2 == nil {
		return nil
	}
	workspace, ok := s.Contexts.ByPath(root)
	if !ok {
		return nil
	}
	name := filepath.Base(path)
	s.providers2.mu.Lock()
	defer s.providers2.mu.Unlock()
	for _, binding := range s.providers2.list {
		if binding.contextID == workspace.ContextID && binding.definition != "" && binding.matchesDocument(languageID, name) {
			return binding
		}
	}
	return nil
}

// PluginDefinitions asks the document's definition provider for the locations of the symbol at a
// zero-based UTF-16 position. The answer is normalised by Core; a locations answer that is not a file
// is kept only when it is a URI the host can open.
func (s *Service) PluginDefinitions(ctx context.Context, root, path, languageID, documentID string, version, line, column int) ([]core.PluginSemanticLocation, error) {
	binding := s.definitionBinding(root, path, languageID)
	if binding == nil {
		return nil, nil
	}
	session := s.Host.Running(binding.pluginID)
	if session == nil || session.Session.ID != binding.sessionID {
		return nil, ErrBackendUnavailable
	}
	argument := mustMarshal(map[string]any{
		"document": map[string]any{"documentID": documentID, "version": version},
		"position": map[string]int{"line": line, "character": column},
	})
	answer, err := session.Call(ctx, binding.definition, argument, binding.reference, editorProviderTimeout)
	if err != nil {
		return nil, err
	}
	decoder, ok := s.kernel.(editorProviderDecoder)
	if !ok {
		return nil, errors.New("editor providers need the Core that normalises their answers")
	}
	decoded, err := decoder.DecodeEditorProviders(ctx, map[string]any{"kind": "result", "type": "definition", "value": answer})
	if err != nil {
		return nil, err
	}
	var result struct {
		Result struct {
			Locations []struct {
				URI   string `json:"uri"`
				Range struct {
					Start struct{ Line, Character int } `json:"start"`
					End   struct{ Line, Character int } `json:"end"`
				} `json:"range"`
			} `json:"locations"`
		} `json:"result"`
	}
	if err := json.Unmarshal(decoded, &result); err != nil {
		return nil, err
	}
	locations := make([]core.PluginSemanticLocation, 0, len(result.Result.Locations))
	for _, location := range result.Result.Locations {
		parsed, err := url.Parse(location.URI)
		if err != nil {
			continue
		}
		item := core.PluginSemanticLocation{
			URI: location.URI,
			Range: core.PluginDocumentRange{
				Start: core.PluginDocumentPosition{Line: location.Range.Start.Line, UTF16Column: location.Range.Start.Character},
				End:   core.PluginDocumentPosition{Line: location.Range.End.Line, UTF16Column: location.Range.End.Character},
			},
		}
		if parsed.Scheme == "file" && filepath.IsAbs(parsed.Path) {
			item.FilePath = parsed.Path
		}
		locations = append(locations, item)
	}
	return locations, nil
}
