package pluginservice

import (
	"context"
	"encoding/json"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// The public document, editor, window and browser methods of protocol version 3.
// Core has already checked the permission, the shape of the params and the
// 1 MiB budgets; the handlers repeat the bounds the host itself enforces and map
// the workbench's answers to the contract's codes.
const (
	methodDocumentsList        = pluginhost.MethodPrefix + "documents/list"
	methodDocumentsGetSnapshot = pluginhost.MethodPrefix + "documents/getSnapshot"
	methodEditorGetActive      = pluginhost.MethodPrefix + "editor/getActive"
	methodEditorGetSelections  = pluginhost.MethodPrefix + "editor/getSelections"
	methodEditorApplyEdits     = pluginhost.MethodPrefix + "editor/applyEdits"
	methodEditorReplaceSel     = pluginhost.MethodPrefix + "editor/replaceSelections"
	methodEditorInsertText     = pluginhost.MethodPrefix + "editor/insertText"
	methodEditorOpen           = pluginhost.MethodPrefix + "editor/open"
	methodEditorReveal         = pluginhost.MethodPrefix + "editor/reveal"
	methodWindowInformation    = pluginhost.MethodPrefix + "window/showInformation"
	methodWindowWarning        = pluginhost.MethodPrefix + "window/showWarning"
	methodWindowError          = pluginhost.MethodPrefix + "window/showError"
	methodBrowserOpenExternal  = pluginhost.MethodPrefix + "browser/openExternal"

	// maxSnapshotBytes is what one snapshot may carry: it leaves room for
	// worst-case JSON escaping under the 1 MiB result budget.
	maxSnapshotBytes = 128 * 1024
	maxEditsPerBatch = 1000
	maxMessageText   = 2000
	maxMessageAction = 40
	maxMessageCount  = 3
)

// Message limits per plugin: the contract allows 5 messages in 10 seconds and 3
// waiting at once.
const (
	messageBurst     = 5
	messageWindow    = 10 * time.Second
	messagePendingAt = 3
)

// messageLimiter keeps the per-plugin message rate and queue limits.
type messageLimiter struct {
	mu      sync.Mutex
	now     func() time.Time
	shown   map[string][]time.Time
	pending map[string]int
}

func newMessageLimiter() *messageLimiter {
	return &messageLimiter{now: time.Now, shown: make(map[string][]time.Time), pending: make(map[string]int)}
}

// admit counts one message for a plugin. It returns a release function, or a
// failure when a limit is reached.
func (l *messageLimiter) admit(plugin string) (func(), *pluginhost.Failure) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	recent := l.shown[plugin][:0]
	for _, at := range l.shown[plugin] {
		if now.Sub(at) < messageWindow {
			recent = append(recent, at)
		}
	}
	if len(recent) >= messageBurst {
		retry := messageWindow - now.Sub(recent[0])
		l.shown[plugin] = recent
		return nil, &pluginhost.Failure{Code: CodeRateLimited, Message: "Too many messages in a short time.",
			Details: detailsOf(map[string]any{"retryAfterMilliseconds": retry.Milliseconds() + 1})}
	}
	if l.pending[plugin] >= messagePendingAt {
		l.shown[plugin] = recent
		return nil, failure(CodeBusy, "The plugin already has messages waiting for the user.")
	}
	l.shown[plugin] = append(recent, now)
	l.pending[plugin]++
	return func() {
		l.mu.Lock()
		l.pending[plugin]--
		l.mu.Unlock()
	}, nil
}

// AttachWorkbench connects the window to the host services that need it, and
// registers their handlers. A host service is registered only here, so a session
// started without a window is never granted a method it cannot answer.
func (s *Service) AttachWorkbench(workbench Workbench) error {
	if workbench == nil {
		return nil
	}
	s.workbench = workbench
	for _, entry := range []struct {
		method  string
		handler pluginhost.Handler
	}{
		{methodDocumentsList, s.handleDocumentsList},
		{methodDocumentsGetSnapshot, s.handleDocumentsSnapshot},
		{methodEditorGetActive, s.handleEditorActive},
		{methodEditorGetSelections, s.handleEditorSelections},
		{methodEditorApplyEdits, s.handleEditorApplyEdits},
		{methodEditorReplaceSel, s.handleEditorReplaceSelections},
		{methodEditorInsertText, s.handleEditorInsertText},
		{methodEditorOpen, s.handleEditorOpen},
		{methodEditorReveal, s.handleEditorOpen},
		{methodBrowserOpenExternal, s.handleBrowserOpenExternal},
	} {
		if err := s.HostServices.Register(entry.method, entry.handler); err != nil {
			return err
		}
	}
	if host, ok := workbench.(TerminalHost); ok {
		if err := s.registerTerminals(host); err != nil {
			return err
		}
	}
	if host, ok := workbench.(VirtualDocumentHost); ok {
		if err := s.registerContentProviders(host); err != nil {
			return err
		}
	}
	if err := s.registerEditorActions(); err != nil {
		return err
	}
	if err := s.registerEditorProviders(); err != nil {
		return err
	}
	for _, level := range []struct {
		method string
		name   string
	}{{methodWindowInformation, "information"}, {methodWindowWarning, "warning"}, {methodWindowError, "error"}} {
		name := level.name
		// A message waits for the user, so the machine deadline must not cut it.
		if err := s.HostServices.RegisterUserChoice(level.method, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleWindowMessage(ctx, params, name)
		}); err != nil {
			return err
		}
	}
	return nil
}

