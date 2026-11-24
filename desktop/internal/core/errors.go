package core

import (
	"context"
	"errors"
	"fmt"
)

// ErrorCode is the kernel's stable failure category. The values are the snake_case names of
// the Rust ErrorCode enum in rust/crates/protocol/src/error.rs of Lithe-IDEA/Lithe-core-rust;
// a code this package does not know (from a newer kernel) is still delivered as is.
type ErrorCode string

const (
	// CodeInvalidRequest means the envelope, payload, path or operation name is invalid.
	CodeInvalidRequest ErrorCode = "invalid_request"
	// CodeWorkspaceNotFound means the workspace or repository root does not exist.
	CodeWorkspaceNotFound ErrorCode = "workspace_not_found"
	// CodePermissionDenied means the operation would escape an allowed root or lacks access.
	CodePermissionDenied ErrorCode = "permission_denied"
	// CodeNotSupported means the request is valid but this kernel build cannot serve it. The
	// kernel also answers an unknown command name with this code.
	CodeNotSupported ErrorCode = "not_supported"
	// CodeRuntimeMissing means a required executable or runtime is unavailable.
	CodeRuntimeMissing ErrorCode = "runtime_missing"
	// CodeProcessStartFailed means a required child process could not be created.
	CodeProcessStartFailed ErrorCode = "process_start_failed"
	// CodeProcessFailed means a child process started but failed while serving the request.
	CodeProcessFailed ErrorCode = "process_failed"
	// CodeGitBranchExists means a reviewed checkout would conflict with a local reference.
	CodeGitBranchExists ErrorCode = "git_branch_exists"
	// CodeGitBranchNotMerged means ordinary deletion needs an explicit forced confirmation.
	CodeGitBranchNotMerged ErrorCode = "git_branch_not_merged"
	// CodeGitBranchChanged means the branch moved after its deletion was reviewed.
	CodeGitBranchChanged ErrorCode = "git_branch_changed"
	// CodeGitCheckoutChanged means a reviewed checkout no longer matches the repository.
	CodeGitCheckoutChanged ErrorCode = "git_checkout_changed"
	// CodeGitAuthenticationFailed means a git.write operation failed because the remote
	// refused or lacked credentials.
	CodeGitAuthenticationFailed ErrorCode = "git_authentication_failed"
	// CodeGitWorktreeNotRegistered means a worktree removal, lock or unlock named a path that
	// is not a registered worktree of the repository: the caller's list is out of date.
	CodeGitWorktreeNotRegistered ErrorCode = "git_worktree_not_registered"
	// CodeGitWorktreePrimary means a worktree removal, lock or unlock named the repository's
	// primary worktree, which Git can neither remove, lock nor unlock.
	CodeGitWorktreePrimary ErrorCode = "git_worktree_primary"
	// CodeGitWorktreeCurrent means a removal named the worktree the request was made from.
	CodeGitWorktreeCurrent ErrorCode = "git_worktree_current"
	// CodeGitWorktreeLocked means a removal named a locked worktree; unlocking it first
	// allows the removal.
	CodeGitWorktreeLocked ErrorCode = "git_worktree_locked"
	// CodeGitWorktreeHasChanges means Git refused a removal without force because the
	// checkout has modified or untracked files, which a forced removal deletes.
	CodeGitWorktreeHasChanges ErrorCode = "git_worktree_has_changes"
	// CodeGitCommitAuthorInvalid means a commit named an author that is not exactly
	// "Name <email>"; nothing was committed.
	CodeGitCommitAuthorInvalid ErrorCode = "git_commit_author_invalid"
	// CodeGitUntrustedWorkspace means the request belongs to a workspace the user has not trusted
	// (WithProjectCodeAllowed), so Core started no Git process: the repository's own configuration
	// can name programs Git runs, such as core.fsmonitor and hooks.
	CodeGitUntrustedWorkspace ErrorCode = "git_untrusted_workspace"
	// CodeParseFailed means input or tool output could not be decoded into the stable
	// contract. This package also uses it for a response it cannot decode.
	CodeParseFailed ErrorCode = "parse_failed"
	// CodeCancelled means the request was cancelled cooperatively.
	CodeCancelled ErrorCode = "cancelled"
	// CodeTimedOut means the request exceeded its deadline.
	CodeTimedOut ErrorCode = "timed_out"
	// CodeConnectionClosed means a long-lived connection named by the request is closed.
	CodeConnectionClosed ErrorCode = "connection_closed"
	// CodeForwardTargetNotConfirmed means remote.startForward named a target outside the host's
	// loopback interface the user did not confirm (S28); nothing was forwarded.
	CodeForwardTargetNotConfirmed ErrorCode = "forward_target_not_confirmed"
	// CodeForwardLimitReached means the session already runs as many forwards as Core allows;
	// details carry the maximum.
	CodeForwardLimitReached ErrorCode = "forward_limit_reached"
	// CodeForwardHostPortInUse means the host port a host or reverse forward asked for is used by
	// another program of the host; unlike a local port it is never replaced by another one.
	CodeForwardHostPortInUse ErrorCode = "forward_host_port_in_use"
	// CodeForwardHostPortDenied means the host refused to listen on the port, such as a port
	// below 1024 for an unprivileged user.
	CodeForwardHostPortDenied ErrorCode = "forward_host_port_denied"
	// CodeForwardHostUnsupported means the remote server cannot listen on host ports.
	CodeForwardHostUnsupported ErrorCode = "forward_host_unsupported"
	// CodeReverseForwardDisabled means the remote preferences do not allow reverse forwards.
	CodeReverseForwardDisabled ErrorCode = "reverse_forward_disabled"
	// CodeRemoteServerInvalid means the remote server build for the host's platform could not be
	// read, or its SHA-256 is not the one the application's manifest names; nothing was sent to
	// the host.
	CodeRemoteServerInvalid ErrorCode = "remote_server_invalid"
	// CodeDevcontainerUntrustedFolder means remote.devcontainerUp named a folder the user has not
	// trusted; the Dev Container CLI did not run, because building runs the folder's code here.
	CodeDevcontainerUntrustedFolder ErrorCode = "devcontainer_untrusted_folder"
	// CodeRemoteProcessGone means remote.attachProcess found no host process to receive: the
	// connection resumed no session, the process ended before what this Core received, or an
	// earlier attach already received it to its end.
	CodeRemoteProcessGone ErrorCode = "remote_process_gone"
	// CodeRemoteProcessAttached means another remote.attachProcess request already receives the
	// host process.
	CodeRemoteProcessAttached ErrorCode = "remote_process_attached"
	// CodeEntryNotFound means a file change named an entry, or the directory that would hold it,
	// that does not exist.
	CodeEntryNotFound ErrorCode = "entry_not_found"
	// CodeEntryExists means a file change would have replaced an existing entry; nothing was
	// written.
	CodeEntryExists ErrorCode = "entry_exists"
	// CodeUnknown means the failure fits no more specific category.
	CodeUnknown ErrorCode = "unknown"
)

