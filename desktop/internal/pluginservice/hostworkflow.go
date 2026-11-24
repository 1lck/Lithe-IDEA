package pluginservice

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// QuickItem has a stable backend identifier; filtering never changes its identity.
type QuickItem struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Description string `json:"description,omitempty"`
	Detail      string `json:"detail,omitempty"`
	Picked      bool   `json:"picked,omitempty"`
}

// QuickInput is one queued user choice. Password input is never prefilled.
type QuickInput struct {
	PluginID, Title, Prompt, Placeholder, Value string
	Password, CanPickMany, Pick                 bool
	Items                                       []QuickItem
	Filter                                      func(context.Context, string) ([]int, error)
	Validate                                    func(context.Context, string) (bool, error)
}

// QuickResult distinguishes dismissal (nil) from an accepted empty input.
type QuickResult struct {
	Value string   `json:"value"`
	IDs   []string `json:"ids"`
}

// PreviewRequest names one saved resource or a private read-only inline document.
type PreviewRequest struct {
	PluginID, Owner, ID, Title, Text, Path, Kind, Presentation string
	Range                                                      *Range
}

// DiffRequest shows two bounded texts in the existing read-only Diff editor.
type DiffRequest struct {
	Title, Original, Modified, OriginalTitle, ModifiedTitle string
}

// OutputUpdate carries only newly completed lines and the unfinished line.
type OutputUpdate struct {
	ID, Name, Action string
	Lines            []string
	Open             string
	MaxLines         int
	MaxBytes         int
}

// ProgressUpdate belongs to one backend handle. Cancel sends a subscription event.
type ProgressUpdate struct {
	ID, Title, Message string
	Percentage         *float64
	Cancellable        bool
	Remove             bool
	Cancel             func()
	MessageSet         bool
}

// StatusUpdate belongs to one session and opaque item ID.
type StatusUpdate struct {
	ID, PluginID, Text, Tooltip, CommandID string
	Priority                               int
	Order                                  []string
	Remove                                 bool
}

// PluginWorkflow exposes Core projections to the native view surfaces.
func (s *Service) PluginWorkflow(ctx context.Context, request, result any) error {
	kernel, ok := s.kernel.(workflowKernel)
	if !ok {
		return &HostError{Code: CodeUnsupportedOption, Message: "Plugin workflow projections are unavailable."}
	}
	return kernel.PluginWorkflow(ctx, request, result)
}

// WorkflowHost is the native presentation boundary. Core validates and projects
// each operation before these methods run; the host never parses plugin business.
type WorkflowHost interface {
	QuickInput(context.Context, string, QuickInput) (*QuickResult, error)
	OpenPreview(context.Context, string, PreviewRequest) (PreviewResult, error)
	ShowTextDiff(context.Context, string, DiffRequest) error
	UpdateOutput(context.Context, string, OutputUpdate) error
	UpdateProgress(context.Context, string, ProgressUpdate) error
	UpdateStatus(context.Context, string, StatusUpdate) error
	ReadClipboard(context.Context) (string, error)
	WriteClipboard(context.Context, string) error
	RevealResource(context.Context, string) error
	OpenBrowserResource(context.Context, string, string, string) (bool, error)
	// ReleaseWorkflow queues idempotent removal without waiting for the window.
	// Context closure may itself run on the window thread.
	ReleaseWorkflow(root, kind, id string)
}

// PreviewResult preserves the existing document-open result for HTML previews.
type PreviewResult struct {
	OpenResult
	UsesLiveBuffer bool   `json:"usesLiveBuffer"`
	Presentation   string `json:"presentation"`
}

type workflowKernel interface {
	PluginWorkflow(context.Context, any, any) error
}

type workflowResource struct {
	mu                          sync.Mutex
	caller                      pluginhost.Caller
	contextID, root             string
	id, lease, kind, name, open string
	priority                    int
	closed                      bool
	cancelled                   bool
	lifetime                    context.Context
	stop                        context.CancelFunc
}

type workflowResources struct {
	statusMu  sync.Mutex
	httpMu    sync.Mutex
	transport *http.Transport
	mu        sync.Mutex
	byID      map[string]*workflowResource
}