// workspaceRequest is the part every method shares: the caller and the context
// the request names, resolved to a live workspace.
func (s *Service) workspaceRequest(ctx context.Context, ref ContextRef) (pluginhost.Caller, WorkspaceContext, *pluginhost.Failure) {
	caller, ok := pluginhost.CallerFrom(ctx)
	if !ok {
		return caller, WorkspaceContext{}, failure(pluginhost.CodeHostFailure, "the request has no calling plugin")
	}
	workspace, err := s.Contexts.Lookup(ref)
	if err != nil {
		return caller, workspace, contextFailure(err)
	}
	return caller, workspace, nil
}

type documentParams struct {
	Context    ContextRef `json:"context"`
	DocumentID string     `json:"documentID"`
}

func decodeDocumentParams(params json.RawMessage) (documentParams, *pluginhost.Failure) {
	var request documentParams
	if err := decodeStrict(params, &request); err != nil {
		return request, invalidParams(err)
	}
	return request, nil
}

func (s *Service) handleDocumentsList(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context ContextRef `json:"context"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	_, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	documents, err := s.workbench.Documents(ctx, workspace.Path)
	if err != nil {
		return nil, hostFailureOf(err)
	}
	if documents == nil {
		documents = []DocumentSummary{}
	}
	return marshalResult(map[string]any{"documents": documents})
}

func (s *Service) handleDocumentsSnapshot(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, refusal := decodeDocumentParams(params)
	if refusal != nil {
		return nil, refusal
	}
	_, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	summary, text, err := s.workbench.Snapshot(ctx, workspace.Path, request.DocumentID, maxSnapshotBytes)
	if err != nil {
		return nil, hostFailureOf(err)
	}
	if len(text) > maxSnapshotBytes {
		return nil, failure(CodeLimitExceeded, "The document is larger than a snapshot may be.")
	}
	return marshalResult(map[string]any{"document": summary, "text": text})
}

func (s *Service) handleEditorActive(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context ContextRef `json:"context"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	_, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	active, err := s.workbench.Active(ctx, workspace.Path)
	if err != nil {
		return nil, hostFailureOf(err)
	}
	if active == nil {
		return nil, nil
	}
	return marshalResult(active)
}

func (s *Service) handleEditorSelections(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, refusal := decodeDocumentParams(params)
	if refusal != nil {
		return nil, refusal
	}
	_, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	result, err := s.workbench.Selections(ctx, workspace.Path, request.DocumentID)
	if err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(result)
}

func validPosition(p Position) bool { return p.Line >= 1 && p.Column >= 1 }

func validRange(r Range) bool {
	if !validPosition(r.Start) || !validPosition(r.End) {
		return false
	}
	return r.Start.Line < r.End.Line || (r.Start.Line == r.End.Line && r.Start.Column <= r.End.Column)
}

// applyEdits runs one validated batch and shapes the answer.
func (s *Service) applyEdits(ctx context.Context, ref ContextRef, documentID string, expected int, edits []RangeEdit) (json.RawMessage, *pluginhost.Failure) {
	_, workspace, refusal := s.workspaceRequest(ctx, ref)
	if refusal != nil {
		return nil, refusal
	}
	if documentID == "" || expected < 0 {
		return nil, failure(codeInvalidParams, "documentID and expectedVersion are required.")
	}
	if len(edits) > maxEditsPerBatch {
		return nil, failure(CodeLimitExceeded, "A batch holds at most 1000 edits.")
	}
	for _, edit := range edits {
		if !validRange(edit.Range) || !utf8.ValidString(edit.Text) {
			return nil, failure(codeInvalidParams, "An edit has an invalid range or text.")
		}
	}
	result, err := s.workbench.Edit(ctx, workspace.Path, EditRequest{DocumentID: documentID, ExpectedVersion: expected, Edits: edits})
	if err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(result)
}

type editParams struct {
	Context         ContextRef `json:"context"`
	DocumentID      string     `json:"documentID"`
	ExpectedVersion int        `json:"expectedVersion"`
}

func (s *Service) handleEditorApplyEdits(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		editParams
		Edits []struct {
			Range Range  `json:"range"`
			Text  string `json:"text"`
		} `json:"edits"`
	}
	if err := decodeStrictEmbedded(params, &request, "context", "documentID", "expectedVersion", "edits"); err != nil {
		return nil, invalidParams(err)
	}
	edits := make([]RangeEdit, len(request.Edits))
	for i, e := range request.Edits {
		edits[i] = RangeEdit{Range: e.Range, Text: e.Text}
	}
	return s.applyEdits(ctx, request.Context, request.DocumentID, request.ExpectedVersion, edits)
}

