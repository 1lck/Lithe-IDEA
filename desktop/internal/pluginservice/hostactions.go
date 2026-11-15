package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// Independent editor actions: a tool backend registers actions for the files it selects, and the
// host asks the backend's collection function which actions a document has. An action is shown in
// the editor and, when clicked, calls the backend's function again. Core validates every message;
// the host owns the calls, the document versions and the session they belong to.
const (
	methodRegisterEditorActions = pluginhost.MethodPrefix + "editor/registerActions"

	// editorActionCollectTimeout bounds one collection, the whole batch of a document's bindings.
	editorActionCollectTimeout = 8 * time.Second
	// editorActionInvokeTimeout bounds one click.
	editorActionInvokeTimeout = 90 * time.Second
	// maxEditorActionBindings is the most bindings one plugin registers across contexts.
	maxEditorActionBindings = 32
)

// editorActionDecoder is the part of Core that validates editor action messages.
type editorActionDecoder interface {
	DecodeEditorActions(ctx context.Context, payload any) (json.RawMessage, error)
}

// EditorActionRange is a range in one-based UTF-16 positions, half-open.
type EditorActionRange struct {
	StartLine, StartColumn, EndLine, EndColumn int
}

// EditorAction is one action a collection answered for a document. The host keeps the session and
// reference it came from, so a click reaches the same backend session.
type EditorAction struct {
	ID    string
	Title string
	Icon  string
	Range EditorActionRange
	// Alternatives are further choices in the action's menu: each runs its own function.
	Alternatives []EditorActionChoice

	pluginID   string
	sessionID  string
	reference  json.RawMessage
	invoke     editorActionInvoke
	documentID string
	version    int
}

// EditorActionChoice is one menu entry of an action: the action itself or an alternative.
type EditorActionChoice struct {
	ID    string
	Title string
	Icon  string

	invoke editorActionInvoke
}

type editorActionInvoke struct {
	function string
	params   json.RawMessage
}

// Version is the document version the action was collected for; a click on a newer text is refused.
func (a EditorAction) Version() int { return a.version }

// EditorLocation is a place a clicked action reveals, zero-based as LSP positions are.
type EditorLocation struct {
	URI                       string
	StartLine, StartCharacter int
	EndLine, EndCharacter     int
}

type editorActionBinding struct {
	pluginID  string
	sessionID string
	contextID string
	reference json.RawMessage
	id        string
	function  string
	// extensions and names are the literal selector, lowercased; the extensions have no dot.
	extensions map[string]bool
	names      map[string]bool
}

// editorActionBindings holds the registrations of every window's workspaces.
type editorActionBindings struct {
	mu   sync.Mutex
	list []*editorActionBinding
}

// registerEditorActions attaches the registration method to a window. The bindings are only
// recorded here; the backend is called when a document is collected.
func (s *Service) registerEditorActions() error {
	s.actions = &editorActionBindings{}
	return s.HostServices.Register(methodRegisterEditorActions, s.handleRegisterEditorActions)
}

