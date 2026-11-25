package pluginservice

import (
	"context"
	"encoding/json"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

const (
	methodWorkspaceFindFiles = pluginhost.MethodPrefix + "workspace/findFiles"
	methodWorkspaceFindText  = pluginhost.MethodPrefix + "workspace/findText"
)

// WorkspaceFindHost executes Core's bounded disk searches outside the UI thread.
type WorkspaceFindHost interface {
	FindFiles(context.Context, core.WorkspaceFindRequest) (core.WorkspaceFindPage, error)
	FindText(context.Context, core.WorkspaceFindRequest) (core.WorkspaceFindPage, error)
}

func (s *Service) registerWorkspaceFind(host WorkspaceFindHost) error {
	for _, method := range []string{methodWorkspaceFindFiles, methodWorkspaceFindText} {
		if err := s.HostServices.Register(method, func(ctx context.Context, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
			return s.handleWorkspaceFind(ctx, host, method, params)
		}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) handleWorkspaceFind(ctx context.Context, host WorkspaceFindHost, method string, params json.RawMessage) (json.RawMessage, *pluginhost.Failure) {
	var request struct {
		Context           ContextRef `json:"context"`
		Resource          Resource   `json:"resource"`
		Query             string     `json:"query"`
		Pattern           string     `json:"pattern"`
		FileMask          string     `json:"fileMask"`
		CaseSensitive     bool       `json:"caseSensitive"`
		WholeWords        bool       `json:"wholeWords"`
		RegularExpression bool       `json:"regularExpression"`
		Cursor            *string    `json:"cursor"`
		Limit             *int       `json:"limit"`
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
	query := core.WorkspaceFindRequest{
		Root: workspace.Path, Query: request.Query, Pattern: request.Pattern, FileMask: request.FileMask,
		CaseSensitive: request.CaseSensitive, WholeWords: request.WholeWords, RegularExpression: request.RegularExpression,
		Cursor: request.Cursor, Limit: request.Limit,
	}
	var page core.WorkspaceFindPage
	var err error
	if method == methodWorkspaceFindFiles {
		page, err = host.FindFiles(ctx, query)
	} else {
		page, err = host.FindText(ctx, query)
	}
	if err != nil {
		return nil, hostFailureOf(WorkspaceReadError(err))
	}
	if _, err := s.Contexts.Lookup(request.Context); err != nil {
		return nil, contextFailure(err)
	}
	if err := ctx.Err(); err != nil {
		return nil, hostFailureOf(err)
	}
	matches := make([]any, 0, len(page.Matches))
	for _, hit := range page.Matches {
		resource := Resource{request.Resource.RootID, hit.Path}
		if method == methodWorkspaceFindFiles {
			matches = append(matches, resource)
		} else {
			matches = append(matches, struct {
				Resource Resource `json:"resource"`
				Line     *int     `json:"line"`
				Preview  string   `json:"preview"`
				Range    *Range   `json:"range"`
			}{resource, hit.Line, hit.Preview, nil})
		}
	}
	return marshalResult(struct {
		Matches     []any   `json:"matches"`
		NextCursor  *string `json:"nextCursor"`
		IsTruncated bool    `json:"isTruncated"`
		Source      string  `json:"source"`
	}{matches, page.NextCursor, page.IsTruncated, page.Source})
}