func (s *Service) handleEditorInsertText(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		editParams
		At   Position `json:"at"`
		Text string   `json:"text"`
	}
	if err := decodeStrictEmbedded(params, &request, "context", "documentID", "expectedVersion", "at", "text"); err != nil {
		return nil, invalidParams(err)
	}
	return s.applyEdits(ctx, request.Context, request.DocumentID, request.ExpectedVersion,
		[]RangeEdit{{Range: Range{Start: request.At, End: request.At}, Text: request.Text}})
}

func (s *Service) handleEditorReplaceSelections(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		editParams
		Selections   []Selection `json:"selections"`
		Replacements []string    `json:"replacements"`
	}
	if err := decodeStrictEmbedded(params, &request, "context", "documentID", "expectedVersion", "selections", "replacements"); err != nil {
		return nil, invalidParams(err)
	}
	if len(request.Selections) == 0 || (len(request.Replacements) != 1 && len(request.Replacements) != len(request.Selections)) {
		return nil, failure(codeInvalidParams, "Give one replacement for all selections or one for each.")
	}
	edits := make([]RangeEdit, len(request.Selections))
	for i, selection := range request.Selections {
		// A selection keeps its direction; the edit covers it in document order.
		r := Range{Start: selection.Anchor, End: selection.Active}
		if !validRange(r) {
			r = Range{Start: selection.Active, End: selection.Anchor}
		}
		text := request.Replacements[0]
		if len(request.Replacements) > 1 {
			text = request.Replacements[i]
		}
		edits[i] = RangeEdit{Range: r, Text: text}
	}
	return s.applyEdits(ctx, request.Context, request.DocumentID, request.ExpectedVersion, edits)
}

type openParams struct {
	Context    ContextRef `json:"context"`
	Resource   Resource   `json:"resource"`
	Activation string     `json:"activation"`
	Range      *Range     `json:"range"`
	Tab        string     `json:"tab"`
}

func (s *Service) handleEditorOpen(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request openParams
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	switch request.Activation {
	case "", "select", "background":
	default:
		return nil, &pluginhost.Failure{Code: CodeUnsupportedOption, Message: "Unknown activation.", Details: detailsOf(map[string]any{"option": "activation"})}
	}
	if request.Tab != "" && request.Tab != "regular" {
		return nil, &pluginhost.Failure{Code: CodeUnsupportedOption, Message: "Only regular tabs open.", Details: detailsOf(map[string]any{"option": "tab"})}
	}
	path, err := s.resolveResource(caller.PluginID, workspace, request.Resource)
	if err != nil {
		return nil, failure(codeInvalidParams, "The resource is not a path inside the workspace.")
	}
	open := OpenRequest{Path: path, Background: request.Activation == "background"}
	if request.Range != nil {
		if !validRange(*request.Range) {
			return nil, failure(codeInvalidParams, "The range is invalid.")
		}
		start := request.Range.Start
		open.Caret = &start
	}
	result, err := s.workbench.Open(ctx, workspace.Path, open)
	if err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(result)
}

func (s *Service) handleWindowMessage(ctx context.Context, params json.RawMessage, level string) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context ContextRef `json:"context"`
		Text    string     `json:"text"`
		Actions []string   `json:"actions"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, _, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if n := utf8.RuneCountInString(request.Text); n == 0 || n > maxMessageText || len(request.Actions) > maxMessageCount {
		return nil, failure(codeInvalidParams, "A message has 1 to 2000 characters and at most 3 actions.")
	}
	for _, action := range request.Actions {
		if n := utf8.RuneCountInString(action); n == 0 || n > maxMessageAction {
			return nil, failure(codeInvalidParams, "An action has 1 to 40 characters.")
		}
	}
	release, limited := s.messages.admit(caller.PluginID)
	if limited != nil {
		return nil, limited
	}
	defer release()
	selected, err := s.workbench.Prompt(ctx, PromptRequest{PluginID: caller.PluginID, Level: level, Text: request.Text, Actions: request.Actions})
	if err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(map[string]*int{"selectedIndex": selected})
}

func (s *Service) handleBrowserOpenExternal(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context  ContextRef `json:"context"`
		URL      string     `json:"url"`
		Resource *Resource  `json:"resource"`
		Unsaved  string     `json:"unsaved"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	if _, _, refusal := s.workspaceRequest(ctx, request.Context); refusal != nil {
		return nil, refusal
	}
	if request.Resource != nil || request.Unsaved != "" {
		// The system browser opens addresses; opening a saved workspace file
		// needs a file: URL, which the platform helper refuses.
		return nil, &pluginhost.Failure{Code: CodeUnsupportedOption, Message: "Opening a workspace file in the browser is not supported.",
			Details: detailsOf(map[string]any{"option": "resource"})}
	}
	address, err := httpURL(request.URL)
	if err != nil {
		return nil, failure(codeInvalidParams, "url must be an http or https address.")
	}
	if err := s.workbench.OpenExternal(ctx, address); err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(map[string]any{"opened": true, "source": "web"})
}