func (s *Service) registerWorkflows(host WorkflowHost, kernel workflowKernel) error {
	s.workflow = &workflowResources{byID: map[string]*workflowResource{}}
	methods := []string{"window/showQuickPick", "window/showInputBox", "preview/openMarkdown", "preview/openHTML", "editor/showDiff", "views/refresh", "output/create", "output/append", "output/clear", "output/show", "output/dispose", "progress/create", "progress/report", "progress/end", "statusBar/setItem", "statusBar/removeItem", "clipboard/readText", "clipboard/writeText", "workspace/reveal", "network/request"}
	for _, method := range methods {
		name := method
		handler := func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleWorkflow(ctx, host, kernel, name, params)
		}
		register := s.HostServices.Register
		if strings.HasPrefix(method, "window/") {
			register = s.HostServices.RegisterUserChoice
		}
		if err := register(pluginhost.MethodPrefix+method, handler); err != nil {
			return err
		}
	}
	return nil
}

type workflowParams struct {
	Context              ContextRef        `json:"context"`
	Title                string            `json:"title"`
	Prompt               string            `json:"prompt"`
	Placeholder          string            `json:"placeholder"`
	Value                string            `json:"value"`
	Password             bool              `json:"password"`
	CanPickMany          bool              `json:"canPickMany"`
	Items                []QuickItem       `json:"items"`
	Resource             *Resource         `json:"resource"`
	Text                 string            `json:"text"`
	ID                   string            `json:"id"`
	Presentation         string            `json:"presentation"`
	Range                *Range            `json:"range"`
	Original             string            `json:"original"`
	Modified             string            `json:"modified"`
	OriginalTitle        string            `json:"originalTitle"`
	ModifiedTitle        string            `json:"modifiedTitle"`
	Instance             string            `json:"instance"`
	Name                 string            `json:"name"`
	ChannelID            string            `json:"channelID"`
	ProgressID           string            `json:"progressID"`
	Cancellable          bool              `json:"cancellable"`
	Message              *string           `json:"message"`
	Percentage           *float64          `json:"percentage"`
	Tooltip              string            `json:"tooltip"`
	CommandID            string            `json:"commandID"`
	Priority             int               `json:"priority"`
	URL                  string            `json:"url"`
	Method               string            `json:"method"`
	Headers              map[string]string `json:"headers"`
	Body                 string            `json:"body"`
	TimeoutMilliseconds  int               `json:"timeoutMilliseconds"`
	MaximumResponseBytes int               `json:"maximumResponseBytes"`
}

