package pluginservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// HostError is a refusal a Workbench reports with one of the contract's host
// codes, so the handler can pass the code and details to the backend unchanged.
type HostError struct {
	Code    string
	Message string
	Details map[string]any
}

func (e *HostError) Error() string { return e.Code + ": " + e.Message }

// Host failure codes of protocol version 3 that the workbench reports.
const (
	CodeVersionConflict      = "plugin.host.versionConflict"
	CodeLimitExceeded        = "plugin.host.limitExceeded"
	CodeNotFound             = "plugin.host.notFound"
	CodeReadOnly             = "plugin.host.readOnly"
	CodePreconditionFailed   = "plugin.host.preconditionFailed"
	CodeBusy                 = "plugin.host.busy"
	CodeRateLimited          = "plugin.host.rateLimited"
	CodePermissionDenied     = "plugin.host.permissionDenied"
	CodeContextExpired       = "plugin.host.contextExpired"
	CodeUnsupportedOption    = "plugin.host.unsupportedOption"
	codeInvalidParams        = "plugin.host.invalidParams"
	codeAuthorityUnsupported = "plugin.host.authorityUnsupported"
)

// Position is a one-based line and one-based UTF-16 column, as the contract
// writes positions.
type Position struct {
	Line   int `json:"line"`
	Column int `json:"column"`
}

// Range is a half-open span between two positions.
type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}

// Selection is a direction-keeping selection.
type Selection struct {
	Anchor Position `json:"anchor"`
	Active Position `json:"active"`
}

// DocumentSummary is the public description of an open document.
type DocumentSummary struct {
	DocumentID string  `json:"documentID"`
	Version    int     `json:"version"`
	Path       *string `json:"path"`
	LanguageID *string `json:"languageID"`
	IsReadOnly bool    `json:"isReadOnly"`
	IsDirty    bool    `json:"isDirty"`
	Encoding   string  `json:"encoding"`
	LineEnding string  `json:"lineEnding"`
}

// SelectionsResult is the answer of editor/getSelections.
type SelectionsResult struct {
	DocumentID   string      `json:"documentID"`
	Version      int         `json:"version"`
	Selections   []Selection `json:"selections"`
	PrimaryIndex int         `json:"primaryIndex"`
}

// RangeEdit replaces a range.
type RangeEdit struct {
	Range Range
	Text  string
}

// EditRequest is one atomic batch against one document version.
type EditRequest struct {
	DocumentID      string
	ExpectedVersion int
	Edits           []RangeEdit
}

// EditResult is the document after an edit.
type EditResult struct {
	DocumentID string `json:"documentID"`
	Version    int    `json:"version"`
	Applied    bool   `json:"applied"`
}

// OpenRequest opens or reveals a file of the workspace.
type OpenRequest struct {
	// Path is the absolute, containment-checked path.
	Path string
	// Background opens the document without selecting its tab.
	Background bool
	// Caret is where the caret goes, or nil to leave it.
	Caret *Position
}

// OpenResult describes the document after an open.
type OpenResult struct {
	DocumentSummary
	WasAlreadyOpen     bool          `json:"wasAlreadyOpen"`
	WindowIsForeground bool          `json:"windowIsForeground"`
	AppliedSelection   *AppliedCaret `json:"appliedSelection"`
}

// AppliedCaret is the selection an open applied. Only a caret is applied: a
// range's start becomes the caret.
type AppliedCaret struct {
	Kind   string `json:"kind"`
	Line   int    `json:"line"`
	Column int    `json:"column"`
}

// PromptRequest asks the user something on behalf of a plugin.
type PromptRequest struct {
	PluginID string
	// Level is "information", "warning" or "error".
	Level   string
	Text    string
	Actions []string
}

// Workbench is what the window provides to the host services. Every method does
// its work on the window's thread and returns when it is done or ctx ends; none
// is called with a lock held. Errors that are not *HostError become a generic
// host failure.
type Workbench interface {
	// Documents lists the open text documents of the project at root.
	Documents(ctx context.Context, root string) ([]DocumentSummary, error)
	// Snapshot returns a document and its live text. A document longer than
	// maxBytes is refused with CodeLimitExceeded before its text is copied.
	Snapshot(ctx context.Context, root, documentID string, maxBytes int) (DocumentSummary, string, error)
	// Active is the foreground text document, or nil.
	Active(ctx context.Context, root string) (*DocumentSummary, error)
	Selections(ctx context.Context, root, documentID string) (SelectionsResult, error)
	// Edit applies the batch as one undo step when the version matches.
	Edit(ctx context.Context, root string, request EditRequest) (EditResult, error)
	Open(ctx context.Context, root string, request OpenRequest) (OpenResult, error)
	// Prompt shows a message and waits for the user's choice. The index is nil
	// when the message was dismissed.
	Prompt(ctx context.Context, request PromptRequest) (*int, error)
	// OpenExternal opens an http or https address in the system browser.
	OpenExternal(ctx context.Context, address string) error
}

