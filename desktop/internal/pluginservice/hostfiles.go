package pluginservice

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

type workspaceFileParams struct {
	Context           ContextRef      `json:"context"`
	Resource          json.RawMessage `json:"resource"`
	Cursor            *string         `json:"cursor"`
	Limit             *int64          `json:"limit"`
	MaximumBytes      *int64          `json:"maximumBytes"`
	Query             *string         `json:"query"`
	Pattern           *string         `json:"pattern"`
	FileMask          *string         `json:"fileMask"`
	CaseSensitive     *bool           `json:"caseSensitive"`
	WholeWords        *bool           `json:"wholeWords"`
	RegularExpression *bool           `json:"regularExpression"`
}

type pluginWorkspaceResource struct {
	RootID string  `json:"rootID"`
	Path   *string `json:"path"`
}

func (s *Service) remoteFileResource(ctx context.Context, ref ContextRef, raw json.RawMessage) (pluginhost.Caller, WorkspaceContext, pluginWorkspaceResource, *core.RemoteWorkspaceConnection, *pluginhost.Failure) {
	var resource pluginWorkspaceResource
	if err := decodeStrict(raw, &resource); err != nil {
		return pluginhost.Caller{}, WorkspaceContext{}, resource, nil, invalidParams(err)
	}
	caller, workspace, refusal := s.workspaceRequest(ctx, ref)
	if refusal != nil {
		return caller, workspace, resource, nil, refusal
	}
	if resource.Path == nil || resource.RootID == "" ||
		resource.RootID != s.Contexts.RootID(caller.PluginID, workspace.Path) {
		return caller, workspace, resource, nil, failure("plugin.host.invalidParams", "Expected a resource in the caller's workspace folder.")
	}
	binding := workspace.remote.binding
	if binding == nil {
		return caller, workspace, resource, nil, failure(codeAuthorityUnsupported, "This file service requires a remote workspace.")
	}
	connection := binding.CaptureConnection()
	if connection == nil {
		return caller, workspace, resource, nil, failure("plugin.host.remoteDisconnected", "The remote workspace is disconnected.")
	}
	return caller, workspace, resource, connection, nil
}

func (s *Service) workspaceFileHandler(kind string, options ...string) pluginhost.Handler {
	allowed := append([]string{"context", "resource"}, options...)
	return func(ctx context.Context, raw json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
		var request workspaceFileParams
		if err := decodeStrictEmbedded(raw, &request, allowed...); err != nil {
			return nil, invalidParams(err)
		}
		_, workspace, resource, connection, refusal := s.remoteFileResource(ctx, request.Context, request.Resource)
		if refusal != nil {
			return nil, refusal
		}
		return s.readRemotePluginFile(ctx, workspace, connection, resource, core.PluginFileOperation{
			Kind: kind, Cursor: request.Cursor, Limit: request.Limit, MaximumBytes: request.MaximumBytes,
			Query: request.Query, Pattern: request.Pattern, FileMask: request.FileMask,
			CaseSensitive: request.CaseSensitive, WholeWords: request.WholeWords, RegularExpression: request.RegularExpression,
		})
	}
}

func (s *Service) readRemotePluginFile(ctx context.Context, workspace WorkspaceContext, connection *core.RemoteWorkspaceConnection, resource pluginWorkspaceResource, operation core.PluginFileOperation) (json.RawMessage, *pluginhost.Failure) {
	result, err := s.kernel.ReadPluginFile(connection.Context(ctx), core.PluginFileRequest{
		RootID:     resource.RootID,
		Generation: workspace.Generation,
		Attachment: connection.Revision(),
		Path:       *resource.Path,
		Operation:  operation,
	})
	if _, lookupErr := s.Contexts.Lookup(workspace.ContextRef); lookupErr != nil {
		return nil, contextFailure(lookupErr)
	}
	if ctx.Err() != nil {
		return nil, hostFailureOf(ctx.Err())
	}
	if !connection.IsCurrent() {
		return nil, failure("plugin.host.remoteDisconnected", "The remote workspace connection changed.")
	}
	if err != nil {
		return nil, pluginFileFailure(err)
	}
	return result, nil
}

func pluginFileFailure(err error) *pluginhost.Failure {
	var detail *core.Error
	if !errors.As(err, &detail) {
		return hostFailureOf(err)
	}
	switch detail.Code {
	case core.CodeInvalidRequest:
		return failure("plugin.host.invalidParams", detail.Message)
	case core.CodeWorkspaceNotFound:
		return failure("plugin.host.notFound", "The workspace resource does not exist.")
	case core.CodePermissionDenied:
		return failure("plugin.host.permissionDenied", "The workspace host refused access to the resource.")
	case core.CodeConnectionClosed:
		return failure("plugin.host.remoteDisconnected", "The remote workspace is disconnected.")
	case core.CodeProcessFailed:
		var host struct {
			RemoteCode string `json:"remoteCode"`
		}
		if json.Unmarshal([]byte(detail.Details), &host) == nil {
			switch host.RemoteCode {
			case "TOO_LARGE":
				return failure("plugin.host.limitExceeded", detail.Message)
			case "BUSY":
				return failure("plugin.host.busy", detail.Message)
			case "NOT_A_DIRECTORY", "IS_A_DIRECTORY", "INVALID_PATH", "INVALID_REQUEST":
				return failure("plugin.host.invalidParams", detail.Message)
			case "UNKNOWN_METHOD", "UNSUPPORTED":
				return failure(codeAuthorityUnsupported, "The remote host does not offer this file service.")
			}
		}
	}
	return hostFailureOf(err)
}
