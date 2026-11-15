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
// supply. The host routes only the feature types it presents (routedProviderTypes, which Core is told
// at session start and on every registration); Core refuses a registration of any other type, so
// nothing is registered that the host would never call. Each routed type fills one function in the
// binding (providerFunctionFields), and its answer is shown through the same presentation as a
// language server's, only when no language server serves the document, since the server comes first.
const (
	methodRegisterEditorProviders = pluginhost.MethodPrefix + "editor/registerProviders"

	// editorProviderTimeout bounds one provider call.
	editorProviderTimeout = 15 * time.Second
	// maxEditorProviderBindings is the most registrations one plugin keeps across contexts.
	maxEditorProviderBindings = 32
)

// routedProviderTypes are the provider types this host routes, in the order Core is told them.
var routedProviderTypes = core.EditorHost.ProviderTypes

// providerFunctionFields is the binding field each routed provider type fills. Its keys are exactly
// routedProviderTypes: a type routed without a field would be accepted and never called, and a field
// without a routed type would be refused by Core.
var providerFunctionFields = map[string]func(*editorProviderBinding) *string{
	"definition":     func(b *editorProviderBinding) *string { return &b.definition },
	"hover":          func(b *editorProviderBinding) *string { return &b.hover },
	"completion":     func(b *editorProviderBinding) *string { return &b.completion },
	"codeLens":       func(b *editorProviderBinding) *string { return &b.codeLens },
	"semanticTokens": func(b *editorProviderBinding) *string { return &b.semanticTokens },
	"documentLink":   func(b *editorProviderBinding) *string { return &b.documentLink },
}

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
	// definition, hover and completion are the functions that answer those requests; empty when not declared.
	definition string
	hover      string
	completion string
	// semanticTokens is the function that answers token requests, and tokenTypes/tokenModifiers its legend.
	semanticTokens string
	tokenTypes     []string
	tokenModifiers []string
	// triggers are the characters that ask for completion as they are typed.
	triggers []string
	// codeLens is the function that answers code lens requests.
	codeLens string
	// documentLink is the function that answers document link requests.
	documentLink string
	languages    map[string]bool
	extensions   map[string]bool
	names        map[string]bool
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
			Function          string   `json:"function"`
			TriggerCharacters []string `json:"triggerCharacters"`
			Legend            struct {
				TokenTypes     []string `json:"tokenTypes"`
				TokenModifiers []string `json:"tokenModifiers"`
			} `json:"legend"`
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
		value, err := editorRegistrationValue(params)
		if err != nil {
			return nil, invalidParams(err)
		}
		if _, err := decoder.DecodeEditorProviders(ctx, map[string]any{"kind": "registration", "value": value, "types": routedProviderTypes}); err != nil {
			return nil, failure(codeInvalidParams, err.Error())
		}
	}
	binding := &editorProviderBinding{
		pluginID: caller.PluginID, sessionID: caller.SessionID, contextID: workspace.ContextID,
		reference: mustMarshal(workspace.ContextRef), id: request.ID,
		languages: map[string]bool{}, extensions: map[string]bool{}, names: map[string]bool{},
	}
	for kind, provider := range request.Providers {
		field, routed := providerFunctionFields[kind]
		if !routed {
			return nil, failure(codeInvalidParams, "The host does not route the "+kind+" provider type.")
		}
		if !validFunctionID(provider.Function) {
			return nil, failure(codeInvalidParams, "The "+kind+" provider needs a function ID.")
		}
		if kind == "semanticTokens" && (len(provider.Legend.TokenTypes) == 0 || len(provider.Legend.TokenTypes) > 64 || len(provider.Legend.TokenModifiers) > 64) {
			return nil, failure(codeInvalidParams, "The semantic tokens provider needs a legend within the limits.")
		}
		session := s.Host.Running(caller.PluginID)
		if session == nil || session.Session.ID != caller.SessionID || !session.hasFunction(provider.Function) {
			return nil, failure(CodePreconditionFailed, "The function is not registered on this session.")
		}
		*field(binding) = provider.Function
		switch kind {
		case "semanticTokens":
			binding.tokenTypes = provider.Legend.TokenTypes
			binding.tokenModifiers = provider.Legend.TokenModifiers
		case "completion":
			binding.triggers = provider.TriggerCharacters
		}
	}
	if len(request.Providers) == 0 {
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

// hoverBinding is the binding of the document whose hover provider answers, or nil.
func (s *Service) hoverBinding(root, path, languageID string) *editorProviderBinding {
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
		if binding.contextID == workspace.ContextID && binding.hover != "" && binding.matchesDocument(languageID, name) {
			return binding
		}
	}
	return nil
}

// HasHoverProvider reports whether a plugin's hover provider serves the document.
func (s *Service) HasHoverProvider(root, path, languageID string) bool {
	return s.hoverBinding(root, path, languageID) != nil
}