func (s *Service) handleWorkflow(ctx context.Context, host WorkflowHost, kernel workflowKernel, method string, raw json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	_, session, refusal := s.buildCaller(ctx)
	if refusal != nil {
		return nil, refusal
	}
	var prepared struct {
		Params workflowParams `json:"params"`
		Limits struct {
			TextBytes       int `json:"textBytes"`
			Resources       int `json:"resources"`
			HTTPHeaderBytes int `json:"httpHeaderBytes"`
		} `json:"limits"`
	}
	if err := kernel.PluginWorkflow(ctx, map[string]any{"operation": "prepare", "method": method, "params": raw, "manifest": session.manifest}, &prepared); err != nil {
		return nil, workflowFailure(err)
	}
	p := prepared.Params
	caller, workspace, refusal := s.workspaceRequest(ctx, p.Context)
	if refusal != nil {
		return nil, refusal
	}
	// Tie native I/O and queued input to context closure as well as request cancellation.
	ctx, cancel := context.WithCancel(ctx)
	lease := s.resources.add(caller, workspace.ContextID, cancel)
	defer s.resources.dispose(caller, lease)
	defer cancel()
	if _, _, refusal := s.workspaceRequest(ctx, p.Context); refusal != nil {
		return nil, refusal
	}
	if session.isEnded() {
		return nil, failure(pluginhost.CodeCancelled, "The requesting backend session ended.")
	}
	if err := ctx.Err(); err != nil {
		return nil, hostFailureOf(err)
	}
	root := workspace.Path
	switch method {
	case "window/showQuickPick", "window/showInputBox":
		release, refusal := s.messages.admit(caller.PluginID)
		if refusal != nil {
			return nil, refusal
		}
		defer release()
		input := QuickInput{PluginID: caller.PluginID, Title: p.Title, Prompt: p.Prompt, Placeholder: p.Placeholder, Value: p.Value, Password: p.Password, CanPickMany: p.CanPickMany, Items: p.Items, Pick: strings.HasSuffix(method, "showQuickPick")}
		input.Filter = func(ctx context.Context, query string) ([]int, error) {
			var result struct {
				Indices []int `json:"indices"`
			}
			err := kernel.PluginWorkflow(ctx, map[string]any{"operation": "quickPick", "items": p.Items, "query": query}, &result)
			return result.Indices, err
		}
		input.Validate = func(ctx context.Context, value string) (bool, error) {
			var result struct {
				Valid bool `json:"valid"`
			}
			err := kernel.PluginWorkflow(ctx, map[string]any{"operation": "input", "pick": input.Pick, "value": value}, &result)
			return result.Valid, err
		}
		result, err := host.QuickInput(ctx, root, input)
		if err != nil {
			return nil, hostFailureOf(err)
		}
		if result == nil {
			return json.RawMessage("null"), nil
		}
		if input.Pick {
			return marshalResult(map[string]any{"selectedIDs": result.IDs})
		}
		return marshalResult(map[string]any{"value": result.Value})
	case "preview/openMarkdown", "preview/openHTML":
		request := PreviewRequest{PluginID: caller.PluginID, Owner: caller.SessionID + ":" + workspace.ContextID, ID: p.ID, Title: p.Title, Text: p.Text, Kind: strings.TrimPrefix(method, "preview/open"), Presentation: p.Presentation, Range: p.Range}
		if p.Resource != nil {
			path, err := s.resolveResource(caller.PluginID, workspace, *p.Resource)
			if err != nil {
				return nil, hostFailureOf(err)
			}
			request.Path = path
		}
		result, err := host.OpenPreview(ctx, root, request)
		if err != nil {
			return nil, hostFailureOf(err)
		}
		return marshalResult(result)
	case "editor/showDiff":
		if err := host.ShowTextDiff(ctx, root, DiffRequest{Title: p.Title, Original: p.Original, Modified: p.Modified, OriginalTitle: p.OriginalTitle, ModifiedTitle: p.ModifiedTitle}); err != nil {
			return nil, hostFailureOf(err)
		}
		return marshalResult(map[string]bool{"opened": true})
	case "views/refresh":
		if !s.refreshView(caller, workspace.ContextID, p.Instance) {
			return nil, failure(CodeNotFound, "The view instance is no longer open.")
		}
		return marshalResult(map[string]bool{"refreshed": true})
	case "clipboard/readText":
		text, err := host.ReadClipboard(ctx)
		if err != nil {
			return nil, hostFailureOf(err)
		}
		if len(text) > prepared.Limits.TextBytes {
			return nil, failure(CodeLimitExceeded, "Clipboard text exceeds the transfer budget.")
		}
		return marshalResult(map[string]string{"text": text})
	case "clipboard/writeText":
		if err := host.WriteClipboard(ctx, p.Text); err != nil {
			return nil, hostFailureOf(err)
		}
		return nil, nil
	case "workspace/reveal":
		path, err := s.resolveResource(caller.PluginID, workspace, *p.Resource)
		if err != nil {
			return nil, hostFailureOf(err)
		}
		if _, err := os.Stat(path); err != nil {
			return nil, hostFailureOf(err)
		}
		if err := host.RevealResource(ctx, path); err != nil {
			return nil, hostFailureOf(err)
		}
		return nil, nil
	case "network/request":
		return managedRequest(ctx, p, s.workflow.httpTransport(prepared.Limits.HTTPHeaderBytes))
	default:
		return s.workflowResourceRequest(ctx, host, kernel, caller, workspace, p, method, prepared.Limits.Resources)
	}
}