func (s *Service) handleRegisterEditorActions(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context  ContextRef `json:"context"`
		ID       string     `json:"id"`
		Function string     `json:"function"`
		Selector struct {
			FileExtensions []string `json:"fileExtensions"`
			FileNames      []string `json:"fileNames"`
		} `json:"selector"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if request.ID == "" || len(request.ID) > 128 || !validFunctionID(request.Function) {
		return nil, failure(codeInvalidParams, "The registration needs an ID and a function ID.")
	}
	if n := len(request.Selector.FileExtensions) + len(request.Selector.FileNames); n < 1 || n > 32 {
		return nil, failure(codeInvalidParams, "The selector needs one to 32 literal names or extensions.")
	}
	session := s.Host.Running(caller.PluginID)
	if session == nil || session.Session.ID != caller.SessionID || !session.hasFunction(request.Function) {
		return nil, failure(CodePreconditionFailed, "The function is not registered on this session.")
	}
	if decoder, ok := s.kernel.(editorActionDecoder); ok {
		value, err := editorRegistrationValue(params)
		if err != nil {
			return nil, invalidParams(err)
		}
		if _, err := decoder.DecodeEditorActions(ctx, map[string]any{"kind": "registration", "value": value, "version": core.EditorActionDecodeVersion, "icons": core.EditorHost.ActionIcons, "sourceBytes": core.EditorHost.ActionSourceBytes}); err != nil {
			return nil, failure(codeInvalidParams, err.Error())
		}
	}
	binding := &editorActionBinding{
		pluginID: caller.PluginID, sessionID: caller.SessionID, contextID: workspace.ContextID,
		reference: mustMarshal(workspace.ContextRef), id: request.ID, function: request.Function,
		extensions: map[string]bool{}, names: map[string]bool{},
	}
	for _, extension := range request.Selector.FileExtensions {
		binding.extensions[strings.ToLower(strings.TrimPrefix(extension, "."))] = true
	}
	for _, name := range request.Selector.FileNames {
		binding.names[strings.ToLower(name)] = true
	}
	s.actions.mu.Lock()
	count := 0
	for _, existing := range s.actions.list {
		if existing.pluginID == caller.PluginID {
			count++
		}
		if existing.contextID == binding.contextID && existing.id == binding.id && existing.pluginID == binding.pluginID {
			s.actions.mu.Unlock()
			return nil, failure(CodePreconditionFailed, "The registration ID is already registered in this context.")
		}
	}
	if count >= maxEditorActionBindings {
		s.actions.mu.Unlock()
		return nil, failure(CodePreconditionFailed, "The plugin has too many editor action registrations.")
	}
	s.actions.list = append(s.actions.list, binding)
	s.actions.mu.Unlock()
	id := s.resources.add(caller, workspace.ContextID, func() {
		s.actions.mu.Lock()
		s.actions.list = removeBinding(s.actions.list, binding)
		s.actions.mu.Unlock()
		s.editorActionsChanged(workspace.Path)
	})
	s.editorActionsChanged(workspace.Path)
	return marshalResult(map[string]string{"subscriptionID": id})
}

// editorRegistrationValue separates the host routing envelope from the Core declaration.
// Context has already been checked by workspaceRequest; Core validates only the declaration.
func editorRegistrationValue(params json.RawMessage) (map[string]json.RawMessage, error) {
	var value map[string]json.RawMessage
	if err := json.Unmarshal(params, &value); err != nil {
		return nil, err
	}
	delete(value, "context")
	return value, nil
}

// editorActionsChanged invalidates the window's presentation after a binding changes.
// The window queues work; it must not call the backend synchronously from this handler.
func (s *Service) editorActionsChanged(root string) {
	if window, ok := s.workbench.(interface{ EditorActionsChanged(string) }); ok {
		window.EditorActionsChanged(root)
	}
}

func removeBinding(list []*editorActionBinding, target *editorActionBinding) []*editorActionBinding {
	kept := list[:0]
	for _, binding := range list {
		if binding != target {
			kept = append(kept, binding)
		}
	}
	return kept
}

func mustMarshal(value any) json.RawMessage {
	data, _ := json.Marshal(value)
	return data
}

// matches reports whether a file name is in a binding's selector.
func (b *editorActionBinding) matches(name string) bool {
	lower := strings.ToLower(name)
	if b.names[lower] {
		return true
	}
	extension := strings.TrimPrefix(filepath.Ext(lower), ".")
	return extension != "" && b.extensions[extension]
}

// CollectEditorActions asks every binding of the workspace whose selector matches the file for its
// actions on the document's text. A binding that fails or answers badly contributes nothing and the
// others still answer; the error reports the first failure, if any, alongside the actions found.
func (s *Service) CollectEditorActions(ctx context.Context, root, path string, documentID string, version int, text string) ([]EditorAction, error) {
	if s == nil || s.actions == nil {
		return nil, nil
	}
	workspace, ok := s.Contexts.ByPath(root)
	if !ok {
		return nil, nil
	}
	decoder, ok := s.kernel.(editorActionDecoder)
	if !ok {
		return nil, errors.New("editor actions need the Core that validates them")
	}
	name := filepath.Base(path)
	s.actions.mu.Lock()
	var bindings []*editorActionBinding
	for _, binding := range s.actions.list {
		if binding.contextID == workspace.ContextID && binding.matches(name) {
			bindings = append(bindings, binding)
		}
	}
	s.actions.mu.Unlock()
	// The eight seconds bound the whole batch of bindings, not each one: every call shares this context.
	batch, cancel := context.WithTimeout(ctx, editorActionCollectTimeout)
	defer cancel()
	var actions []EditorAction
	var failures []error
	for _, binding := range bindings {
		session := s.Host.Running(binding.pluginID)
		if session == nil || session.Session.ID != binding.sessionID {
			continue
		}
		argument := mustMarshal(map[string]any{
			"document": map[string]any{"documentID": documentID, "version": version, "path": path},
			"text":     text,
		})
		answer, err := session.Call(batch, binding.function, argument, binding.reference, editorActionCollectTimeout)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		decoded, err := decoder.DecodeEditorActions(ctx, map[string]any{"kind": "actions", "value": answer, "text": text, "version": core.EditorActionDecodeVersion, "icons": core.EditorHost.ActionIcons, "sourceBytes": core.EditorHost.ActionSourceBytes})
		if err != nil {
			failures = append(failures, err)
			continue
		}
		var result struct {
			Actions []struct {
				ID    string `json:"id"`
				Range struct {
					Start struct{ Line, Column int } `json:"start"`
					End   struct{ Line, Column int } `json:"end"`
				} `json:"range"`
				Title  string `json:"title"`
				Icon   string `json:"icon"`
				Invoke struct {
					FunctionID string          `json:"functionID"`
					Params     json.RawMessage `json:"params"`
				} `json:"invoke"`
				Alternatives []struct {
					ID     string `json:"id"`
					Title  string `json:"title"`
					Icon   string `json:"icon"`
					Invoke struct {
						FunctionID string          `json:"functionID"`
						Params     json.RawMessage `json:"params"`
					} `json:"invoke"`
				} `json:"alternatives"`
			} `json:"actions"`
		}
		if err := json.Unmarshal(decoded, &result); err != nil {
			failures = append(failures, err)
			continue
		}
		for _, item := range result.Actions {
			action := EditorAction{
				ID: item.ID, Title: item.Title, Icon: item.Icon,
				Range:    EditorActionRange{StartLine: item.Range.Start.Line, StartColumn: item.Range.Start.Column, EndLine: item.Range.End.Line, EndColumn: item.Range.End.Column},
				pluginID: binding.pluginID, sessionID: binding.sessionID, reference: binding.reference,
				invoke:     editorActionInvoke{function: item.Invoke.FunctionID, params: item.Invoke.Params},
				documentID: documentID, version: version,
			}
			for _, alternative := range item.Alternatives {
				action.Alternatives = append(action.Alternatives, EditorActionChoice{
					ID: alternative.ID, Title: alternative.Title, Icon: alternative.Icon,
					invoke: editorActionInvoke{function: alternative.Invoke.FunctionID, params: alternative.Invoke.Params},
				})
			}
			actions = append(actions, action)
		}
	}
	return actions, errors.Join(failures...)
}

// InvokeEditorAction runs the action, or one of its alternatives when alternative is not -1, and
// returns the locations the result asks to reveal. The backend validates the live document itself.
func (s *Service) InvokeEditorAction(ctx context.Context, action EditorAction, alternative int) ([]EditorLocation, error) {
	if s == nil || s.actions == nil {
		return nil, ErrBackendUnavailable
	}
	session := s.Host.Running(action.pluginID)
	if session == nil || session.Session.ID != action.sessionID {
		return nil, ErrBackendUnavailable
	}
	function, params, choiceID := action.invoke.function, action.invoke.params, ""
	if alternative >= 0 {
		if alternative >= len(action.Alternatives) {
			return nil, errors.New("the alternative does not exist")
		}
		// The choice's own function and parameters come from the collection answer kept with the action.
		choice := action.Alternatives[alternative]
		choiceID = choice.ID
		function, params = choice.invoke.function, choice.invoke.params
	}
	argument := map[string]any{
		"documentID": action.documentID, "expectedVersion": action.version, "actionID": action.ID,
		"data": json.RawMessage(params),
	}
	if choiceID != "" {
		argument["alternativeID"] = choiceID
	}
	answer, err := session.Call(ctx, function, mustMarshal(argument), action.reference, editorActionInvokeTimeout)
	if err != nil {
		return nil, err
	}
	decoder, ok := s.kernel.(editorActionDecoder)
	if !ok {
		return nil, nil
	}
	decoded, err := decoder.DecodeEditorActions(ctx, map[string]any{"kind": "invokeResult", "value": answer, "version": core.EditorActionDecodeVersion, "icons": core.EditorHost.ActionIcons, "sourceBytes": core.EditorHost.ActionSourceBytes})
	if err != nil {
		return nil, err
	}
	var result struct {
		Reveal *struct {
			Locations []struct {
				URI   string `json:"uri"`
				Range struct {
					Start struct{ Line, Character int } `json:"start"`
					End   struct{ Line, Character int } `json:"end"`
				} `json:"range"`
			} `json:"locations"`
		} `json:"reveal"`
	}
	if err := json.Unmarshal(decoded, &result); err != nil || result.Reveal == nil {
		return nil, err
	}
	locations := make([]EditorLocation, 0, len(result.Reveal.Locations))
	for _, location := range result.Reveal.Locations {
		locations = append(locations, EditorLocation{
			URI: location.URI, StartLine: location.Range.Start.Line, StartCharacter: location.Range.Start.Character,
			EndLine: location.Range.End.Line, EndCharacter: location.Range.End.Character,
		})
	}
	return locations, nil
}
