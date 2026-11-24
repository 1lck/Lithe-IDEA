package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"path/filepath"
	"slices"
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
// Foreground color decorations are an independent presentation layer and compose with both sources.
const (
	methodRegisterEditorProviders = pluginhost.MethodPrefix + "editor/registerProviders"

	// editorProviderTimeout bounds one provider call.
	editorProviderTimeout = 15 * time.Second
	// maxEditorProviderBindings is the most registrations one plugin keeps across contexts.
	maxEditorProviderBindings = 32
	// Decorations run alongside language services; bound their process fan-out and latency.
	colorProviderConcurrency = 8
)

// routedProviderTypes are the provider types this host routes, in the order Core is told them.
var routedProviderTypes = core.EditorHost.ProviderTypes

// providerFunctionFields is the binding field each routed provider type fills. Its keys are exactly
// routedProviderTypes: a type routed without a field would be accepted and never called, and a field
// without a routed type would be refused by Core.
var providerFunctionFields = map[string]func(*editorProviderBinding) *string{
	"definition":       func(b *editorProviderBinding) *string { return &b.definition },
	"hover":            func(b *editorProviderBinding) *string { return &b.hover },
	"completion":       func(b *editorProviderBinding) *string { return &b.completion },
	"codeLens":         func(b *editorProviderBinding) *string { return &b.codeLens },
	"semanticTokens":   func(b *editorProviderBinding) *string { return &b.semanticTokens },
	"colorDecorations": func(b *editorProviderBinding) *string { return &b.colorDecorations },
	"documentLink":     func(b *editorProviderBinding) *string { return &b.documentLink },
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
	// subscriptionID is published with the binding under editorProviderBindings.mu.
	subscriptionID string
	// definition, hover and completion are the functions that answer those requests; empty when not declared.
	definition string
	hover      string
	completion string
	// semanticTokens is the function that answers token requests, and tokenTypes/tokenModifiers its legend.
	semanticTokens   string
	tokenTypes       []string
	tokenModifiers   []string
	colorDecorations string
	colorLegend      []core.PluginColorLegendEntry
	colorTimeout     time.Duration
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
			ColorLegend []core.PluginColorLegendEntry `json:"colorLegend"`
		} `json:"providers"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	session := s.Host.Running(caller.PluginID)
	if session == nil || session.Session.ID != caller.SessionID {
		return nil, failure(CodePreconditionFailed, "The backend session is not running.")
	}
	if request.ID == "" || len(request.ID) > 128 {
		return nil, failure(codeInvalidParams, "The registration needs an ID.")
	}
	if n := len(request.Selector.Languages) + len(request.Selector.FileExtensions) + len(request.Selector.FileNames); n < 1 || n > 32 {
		return nil, failure(codeInvalidParams, "The selector needs one to 32 entries.")
	}
	var colorBudget time.Duration
	if decoder, ok := s.kernel.(editorProviderDecoder); ok {
		value, err := editorRegistrationValue(params)
		if err != nil {
			return nil, invalidParams(err)
		}
		decoded, err := decoder.DecodeEditorProviders(ctx, map[string]any{"kind": "registration", "value": value, "types": routedProviderTypes})
		if err != nil {
			return nil, failure(codeInvalidParams, err.Error())
		}
		var normalized struct {
			Registration struct {
				Providers map[string]struct {
					BudgetMs int `json:"budgetMs"`
				} `json:"providers"`
			} `json:"registration"`
		}
		if err := json.Unmarshal(decoded, &normalized); err != nil {
			return nil, invalidParams(err)
		}
		colorBudget = time.Duration(normalized.Registration.Providers["colorDecorations"].BudgetMs) * time.Millisecond
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
		if session == nil || session.Session.ID != caller.SessionID || !session.hasFunction(provider.Function) {
			return nil, failure(CodePreconditionFailed, "The function is not registered on this session.")
		}
		*field(binding) = provider.Function
		switch kind {
		case "semanticTokens":
			binding.tokenTypes = provider.Legend.TokenTypes
			binding.tokenModifiers = provider.Legend.TokenModifiers
		case "colorDecorations":
			if colorBudget <= 0 {
				return nil, failure(CodePreconditionFailed, "Core did not provide the color decorations budget.")
			}
			binding.colorLegend = append([]core.PluginColorLegendEntry(nil), provider.ColorLegend...)
			binding.colorTimeout = colorBudget
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
	id, retired, refusal := s.publishEditorProvider(ctx, caller, workspace, session, binding)
	if refusal != nil {
		return nil, refusal
	}
	for _, previous := range retired {
		s.resources.dispose(pluginhost.Caller{PluginID: previous.pluginID, SessionID: previous.sessionID}, previous.subscriptionID)
	}
	if binding.colorDecorations != "" {
		s.editorProvidersChanged(workspace.Path)
	}
	return marshalResult(map[string]string{"subscriptionID": id})
}

// publishEditorProvider commits both owners and the resource together. Lock order is context,
// host, session, providers, then resources; owner teardown invokes disposal after unlocking.
// A detached request cannot retire a replacement backend, and context close cannot miss a late
// lease. Only the confirmed current backend can retire its predecessors' editor registrations.
func (s *Service) publishEditorProvider(ctx context.Context, caller pluginhost.Caller, workspace WorkspaceContext, session *BackendSession, binding *editorProviderBinding) (string, []*editorProviderBinding, *pluginhost.Failure) {
	s.Contexts.mu.Lock()
	defer s.Contexts.mu.Unlock()
	currentContext := s.Contexts.byPath[workspace.Path]
	if currentContext == nil || currentContext.ContextRef != workspace.ContextRef {
		return "", nil, contextFailure(ErrContextExpired)
	}
	s.Host.mu.Lock()
	defer s.Host.mu.Unlock()
	if s.Host.sessions[caller.PluginID] != session || session.Session.ID != caller.SessionID {
		return "", nil, failure(CodePreconditionFailed, "The backend session is no longer current.")
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.ended {
		return "", nil, failure(CodePreconditionFailed, "The backend session is not running.")
	}
	for _, field := range providerFunctionFields {
		if function := *field(binding); function != "" && !session.functions[function] {
			return "", nil, failure(CodePreconditionFailed, "The provider function is no longer registered.")
		}
	}
	if ctx.Err() != nil {
		return "", nil, failure(pluginhost.CodeCancelled, "The request was cancelled.")
	}
	s.providers2.mu.Lock()
	defer s.providers2.mu.Unlock()
	count := 0
	for _, existing := range s.providers2.list {
		if existing.pluginID != caller.PluginID || existing.sessionID != caller.SessionID {
			continue
		}
		count++
		if existing.contextID == binding.contextID && existing.id == binding.id {
			return "", nil, failure(CodePreconditionFailed, "The registration ID is already registered in this context.")
		}
	}
	if count >= maxEditorProviderBindings {
		return "", nil, failure(CodePreconditionFailed, "The plugin has too many editor provider registrations.")
	}
	var retired []*editorProviderBinding
	s.providers2.list = slices.DeleteFunc(s.providers2.list, func(existing *editorProviderBinding) bool {
		if existing.pluginID == caller.PluginID && existing.sessionID != caller.SessionID {
			retired = append(retired, existing)
			return true
		}
		return false
	})
	binding.subscriptionID = s.resources.add(caller, workspace.ContextID, func() {
		s.providers2.mu.Lock()
		s.providers2.list = removeProviderBinding(s.providers2.list, binding)
		s.providers2.mu.Unlock()
		if binding.colorDecorations != "" {
			s.editorProvidersChanged(workspace.Path)
		}
	})
	s.providers2.list = append(s.providers2.list, binding)
	return binding.subscriptionID, retired, nil
}

// withdrawEditorProviderFunctions releases only registrations that refer to the withdrawn
// functions. Other resources and other provider registrations of the session keep working.
func (s *Service) withdrawEditorProviderFunctions(pluginID, sessionID string, removed []string) {
	if s.providers2 == nil || len(removed) == 0 {
		return
	}
	s.providers2.mu.Lock()
	var subscriptions []string
	s.providers2.list = slices.DeleteFunc(s.providers2.list, func(binding *editorProviderBinding) bool {
		if binding.pluginID != pluginID || binding.sessionID != sessionID {
			return false
		}
		for _, field := range providerFunctionFields {
			if function := *field(binding); function != "" && slices.Contains(removed, function) {
				if binding.subscriptionID != "" {
					subscriptions = append(subscriptions, binding.subscriptionID)
				}
				return true
			}
		}
		return false
	})
	s.providers2.mu.Unlock()
	caller := pluginhost.Caller{PluginID: pluginID, SessionID: sessionID}
	for _, id := range subscriptions {
		s.resources.dispose(caller, id)
	}
}

// editorProvidersChanged asks the owning window to refresh decorations when a provider is
// registered or withdrawn. The service never calls the editor from this handler's thread.
func (s *Service) editorProvidersChanged(root string) {
	if window, ok := s.workbench.(interface{ EditorColorDecorationsChanged(string) }); ok {
		window.EditorColorDecorationsChanged(root)
	}
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

// colorDecorationsBindings returns every registration that can decorate this document.
func (s *Service) colorDecorationsBindings(root, path, languageID string) []*editorProviderBinding {
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
	var bindings []*editorProviderBinding
	for _, binding := range s.providers2.list {
		if binding.contextID == workspace.ContextID && binding.colorDecorations != "" && binding.matchesDocument(languageID, name) {
			bindings = append(bindings, binding)
		}
	}
	return bindings
}

// HasColorDecorationsProvider reports whether any registered provider serves this document.
func (s *Service) HasColorDecorationsProvider(root, path, languageID string) bool {
	return len(s.colorDecorationsBindings(root, path, languageID)) > 0
}

// PluginColorDecorations asks all matching providers, validates each result with Core, then lets
// Core resolve overlap precedence and attach each color legend's light/dark values.
func (s *Service) PluginColorDecorations(ctx context.Context, root, path, languageID, documentID string, version int) ([]core.PluginColorDecoration, error) {
	bindings := s.colorDecorationsBindings(root, path, languageID)
	if len(bindings) == 0 {
		return nil, nil
	}
	decoder, ok := s.kernel.(editorProviderDecoder)
	if !ok {
		return nil, errors.New("editor providers need the Core that normalises their answers")
	}
	type sourceResult struct {
		value map[string]any
		err   error
	}
	results := make([]sourceResult, len(bindings))
	var wait sync.WaitGroup
	call := func(index int) {
		binding := bindings[index]
		callCtx, cancel := context.WithTimeout(ctx, binding.colorTimeout)
		defer cancel()
		session := s.Host.Running(binding.pluginID)
		if session == nil || session.Session.ID != binding.sessionID {
			results[index].err = ErrBackendUnavailable
			return
		}
		argument := mustMarshal(map[string]any{"document": map[string]any{"documentID": documentID, "version": version}})
		answer, err := session.Call(callCtx, binding.colorDecorations, argument, binding.reference, binding.colorTimeout)
		if err != nil {
			results[index].err = err
			return
		}
		normalized, err := decoder.DecodeEditorProviders(ctx, map[string]any{
			"kind": "result", "type": "colorDecorations", "value": answer, "colorLegend": binding.colorLegend,
		})
		if err != nil {
			results[index].err = err
			return
		}
		var payload struct {
			Result json.RawMessage `json:"result"`
		}
		if err := json.Unmarshal(normalized, &payload); err != nil {
			results[index].err = err
			return
		}
		if len(payload.Result) == 0 {
			results[index].err = errors.New("Core returned an empty color decorations result")
			return
		}
		results[index].value = map[string]any{
			"sourceId":    binding.pluginID + "/" + binding.id,
			"colorLegend": binding.colorLegend,
			"value":       payload.Result,
		}
	}
	jobs := make(chan int)
	for range min(colorProviderConcurrency, len(bindings)) {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for index := range jobs {
				call(index)
			}
		}()
	}
	for index := range bindings {
		jobs <- index
	}
	close(jobs)
	wait.Wait()
	var sources []map[string]any
	var failures []error
	for _, result := range results {
		if result.err != nil {
			failures = append(failures, result.err)
			continue
		}
		sources = append(sources, result.value)
	}
	if len(sources) == 0 {
		return nil, errors.Join(failures...)
	}
	merged, err := decoder.DecodeEditorProviders(ctx, map[string]any{
		"kind": "mergeColorDecorations", "value": map[string]any{"sources": sources},
	})
	if err != nil {
		return nil, errors.Join(append(failures, err)...)
	}
	var payload struct {
		Decorations []core.PluginColorDecoration `json:"decorations"`
	}
	if err := json.Unmarshal(merged, &payload); err != nil {
		return nil, errors.Join(append(failures, err)...)
	}
	return payload.Decorations, errors.Join(failures...)
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
