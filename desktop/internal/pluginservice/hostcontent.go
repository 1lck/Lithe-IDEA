package pluginservice

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// Content providers: a plugin whose server hands out documents that have no file
// (the decompiled source of a library class) serves them as a URI scheme. The
// binding is recorded without calling the backend; the backend is asked only when
// a document of that scheme is opened, and the answer is shown read-only.
const (
	methodRegisterContentProvider = pluginhost.MethodPrefix + "documents/registerContentProvider"

	// contentProviderTimeout is how long the host waits for a provider.
	contentProviderTimeout = 30 * time.Second
	// maxContentBytes is Core's limit on a provider's answer.
	maxContentBytes = 1024 * 1024
)

// reservedSchemes are the schemes the host or the platform resolves itself.
var reservedSchemes = map[string]bool{
	"about": true, "blob": true, "data": true, "file": true, "ftp": true, "http": true, "https": true,
	"javascript": true, "lithe": true, "mailto": true, "untitled": true, "ws": true, "wss": true,
}

// VirtualDocument is a read-only document without a file.
type VirtualDocument struct {
	URI string
	// Name is the tab's title.
	Name string
	Text string
	// Line and Column are the zero-based UTF-16 caret the document opens at.
	Line, Column int
}

// VirtualDocumentHost shows provider text in a read-only editor tab. The window
// implements it next to Workbench; a host without it does not register providers.
type VirtualDocumentHost interface {
	OpenVirtualDocument(ctx context.Context, root string, document VirtualDocument) error
}

type contentProvider struct {
	pluginID  string
	sessionID string
	function  string
}

// contentProviders holds the bindings by workspace context and scheme.
type contentProviders struct {
	mu     sync.Mutex
	byName map[string]*contentProvider
}

func providerKey(contextID, scheme string) string { return contextID + "\x00" + scheme }

func (s *Service) registerContentProviders(host VirtualDocumentHost) error {
	s.virtualHost = host
	s.providers = &contentProviders{byName: make(map[string]*contentProvider)}
	return s.HostServices.Register(methodRegisterContentProvider, s.handleRegisterContentProvider)
}

// validScheme is a URI scheme: a letter, then letters, digits, "+", "-" or ".", at
// most 64 characters, lowercase.
func validScheme(scheme string) bool {
	if scheme == "" || len(scheme) > 64 {
		return false
	}
	for i := 0; i < len(scheme); i++ {
		c := scheme[i]
		switch {
		case c >= 'a' && c <= 'z':
		case i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'):
		default:
			return false
		}
	}
	return true
}

// validFunctionID is a plugin function ID: the contract's key alphabet plus "." and "/".
func validFunctionID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '.' || c == '_' || c == ':' || c == '-' || c == '/':
		default:
			return false
		}
	}
	return true
}