// PluginHover asks the document's hover provider for the text at a zero-based UTF-16 position. The
// answer is normalised by Core into contents; an empty string means nothing to show.
func (s *Service) PluginHover(ctx context.Context, root, path, languageID, documentID string, version, line, column int) (string, error) {
	binding := s.hoverBinding(root, path, languageID)
	if binding == nil {
		return "", nil
	}
	session := s.Host.Running(binding.pluginID)
	if session == nil || session.Session.ID != binding.sessionID {
		return "", ErrBackendUnavailable
	}
	argument := mustMarshal(map[string]any{
		"document": map[string]any{"documentID": documentID, "version": version},
		"position": map[string]int{"line": line, "character": column},
	})
	answer, err := session.Call(ctx, binding.hover, argument, binding.reference, editorProviderTimeout)
	if err != nil {
		return "", err
	}
	decoder, ok := s.kernel.(editorProviderDecoder)
	if !ok {
		return "", errors.New("editor providers need the Core that normalises their answers")
	}
	decoded, err := decoder.DecodeEditorProviders(ctx, map[string]any{"kind": "result", "type": "hover", "value": answer})
	if err != nil {
		return "", err
	}
	var result struct {
		Result struct {
			Contents json.RawMessage `json:"contents"`
		} `json:"result"`
	}
	if err := json.Unmarshal(decoded, &result); err != nil {
		return "", err
	}
	var text string
	if len(result.Result.Contents) > 0 && json.Unmarshal(result.Result.Contents, &text) != nil {
		var object struct {
			Value string `json:"value"`
		}
		if json.Unmarshal(result.Result.Contents, &object) == nil {
			text = object.Value
		}
	}
	return text, nil
}

// completionBinding is the binding of the document whose completion provider answers, or nil.
func (s *Service) completionBinding(root, path, languageID string) *editorProviderBinding {
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
		if binding.contextID == workspace.ContextID && binding.completion != "" && binding.matchesDocument(languageID, name) {
			return binding
		}
	}
	return nil
}

// HasCompletionProvider reports whether a plugin's completion provider serves the document.
func (s *Service) HasCompletionProvider(root, path, languageID string) bool {
	return s.completionBinding(root, path, languageID) != nil
}

// PluginCompletions asks the completion provider for the items at a zero-based UTF-16 position. The
// answer is normalised by Core into the same items a language server's completion answer gives.
func (s *Service) PluginCompletions(ctx context.Context, root, path, languageID, documentID string, version, line, column int) ([]core.PluginSemanticCompletionItem, error) {
	binding := s.completionBinding(root, path, languageID)
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
	answer, err := session.Call(ctx, binding.completion, argument, binding.reference, editorProviderTimeout)
	if err != nil {
		return nil, err
	}
	decoder, ok := s.kernel.(editorProviderDecoder)
	if !ok {
		return nil, errors.New("editor providers need the Core that normalises their answers")
	}
	decoded, err := decoder.DecodeEditorProviders(ctx, map[string]any{"kind": "result", "type": "completion", "value": answer})
	if err != nil {
		return nil, err
	}
	var result struct {
		Result struct {
			Items []core.PluginSemanticCompletionItem `json:"items"`
		} `json:"result"`
	}
	if err := json.Unmarshal(decoded, &result); err != nil {
		return nil, err
	}
	return result.Result.Items, nil
}

// MergeDefinitions has Core keep the server's and the plugins' definition locations that belong to the
// answer, with the server's first and duplicates and the covering location dropped. Both lists are
// LSP-shaped locations, one-based only in the editor, never here.
func (s *Service) MergeDefinitions(ctx context.Context, documentURI string, line, column int, server, plugin []core.PluginSemanticLocation) ([]core.PluginSemanticLocation, error) {
	if len(plugin) == 0 {
		return server, nil
	}
	decoder, ok := s.kernel.(editorProviderDecoder)
	if !ok {
		return append(append([]core.PluginSemanticLocation(nil), server...), plugin...), nil
	}
	decoded, err := decoder.DecodeEditorProviders(ctx, map[string]any{
		"kind": "mergeDefinitions",
		"value": map[string]any{
			"documentUri": documentURI,
			"position":    map[string]int{"line": line, "character": column},
			"server":      lspLocations(server),
			"plugin":      lspLocations(plugin),
		},
	})
	if err != nil {
		return nil, err
	}
	var kept struct {
		Server []int `json:"server"`
		Plugin []int `json:"plugin"`
	}
	if err := json.Unmarshal(decoded, &kept); err != nil {
		return nil, err
	}
	merged := make([]core.PluginSemanticLocation, 0, len(kept.Server)+len(kept.Plugin))
	for _, index := range kept.Server {
		if index >= 0 && index < len(server) {
			merged = append(merged, server[index])
		}
	}
	for _, index := range kept.Plugin {
		if index >= 0 && index < len(plugin) {
			merged = append(merged, plugin[index])
		}
	}
	return merged, nil
}

