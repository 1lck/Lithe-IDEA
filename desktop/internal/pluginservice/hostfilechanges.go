package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// The save and file-change methods of API-11. documents.save grants the first three and
// workspace.files.write the other four. Core checked the permission and the params before the
// request came: every path has one spelling below its root, a move stays in one root, the fields
// match the kind and text is at most 128 KiB. The handlers check that the root is the caller's
// and hand the request to the window, which asks Core to make the change and keeps the open
// documents, the project tree and the system trash (FileChangeHost). None of them asks the user
// anything: a change that would need the user's choice is refused with a code instead.
const (
	methodDocumentsSave   = pluginhost.MethodPrefix + "documents/save"
	methodDocumentsSaveAs = pluginhost.MethodPrefix + "documents/saveAs"
	methodDocumentsClose  = pluginhost.MethodPrefix + "documents/close"
	methodWorkspaceCreate = pluginhost.MethodPrefix + "workspace/create"
	methodWorkspaceRename = pluginhost.MethodPrefix + "workspace/rename"
	methodWorkspaceCopy   = pluginhost.MethodPrefix + "workspace/copy"
	methodWorkspaceTrash  = pluginhost.MethodPrefix + "workspace/trash"
)

// EntryCreation is one entry workspace/create makes. Path is "/"-separated below the root; Kind
// is "file", "directory" or "symlink"; only a file takes Text and only a link takes LinkTarget.
type EntryCreation struct {
	Path       string
	Kind       string
	Text       *string
	LinkTarget *string
}

// FileChangeHost is a window that saves documents and changes files for plugins. root is the
// workspace's local folder; every other path is "/"-separated below it, as the plugin named it,
// and Core resolves it. An error is a *HostError with the contract's code, or the request's
// context error.
type FileChangeHost interface {
	// SaveDocument writes the document's current text through the document's own save and
	// returns its summary afterwards. expectedVersion, when set, must be the current version.
	SaveDocument(ctx context.Context, root, id string, expectedVersion *int) (DocumentSummary, error)
	// SaveDocumentAs writes the document's text as UTF-8 to target, which must not exist, and
	// opens and selects the new file.
	SaveDocumentAs(ctx context.Context, root, id, target string) (DocumentSummary, error)
	// CloseDocument saves the document, checks the disk and closes its tab.
	CloseDocument(ctx context.Context, root, id string) error
	// CreateEntry makes a file with text, a directory or a symbolic link, which must not exist.
	CreateEntry(ctx context.Context, root string, entry EntryCreation) error
	// RenameEntry saves the open documents under from, then moves from to to.
	RenameEntry(ctx context.Context, root, from, to string) error
	// CopyEntry copies from to to, which must not exist.
	CopyEntry(ctx context.Context, root, from, to string) error
	// TrashEntry saves and closes the open documents under path, then moves path to the
	// system trash.
	TrashEntry(ctx context.Context, root, path string) error
}

// The codes API-11 added, and the general failure of a change the system refused.
const (
	CodeAlreadyExists = "plugin.host.alreadyExists"
	CodeDiskChanged   = "plugin.host.diskChanged"
	CodeFailed        = "plugin.host.failed"
)

func (s *Service) registerFileChanges(host FileChangeHost) error {
	for _, entry := range []struct {
		method  string
		handler pluginhost.Handler
	}{
		{methodDocumentsSave, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleDocumentsSave(ctx, host, params)
		}},
		{methodDocumentsSaveAs, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleDocumentsSaveAs(ctx, host, params)
		}},
		{methodDocumentsClose, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleDocumentsClose(ctx, host, params)
		}},
		{methodWorkspaceCreate, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleWorkspaceCreate(ctx, host, params)
		}},
		{methodWorkspaceRename, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleWorkspaceMove(ctx, params, host.RenameEntry)
		}},
		{methodWorkspaceCopy, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleWorkspaceMove(ctx, params, host.CopyEntry)
		}},
		{methodWorkspaceTrash, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleWorkspaceTrash(ctx, host, params)
		}},
	} {
		if err := s.HostServices.Register(entry.method, entry.handler); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) handleDocumentsSave(ctx context.Context, host FileChangeHost, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context         ContextRef `json:"context"`
		DocumentID      string     `json:"documentID"`
		ExpectedVersion *int       `json:"expectedVersion"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	_, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	document, err := host.SaveDocument(ctx, workspace.Path, request.DocumentID, request.ExpectedVersion)
	if err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(map[string]any{"document": document})
}

func (s *Service) handleDocumentsSaveAs(ctx context.Context, host FileChangeHost, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context    ContextRef `json:"context"`
		DocumentID string     `json:"documentID"`
		Target     Resource   `json:"target"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if refusal := s.checkRoot(caller.PluginID, workspace, request.Target); refusal != nil {
		return nil, refusal
	}
	document, err := host.SaveDocumentAs(ctx, workspace.Path, request.DocumentID, request.Target.Path)
	if err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(map[string]any{"document": document})
}