// Error is a failure reported by the kernel, or a response this package could not decode. It
// is always returned as *Error, so callers can use errors.As to read the code.
type Error struct {
	// Command is the command name of the failed request.
	Command string
	// Code is the stable failure category.
	Code ErrorCode
	// Message is the kernel's summary, safe to show to the user as diagnostics.
	Message string
	// Details is optional diagnostic context, empty when the kernel gave none.
	Details string
}

// Error implements the error interface.
func (e *Error) Error() string {
	return fmt.Sprintf("lithe core: %s: %s (%s)", e.Command, e.Message, e.Code)
}

// Is reports whether target is the context error that matches e: context.Canceled for the
// cancelled code and context.DeadlineExceeded for the timed_out code.
func (e *Error) Is(target error) bool {
	switch target {
	case context.Canceled:
		return e.Code == CodeCancelled
	case context.DeadlineExceeded:
		return e.Code == CodeTimedOut
	}
	return false
}

// IsGitUntrustedWorkspace reports whether err is Core refusing to run Git for a workspace the
// user has not trusted (CodeGitUntrustedWorkspace).
func IsGitUntrustedWorkspace(err error) bool {
	var coreErr *Error
	return errors.As(err, &coreErr) && coreErr.Code == CodeGitUntrustedWorkspace
}

// newParseError reports a response that violates the envelope contract.
func newParseError(command, message, details string) *Error {
	return &Error{Command: command, Code: CodeParseFailed, Message: message, Details: details}
}