// managedRequest inherits the application's proxy and platform certificate roots.
// Redirects remain responses so credentials never travel to a different origin.
func managedRequest(ctx context.Context, p workflowParams, transport *http.Transport) (json.RawMessage, *pluginhost.Failure) {
	ctx, cancel := context.WithTimeout(ctx, time.Duration(p.TimeoutMilliseconds)*time.Millisecond)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, p.Method, p.URL, strings.NewReader(p.Body))
	if err != nil {
		return nil, failure(codeInvalidParams, "The HTTP request could not be created.")
	}
	for key, value := range p.Headers {
		request.Header.Set(key, value)
	}
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, hostFailureOf(ctx.Err())
		}
		// net/http exposes no typed header-budget error. Match its fixed native
		// diagnostic only; the URL-wrapping error is never returned or logged.
		cause := err
		for errors.Unwrap(cause) != nil {
			cause = errors.Unwrap(cause)
		}
		if strings.HasPrefix(cause.Error(), "net/http: server response headers exceeded ") || cause.Error() == "http2: response header list larger than advertised limit" {
			return nil, failure(CodeLimitExceeded, "The HTTP response headers exceed their byte budget.")
		}
		return nil, failure(pluginhost.CodeHostFailure, "HTTP request failed: "+httpFailureReason(err)+".")
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, int64(p.MaximumResponseBytes)+1))
	if err != nil {
		if ctx.Err() != nil {
			return nil, hostFailureOf(ctx.Err())
		}
		return nil, failure(pluginhost.CodeHostFailure, "HTTP response read failed: "+httpFailureReason(err)+".")
	}
	if len(body) > p.MaximumResponseBytes {
		return nil, failure(CodeLimitExceeded, "The HTTP response exceeds its byte budget.")
	}
	encoding, text := "utf8", string(body)
	if !utf8.Valid(body) {
		encoding, text = "base64", base64.StdEncoding.EncodeToString(body)
	}
	return marshalResult(map[string]any{"status": response.StatusCode, "headers": response.Header, "body": text, "encoding": encoding})
}

// One transport shares native connections without sharing cookies or credentials.
// Closing the workspace closes its idle sockets; requests own cancellable leases.
func (r *workflowResources) httpTransport(headerBytes int) *http.Transport {
	r.httpMu.Lock()
	defer r.httpMu.Unlock()
	if r.transport == nil {
		r.transport = http.DefaultTransport.(*http.Transport).Clone()
		r.transport.MaxResponseHeaderBytes = int64(headerBytes)
	}
	return r.transport
}

// Transport errors can contain a full URL and its secret query. Classify native
// errors without copying their text into the RPC response or unified log.
func httpFailureReason(err error) string {
	var dns *net.DNSError
	var certificate *tls.CertificateVerificationError
	var unknown x509.UnknownAuthorityError
	var operation *net.OpError
	switch {
	case errors.As(err, &dns):
		return "dns_resolution"
	case errors.As(err, &certificate), errors.As(err, &unknown):
		return "tls_certificate"
	case errors.Is(err, io.ErrUnexpectedEOF):
		return "unexpected_eof"
	case errors.As(err, &operation):
		if operation.Timeout() {
			return "network_timeout"
		}
		if operation.Op == "dial" {
			return "connection_failed"
		}
		return "connection_io"
	default:
		return "http_protocol_or_response_headers"
	}
}

