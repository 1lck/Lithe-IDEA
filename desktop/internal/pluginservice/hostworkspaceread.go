package pluginservice

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

const (
	methodWorkspaceReadDirectory = pluginhost.MethodPrefix + "workspace/readDirectory"
	methodWorkspaceStat          = pluginhost.MethodPrefix + "workspace/stat"
	methodWorkspaceReadFile      = pluginhost.MethodPrefix + "workspace/readFile"
)

// WorkspaceReadHost bridges authorized workspace reads to Core off the UI thread.
// Core owns paths, no-follow traversal, visibility, pagination and byte limits.
type WorkspaceReadHost interface {
	ReadDirectory(context.Context, core.WorkspaceDirectoryRequest) (core.WorkspaceDirectoryPage, error)
	StatEntry(ctx context.Context, root, path string) (core.WorkspaceStat, error)
	ReadFile(ctx context.Context, root, path string, maximumBytes *int) (core.WorkspaceFileRead, error)
}

func (s *Service) registerWorkspaceReads(host WorkspaceReadHost) error {
	for _, method := range []string{methodWorkspaceReadDirectory, methodWorkspaceStat, methodWorkspaceReadFile} {
		if err := s.HostServices.Register(method, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleWorkspaceRead(ctx, host, method, params)
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) handleWorkspaceRead(ctx context.Context, host WorkspaceReadHost, method string, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	// The session's Core router already validated the method-specific fields.
	var request struct {
		Context      ContextRef `json:"context"`
		Resource     Resource   `json:"resource"`
		Cursor       *string    `json:"cursor"`
		Limit        *int       `json:"limit"`
		MaximumBytes *int       `json:"maximumBytes"`
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
	var result any
	switch method {
	case methodWorkspaceReadDirectory:
		page, err := host.ReadDirectory(ctx, core.WorkspaceDirectoryRequest{Root: workspace.Path, Path: request.Resource.Path, Cursor: request.Cursor, Limit: request.Limit})
		if err != nil {
			return nil, hostFailureOf(WorkspaceReadError(err))
		}
		type entry struct {
			Name     string   `json:"name"`
			Resource Resource `json:"resource"`
			Kind     string   `json:"kind"`
		}
		entries := make([]entry, 0, len(page.Entries))
		for _, child := range page.Entries {
			entries = append(entries, entry{child.Name, Resource{request.Resource.RootID, child.Path}, child.Kind})
		}
		result = struct {
			Entries    []entry `json:"entries"`
			NextCursor *string `json:"nextCursor"`
		}{entries, page.NextCursor}
	case methodWorkspaceStat:
		stat, err := host.StatEntry(ctx, workspace.Path, request.Resource.Path)
		if err != nil {
			return nil, hostFailureOf(WorkspaceReadError(err))
		}
		result = struct {
			Resource             Resource `json:"resource"`
			Kind                 string   `json:"kind"`
			Size                 uint64   `json:"size"`
			ModifiedMilliseconds *uint64  `json:"modifiedMilliseconds"`
		}{request.Resource, stat.Kind, stat.Size, stat.ModifiedMilliseconds}
	case methodWorkspaceReadFile:
		file, err := host.ReadFile(ctx, workspace.Path, request.Resource.Path, request.MaximumBytes)
		if err != nil {
			return nil, hostFailureOf(WorkspaceReadError(err))
		}
		result = struct {
			Resource    Resource                   `json:"resource"`
			Source      string                     `json:"source"`
			ByteCount   int                        `json:"byteCount"`
			IsTruncated bool                       `json:"isTruncated"`
			Identity    core.WorkspaceReadIdentity `json:"identity"`
			Text        *string                    `json:"text,omitempty"`
			Encoding    *string                    `json:"encoding,omitempty"`
			Base64      *string                    `json:"base64,omitempty"`
		}{request.Resource, file.Source, file.ByteCount, file.IsTruncated, file.Identity, file.Text, file.Encoding, file.Base64}
	}
	// A window may close or replace the context while Core reads. Never publish
	// the old request under a newly opened context with the same root.
	if _, err := s.Contexts.Lookup(request.Context); err != nil {
		return nil, contextFailure(err)
	}
	if err := ctx.Err(); err != nil {
		return nil, hostFailureOf(err)
	}
	return marshalResult(result)
}

// WorkspaceReadError maps Core failures without turning access failures into bad params.
func WorkspaceReadError(err error) error {
	var hostErr *HostError
	var coreErr *core.Error
	switch {
	case err == nil, errors.As(err, &hostErr), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return err
	case errors.As(err, &coreErr):
		code := CodeFailed
		switch coreErr.Code {
		case core.CodeEntryNotFound, core.CodeWorkspaceNotFound:
			code = CodeNotFound
		case core.CodeInvalidRequest, core.CodeParseFailed:
			code = codeInvalidParams
		case core.CodePermissionDenied:
			code = CodePermissionDenied
		case core.CodeNotSupported:
			code = codeAuthorityUnsupported
		}
		return &HostError{Code: code, Message: coreErr.Message}
	}
	return &HostError{Code: CodeFailed, Message: "The workspace read failed."}
}