// hostFailureOf converts a Workbench error into the failure the backend sees.
func hostFailureOf(err error) *pluginhost.Failure {
	var hostErr *HostError
	switch {
	case errors.As(err, &hostErr):
		return &pluginhost.Failure{Code: hostErr.Code, Message: hostErr.Message, Details: detailsOf(hostErr.Details)}
	case errors.Is(err, context.Canceled):
		return failure(pluginhost.CodeCancelled, "The request was cancelled.")
	case errors.Is(err, context.DeadlineExceeded):
		return failure("plugin.host.timeout", "The host's deadline passed.")
	}
	return failure(pluginhost.CodeHostFailure, err.Error())
}

// ErrResource reports a resource the host refuses to resolve.
var ErrResource = errors.New("invalid workspace resource")

// Resource names one file or directory below a root the plugin saw in getFolders.
type Resource struct {
	RootID string `json:"rootID"`
	Path   string `json:"path"`
}

// resolveResource turns a resource into an absolute path inside the context's
// workspace. The path is relative with "/" separators and has no "." or ".."
// component; the longest existing prefix is resolved through symlinks and must
// stay inside the root, so a link cannot lead out of it. The check and the later
// open are not atomic, which the contract documents.
func (s *Service) resolveResource(pluginID string, workspace WorkspaceContext, resource Resource) (string, error) {
	if resource.RootID == "" || resource.RootID != s.Contexts.RootID(pluginID, workspace.Path) {
		return "", fmt.Errorf("%w: unknown root", ErrResource)
	}
	rel := resource.Path
	if strings.ContainsAny(rel, "\\\x00") || strings.HasPrefix(rel, "/") || (len(rel) >= 2 && rel[1] == ':') {
		return "", fmt.Errorf("%w: the path must be relative with / separators", ErrResource)
	}
	var parts []string
	for _, part := range strings.Split(rel, "/") {
		switch part {
		case "":
			// An empty path is the root; a doubled slash is tolerated.
		case ".", "..":
			return "", fmt.Errorf("%w: the path has a %q component", ErrResource, part)
		default:
			parts = append(parts, part)
		}
	}
	root := filepath.Clean(workspace.Path)
	target := filepath.Join(append([]string{root}, parts...)...)
	canonicalRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	existing := target
	var rest []string
	for {
		if _, statErr := os.Lstat(existing); statErr == nil {
			break
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			return "", fmt.Errorf("%w: no existing parent", ErrResource)
		}
		rest = append([]string{filepath.Base(existing)}, rest...)
		existing = parent
	}
	canonical, err := filepath.EvalSymlinks(existing)
	if err != nil {
		return "", err
	}
	if canonical != canonicalRoot && !strings.HasPrefix(canonical, canonicalRoot+string(filepath.Separator)) {
		return "", fmt.Errorf("%w: the path leaves the workspace", ErrResource)
	}
	_ = rest
	return target, nil
}

// relativePath is the workspace-relative form of a document's absolute path, or
// nil for a document outside the root.
func relativePath(root, path string) *string {
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return nil
	}
	rel = filepath.ToSlash(rel)
	return &rel
}

// RelativePath is exported for Workbench implementations.
func RelativePath(root, path string) *string { return relativePath(root, path) }

// httpURL validates the URL browser/openExternal opens: absolute, http or https,
// with a host and no embedded credentials.
func httpURL(raw string) (string, error) {
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" || parsed.User != nil || len(raw) > 4096 {
		return "", fmt.Errorf("%w: only http and https addresses open", ErrResource)
	}
	return parsed.String(), nil
}

// detailsOf encodes failure details; details are optional, so an encoding
// problem drops them rather than the failure.
func detailsOf(details map[string]any) json.RawMessage {
	if len(details) == 0 {
		return nil
	}
	data, err := json.Marshal(details)
	if err != nil {
		return nil
	}
	return data
}