func (s *Service) handleDocumentsClose(ctx context.Context, host FileChangeHost, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	request, refusal := decodeDocumentParams(params)
	if refusal != nil {
		return nil, refusal
	}
	_, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if err := host.CloseDocument(ctx, workspace.Path, request.DocumentID); err != nil {
		return nil, hostFailureOf(err)
	}
	return json.RawMessage("null"), nil
}

func (s *Service) handleWorkspaceCreate(ctx context.Context, host FileChangeHost, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context    ContextRef `json:"context"`
		Resource   Resource   `json:"resource"`
		Kind       string     `json:"kind"`
		Text       *string    `json:"text"`
		LinkTarget *string    `json:"linkTarget"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if refusal := s.checkRoot(caller.PluginID, workspace, request.Resource); refusal != nil {
		return nil, refusal
	}
	creation := EntryCreation{Path: request.Resource.Path, Kind: request.Kind, Text: request.Text, LinkTarget: request.LinkTarget}
	if err := host.CreateEntry(ctx, workspace.Path, creation); err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(map[string]any{"resource": request.Resource, "kind": request.Kind})
}

// handleWorkspaceMove serves rename and copy, which take the same params.
func (s *Service) handleWorkspaceMove(ctx context.Context, params json.RawMessage, change func(context.Context, string, string, string) error) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context  ContextRef `json:"context"`
		Resource Resource   `json:"resource"`
		Target   Resource   `json:"target"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	for _, resource := range []Resource{request.Resource, request.Target} {
		if refusal := s.checkRoot(caller.PluginID, workspace, resource); refusal != nil {
			return nil, refusal
		}
	}
	if err := change(ctx, workspace.Path, request.Resource.Path, request.Target.Path); err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(map[string]any{"resource": request.Target})
}

func (s *Service) handleWorkspaceTrash(ctx context.Context, host FileChangeHost, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context  ContextRef `json:"context"`
		Resource Resource   `json:"resource"`
	}
	if err := decodeStrict(params, &request); err != nil {
		return nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, request.Context)
	if refusal != nil {
		return nil, refusal
	}
	if refusal := s.checkRoot(caller.PluginID, workspace, request.Resource); refusal != nil {
		return nil, refusal
	}
	if err := host.TrashEntry(ctx, workspace.Path, request.Resource.Path); err != nil {
		return nil, hostFailureOf(err)
	}
	return json.RawMessage("null"), nil
}

// checkRoot refuses a resource whose root is not the one this plugin was given for the workspace.
// The path itself is Core's to check.
func (s *Service) checkRoot(pluginID string, workspace WorkspaceContext, resource Resource) *pluginhost.Failure {
	if resource.RootID == "" || resource.RootID != s.Contexts.RootID(pluginID, workspace.Path) {
		return failure(codeInvalidParams, "The resource is not in a root of the workspace.")
	}
	return nil
}

// ChangeError is the contract's error for a file change Core refused or the system failed. A
// HostError and a context error pass unchanged.
func ChangeError(err error) error {
	var hostErr *HostError
	var coreErr *core.Error
	switch {
	case err == nil:
		return nil
	case errors.As(err, &hostErr), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return err
	case errors.As(err, &coreErr):
		switch coreErr.Code {
		case core.CodeEntryExists:
			return &HostError{Code: CodeAlreadyExists, Message: "The target exists."}
		case core.CodeEntryNotFound:
			return &HostError{Code: CodeNotFound, Message: "The resource or the directory that would hold it does not exist."}
		case core.CodeInvalidRequest:
			return &HostError{Code: codeInvalidParams, Message: coreErr.Message + "."}
		case core.CodePermissionDenied:
			// The directory holding the entry resolves outside the root, which editor/open also
			// refuses as invalid params.
			return &HostError{Code: codeInvalidParams, Message: "The resource is not a path inside the workspace."}
		}
	}
	return &HostError{Code: CodeFailed, Message: fmt.Sprintf("The change failed: %v", err)}
}