func (s *Service) workflowResourceRequest(ctx context.Context, host WorkflowHost, kernel workflowKernel, caller pluginhost.Caller, workspace WorkspaceContext, p workflowParams, method string, limit int) (json.RawMessage, *pluginhost.Failure) {
	kind, _, _ := strings.Cut(method, "/")
	if kind == "statusBar" {
		s.workflow.statusMu.Lock()
		defer s.workflow.statusMu.Unlock()
	}
	creating := method == "output/create" || method == "progress/create" || method == "statusBar/setItem"
	id := p.ChannelID
	if kind == "progress" {
		id = p.ProgressID
	}
	if kind == "statusBar" {
		id = caller.SessionID + ":" + workspace.ContextID + ":" + p.ID
	}
	s.workflow.mu.Lock()
	r := s.workflow.byID[id]
	fresh := creating && r == nil
	if fresh {
		lifetime, stop := context.WithCancel(context.WithoutCancel(ctx))
		r = &workflowResource{caller: caller, contextID: workspace.ContextID, root: workspace.Path, kind: kind, name: p.Name, lifetime: lifetime, stop: stop}
		// Hold the new resource until its identifiers are published. A concurrent
		// context/session close may already have taken its lease for disposal.
		r.mu.Lock()
		resource := r
		r.lease = s.resources.addLimited(caller, workspace.ContextID, func() { s.cleanupWorkflow(host, resource) }, limit)
		if r.lease == "" {
			stop()
			r.mu.Unlock()
			s.workflow.mu.Unlock()
			return nil, failure(CodeLimitExceeded, "Too many workflow resources.")
		}
		if kind != "statusBar" {
			id = r.lease
		}
		r.id = id
		s.workflow.byID[id] = r
	}
	s.workflow.mu.Unlock()
	if r == nil {
		return nil, failure(CodeNotFound, "The workflow resource is no longer available.")
	}
	if !fresh {
		r.mu.Lock()
	}
	defer r.mu.Unlock()
	if r.closed || r.caller != caller || r.contextID != workspace.ContextID || r.kind != kind {
		return nil, failure(CodeNotFound, "The workflow resource is not owned by this session and context.")
	}
	ctx, cancel := context.WithCancel(ctx)
	stopClosing := context.AfterFunc(r.lifetime, cancel)
	defer stopClosing()
	defer cancel()
	// A newly allocated handle must be removed even when validation or native
	// creation fails after registration. Disposal runs after r.mu is released.
	succeeded := !fresh
	defer func() {
		if !succeeded {
			r.stop()
			s.resources.forget(caller, r.lease)
		}
	}()
	if _, session, refusal := s.buildCaller(ctx); refusal != nil || session.isEnded() {
		if fresh {
			r.closed = true
			s.forgetWorkflow(r)
		}
		return nil, failure(pluginhost.CodeCancelled, "The requesting backend session ended.")
	}
	if _, _, refusal := s.workspaceRequest(ctx, p.Context); refusal != nil {
		if fresh {
			r.closed = true
			s.forgetWorkflow(r)
		}
		return nil, refusal
	}
	if err := ctx.Err(); err != nil {
		if fresh {
			r.closed = true
			s.forgetWorkflow(r)
		}
		return nil, hostFailureOf(err)
	}
	var err error
	switch method {
	case "output/create":
		err = host.UpdateOutput(ctx, r.root, OutputUpdate{ID: id, Name: p.Name, Action: "create"})
	case "output/append":
		var projection struct {
			Lines    []string `json:"lines"`
			Open     string   `json:"open"`
			MaxLines int      `json:"maxLines"`
			MaxBytes int      `json:"maxBytes"`
		}
		err = kernel.PluginWorkflow(ctx, map[string]any{"operation": "output", "open": r.open, "text": p.Text}, &projection)
		if err == nil {
			err = host.UpdateOutput(ctx, r.root, OutputUpdate{ID: id, Action: "append", Lines: projection.Lines, Open: projection.Open, MaxLines: projection.MaxLines, MaxBytes: projection.MaxBytes})
			if err == nil {
				r.open = projection.Open
			}
		}
	case "output/clear":
		err = host.UpdateOutput(ctx, r.root, OutputUpdate{ID: id, Action: "clear"})
		if err == nil {
			r.open = ""
		}
	case "output/show":
		err = host.UpdateOutput(ctx, r.root, OutputUpdate{ID: id, Action: "show"})
	case "progress/create", "progress/report":
		if r.cancelled {
			return nil, failure(pluginhost.CodeCancelled, "The user cancelled this operation.")
		}
		update := ProgressUpdate{ID: id, Title: p.Title, Percentage: p.Percentage, Cancellable: p.Cancellable, MessageSet: p.Message != nil}
		if p.Message != nil {
			update.Message = *p.Message
		}
		if method == "progress/create" && p.Cancellable {
			update.Cancel = func() { s.cancelWorkflowProgress(r) }
		}
		err = host.UpdateProgress(ctx, r.root, update)
	case "statusBar/setItem":
		s.workflow.mu.Lock()
		items := []map[string]any{}
		for _, item := range s.workflow.byID {
			if item.kind == "statusBar" && item.contextID == workspace.ContextID {
				priority := item.priority
				if item == r {
					priority = p.Priority
				}
				items = append(items, map[string]any{"id": item.id, "priority": priority})
			}
		}
		s.workflow.mu.Unlock()
		var projection struct {
			IDs []string `json:"ids"`
		}
		err = kernel.PluginWorkflow(ctx, map[string]any{"operation": "status", "items": items}, &projection)
		if err == nil {
			err = host.UpdateStatus(ctx, r.root, StatusUpdate{ID: id, PluginID: caller.PluginID, Text: p.Text, Tooltip: p.Tooltip, CommandID: p.CommandID, Priority: p.Priority, Order: projection.IDs})
		}
		if err == nil {
			s.workflow.mu.Lock()
			r.priority = p.Priority
			s.workflow.mu.Unlock()
		}
	case "output/dispose", "progress/end", "statusBar/removeItem":
		err = s.removeWorkflowUI(ctx, host, r)
		if err == nil {
			r.stop()
			r.closed = true
			s.forgetWorkflow(r)
			s.resources.forget(caller, r.lease)
		}
	}
	if err != nil {
		if fresh {
			r.closed = true
			s.forgetWorkflow(r)
			s.cleanupWorkflowUI(host, r)
		}
		return nil, hostFailureOf(err)
	}
	succeeded = true
	if creating {
		switch kind {
		case "output":
			return marshalResult(map[string]string{"channelID": id})
		case "progress":
			return marshalResult(map[string]string{"progressID": id, "subscriptionID": r.lease})
		default:
			return marshalResult(map[string]string{"id": p.ID})
		}
	}
	return nil, nil
}