func (s *Service) handleRegisterContentProvider(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context  ContextRef `json:"context"`
		Scheme   string     `json:"scheme"`
		Function string     `json:"function"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if !validScheme(request.Scheme) || reservedSchemes[request.Scheme] || !validFunctionID(request.Function) {
		return nil, failure(codeInvalidParams, "The scheme is malformed or reserved, or the function is not a function ID.")
	}
	session := s.Host.Running(caller.PluginID)
	if session == nil || session.Session.ID != caller.SessionID || !session.hasFunction(request.Function) {
		return nil, failure(CodePreconditionFailed, "The function is not registered on this session.")
	}
	key := providerKey(workspace.ContextID, request.Scheme)
	s.providers.mu.Lock()
	if _, taken := s.providers.byName[key]; taken {
		s.providers.mu.Unlock()
		return nil, failure(CodePreconditionFailed, "The scheme already has a provider in this window.")
	}
	binding := &contentProvider{pluginID: caller.PluginID, sessionID: caller.SessionID, function: request.Function}
	s.providers.byName[key] = binding
	s.providers.mu.Unlock()
	id := s.resources.add(caller, workspace.ContextID, func() {
		s.providers.mu.Lock()
		if s.providers.byName[key] == binding {
			delete(s.providers.byName, key)
		}
		s.providers.mu.Unlock()
	})
	return marshalResult(map[string]string{"subscriptionID": id})
}

// HasContentProvider reports whether a document URI names a scheme a plugin
// serves in the workspace, so the editor can offer it as a navigation target.
func (s *Service) HasContentProvider(root, uri string) bool {
	if s == nil || s.providers == nil {
		return false
	}
	workspace, ok := s.Contexts.ByPath(root)
	if !ok {
		return false
	}
	scheme, _, found := strings.Cut(uri, ":")
	if !found {
		return false
	}
	s.providers.mu.Lock()
	defer s.providers.mu.Unlock()
	_, bound := s.providers.byName[providerKey(workspace.ContextID, strings.ToLower(scheme))]
	return bound
}

// contentDecoder is the part of Core that checks a provider's answer.
type contentDecoder interface {
	DecodePluginContent(ctx context.Context, result json.RawMessage) (string, error)
}

// ErrNoContentProvider reports a URI no provider serves.
var ErrNoContentProvider = errors.New("no content provider serves this URI")

// OpenContentURI asks the provider of the URI's scheme for the document and shows
// it read-only at a zero-based position. Any failure, malformed answer or timeout
// returns an error and opens nothing.
func (s *Service) OpenContentURI(ctx context.Context, root, uri string, line, column int) error {
	if s == nil || s.providers == nil || s.virtualHost == nil {
		return ErrNoContentProvider
	}
	workspace, ok := s.Contexts.ByPath(root)
	if !ok {
		return ErrNoContentProvider
	}
	parsed, err := url.Parse(uri)
	if err != nil || parsed.Scheme == "" {
		return fmt.Errorf("%w: %q is not a URI", ErrNoContentProvider, uri)
	}
	s.providers.mu.Lock()
	binding := s.providers.byName[providerKey(workspace.ContextID, strings.ToLower(parsed.Scheme))]
	s.providers.mu.Unlock()
	if binding == nil {
		return ErrNoContentProvider
	}
	session := s.Host.Running(binding.pluginID)
	if session == nil || session.Session.ID != binding.sessionID {
		return ErrBackendUnavailable
	}
	reference, _ := json.Marshal(workspace.ContextRef)
	argument, _ := json.Marshal(map[string]string{"uri": uri})
	answer, err := session.Call(ctx, binding.function, argument, reference, contentProviderTimeout)
	if err != nil {
		return err
	}
	text, err := s.decodeContent(ctx, answer)
	if err != nil {
		return err
	}
	name := parsed.Path
	if i := strings.LastIndexAny(name, "/!"); i >= 0 {
		name = name[i+1:]
	}
	if name == "" {
		name = uri
	}
	return s.virtualHost.OpenVirtualDocument(ctx, root, VirtualDocument{URI: uri, Name: name, Text: text, Line: line, Column: column})
}

// decodeContent has Core check the answer; a kernel without that command applies
// the same rule here.
func (s *Service) decodeContent(ctx context.Context, answer json.RawMessage) (string, error) {
	if decoder, ok := s.kernel.(contentDecoder); ok {
		return decoder.DecodePluginContent(ctx, answer)
	}
	var text string
	if trimmed := bytes.TrimSpace(answer); len(trimmed) == 0 || (trimmed[0] != '"' && trimmed[0] != '{') {
		return "", errors.New("the content provider must answer a string or an object with only `content`")
	}
	if json.Unmarshal(answer, &text) != nil {
		var wrapped map[string]json.RawMessage
		if json.Unmarshal(answer, &wrapped) != nil || len(wrapped) != 1 || json.Unmarshal(wrapped["content"], &text) != nil {
			return "", errors.New("the content provider must answer a string or an object with only `content`")
		}
	}
	if len(text) > maxContentBytes {
		return "", errors.New("the content provider answered more than 1 MiB")
	}
	return text, nil
}