// lspLocations converts located ranges to LSP Location objects for Core's merge.
func lspLocations(locations []core.PluginSemanticLocation) []map[string]any {
	out := make([]map[string]any, 0, len(locations))
	for _, location := range locations {
		out = append(out, map[string]any{
			"uri": location.URI,
			"range": map[string]any{
				"start": map[string]int{"line": location.Range.Start.Line, "character": location.Range.Start.UTF16Column},
				"end":   map[string]int{"line": location.Range.End.Line, "character": location.Range.End.UTF16Column},
			},
		})
	}
	return out
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

// semanticTokensBinding is the binding of the document whose semantic tokens provider answers, or nil.
func (s *Service) semanticTokensBinding(root, path, languageID string) *editorProviderBinding {
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
		if binding.contextID == workspace.ContextID && binding.semanticTokens != "" && binding.matchesDocument(languageID, name) {
			return binding
		}
	}
	return nil
}

// HasSemanticTokensProvider reports whether a plugin's semantic tokens provider serves the document.
func (s *Service) HasSemanticTokensProvider(root, path, languageID string) bool {
	return s.semanticTokensBinding(root, path, languageID) != nil
}

// SemanticTokens is the decoded answer of a semantic tokens provider: the token types and modifiers of its
// registered legend, and the tokens with their positions made absolute.
type SemanticTokens struct {
	Types     []string
	Modifiers []string
	// Tokens are zero-based: line, UTF-16 start column, length, type index, modifier bit set.
	Tokens []SemanticTokenSpan
}

// SemanticTokenSpan is one token of a provider's answer.
type SemanticTokenSpan struct {
	Line, StartChar, Length, Type int
	Modifiers                     uint32
}

// PluginSemanticTokens asks the provider for the document's tokens, has Core normalise the answer to the
// LSP relative encoding, and expands it into absolute positions.
func (s *Service) PluginSemanticTokens(ctx context.Context, root, path, languageID, documentID string, version int) (SemanticTokens, error) {
	binding := s.semanticTokensBinding(root, path, languageID)
	if binding == nil {
		return SemanticTokens{}, nil
	}
	session := s.Host.Running(binding.pluginID)
	if session == nil || session.Session.ID != binding.sessionID {
		return SemanticTokens{}, ErrBackendUnavailable
	}
	argument := mustMarshal(map[string]any{"document": map[string]any{"documentID": documentID, "version": version}})
	answer, err := session.Call(ctx, binding.semanticTokens, argument, binding.reference, editorProviderTimeout)
	if err != nil {
		return SemanticTokens{}, err
	}
	decoder, ok := s.kernel.(editorProviderDecoder)
	if !ok {
		return SemanticTokens{}, errors.New("editor providers need the Core that normalises their answers")
	}
	legend := map[string]any{"tokenTypes": binding.tokenTypes, "tokenModifiers": binding.tokenModifiers}
	decoded, err := decoder.DecodeEditorProviders(ctx, map[string]any{"kind": "result", "type": "semanticTokens", "value": answer, "legend": legend})
	if err != nil {
		return SemanticTokens{}, err
	}
	var result struct {
		Result struct {
			Data []int `json:"data"`
		} `json:"result"`
	}
	if err := json.Unmarshal(decoded, &result); err != nil {
		return SemanticTokens{}, err
	}
	return SemanticTokens{Types: binding.tokenTypes, Modifiers: binding.tokenModifiers, Tokens: expandRelativeTokens(result.Result.Data)}, nil
}

// expandRelativeTokens reads the LSP relative encoding: five integers per token, a line delta, a start delta
// (relative to the previous token only on the same line), a length, a type and a modifier bit set.
func expandRelativeTokens(data []int) []SemanticTokenSpan {
	var tokens []SemanticTokenSpan
	line, start := 0, 0
	for index := 0; index+5 <= len(data); index += 5 {
		deltaLine, deltaStart := data[index], data[index+1]
		if deltaLine < 0 || deltaStart < 0 || data[index+2] <= 0 || data[index+3] < 0 || data[index+4] < 0 {
			continue
		}
		line += deltaLine
		if deltaLine == 0 {
			start += deltaStart
		} else {
			start = deltaStart
		}
		tokens = append(tokens, SemanticTokenSpan{Line: line, StartChar: start, Length: data[index+2], Type: data[index+3], Modifiers: uint32(data[index+4])})
	}
	return tokens
}

// CompletionTriggers returns the characters a plugin's completion provider asks for completion on, or nil.
func (s *Service) CompletionTriggers(root, path, languageID string) []string {
	binding := s.completionBinding(root, path, languageID)
	if binding == nil {
		return nil
	}
	return binding.triggers
}