func (s *Service) forgetWorkflow(r *workflowResource) {
	s.workflow.mu.Lock()
	delete(s.workflow.byID, r.id)
	s.workflow.mu.Unlock()
}

func (s *Service) removeWorkflowUI(ctx context.Context, host WorkflowHost, r *workflowResource) error {
	switch r.kind {
	case "output":
		return host.UpdateOutput(ctx, r.root, OutputUpdate{ID: r.id, Action: "dispose"})
	case "progress":
		return host.UpdateProgress(ctx, r.root, ProgressUpdate{ID: r.id, Remove: true})
	default:
		return host.UpdateStatus(ctx, r.root, StatusUpdate{ID: r.id, Remove: true})
	}
}
func (s *Service) cleanupWorkflowUI(host WorkflowHost, r *workflowResource) {
	host.ReleaseWorkflow(r.root, r.kind, r.id)
}
func (s *Service) cleanupWorkflow(host WorkflowHost, r *workflowResource) {
	// Cancel a native call before taking its lock: that call may be waiting for
	// the very window thread that is closing this context.
	r.stop()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.closed = true
	s.forgetWorkflow(r)
	s.cleanupWorkflowUI(host, r)
}

// Native UI invokes this on its owned project worker, never on the window thread.
func (s *Service) cancelWorkflowProgress(r *workflowResource) {
	r.mu.Lock()
	if r.closed || r.cancelled {
		r.mu.Unlock()
		return
	}
	r.cancelled = true
	r.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Core records delivery failures at the lsp.hostNotify boundary. A session
	// closing before delivery has no recipient and needs no retry.
	_, err := s.kernel.SendPluginHostNotification(ctx, r.caller.SessionID, notifySubscription, mustMarshal(map[string]any{"subscriptionID": r.lease, "sequence": 1, "event": map[string]bool{"cancelled": true}}))
	if err != nil { // log-exempt: 同一次失败已经记录过：Core records host notification delivery.
		return
	}
}

// workflowFailure keeps Core's public refusal when native preparation fails.
func workflowFailure(err error) *pluginhost.Failure {
	var coreErr *core.Error
	if errors.As(err, &coreErr) && coreErr.Code == core.CodeInvalidRequest {
		switch coreErr.Details {
		case codeInvalidParams, CodeUnsupportedOption:
			return failure(coreErr.Details, coreErr.Message)
		}
	}
	return hostFailureOf(err)
}
