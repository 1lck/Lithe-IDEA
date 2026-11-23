package core

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"strings"
)

// Git authentication: Core lets a Git process the user started call this program as its
// AskPass helper (GIT_ASKPASS, SSH_ASKPASS). The helper process forwards the question over a
// channel only this account can reach to the request that started Git, which reports it as an
// execution event; the host asks the user and answers with git.authRespond. Core redacts the
// question, keeps the answer out of logs and zeroes its copies once Git has read it.

// GitAuthChallenge is a question a running Git request asks: a user name, a password, token or
// passphrase (Secret), or, after a transfer failed to authenticate, whether to retry it once
// with credentials typed in Lithe instead of the credential helper (Retry).
type GitAuthChallenge struct {
	// RequestID names the challenge to GitAuthRespond.
	RequestID string
	// Prompt is Git's or SSH's own question with Core's redactions applied. It is upstream text,
	// shown as it is. A Retry challenge carries Core's English wording, which the host replaces
	// with its own translated question.
	Prompt string
	// Secret says the answer must not be shown or logged, nor kept unless the user ticks Remember
	// under a remote connection's password or passphrase (workbench, remote_answers.go).
	Secret bool
	// Retry is the question whether to retry the transfer; only GitRetryAnswer accepts it.
	Retry bool
	// Attempt counts, from 1, how often the Git process asked the same question. A Retry
	// challenge carries the number of the transfer a retry would start instead, from 2.
	Attempt int
	// WorkingDirectory is the directory the Git process runs in.
	WorkingDirectory string
	// Remote says the question comes from the SSH client of a remote connection (RemoteProbe),
	// not from Git: it is answered with RemoteAuthRespond.
	Remote bool
	// Kind is what a Remote question asks for, one of the RemoteQuestion kinds; Core classifies
	// OpenSSH's English wording, so the window can show a fitting form. Empty for Git.
	Kind RemoteQuestionKind
	// KeyType and Fingerprint name the unknown host key of a RemoteQuestionHostKey question, for
	// example "ED25519" and "SHA256:…"; empty when OpenSSH did not print them.
	KeyType     string
	Fingerprint string
	// Done is closed once the request that asked has returned; no answer reaches it after that.
	Done <-chan struct{}
}

// GitRetryAnswer is the answer to a Retry challenge that retries the transfer.
const GitRetryAnswer = "retry"

// RemoteQuestionKind is what an OpenSSH question of a remote connection asks for.
type RemoteQuestionKind string

// The kinds Core tells apart. Any other wording is RemoteQuestionOther, shown as asked.
const (
	// RemoteQuestionHostKey asks to accept ("yes") or decline ("no") an unknown host key.
	RemoteQuestionHostKey RemoteQuestionKind = "hostKey"
	// RemoteQuestionPassword asks for the account's password.
	RemoteQuestionPassword RemoteQuestionKind = "password"
	// RemoteQuestionPassphrase asks for a private key's passphrase.
	RemoteQuestionPassphrase RemoteQuestionKind = "passphrase"
	// RemoteQuestionCode asks for a one-time or verification code.
	RemoteQuestionCode RemoteQuestionKind = "code"
	// RemoteQuestionOther is any other question.
	RemoteQuestionOther RemoteQuestionKind = "other"
)

type gitAuthenticationKey struct{}

// WithGitAuthentication returns a context whose Git requests may ask the user for credentials:
// Core lets the Git processes the user sees (not a request's internal queries) use this program
// as their AskPass helper, and each question reaches prompt. prompt runs on the request's
// goroutine and must return promptly, posting the question to the UI thread; the Git process
// waits for GitAuthRespond, for at most Core's prompt deadline, and fails authentication
// without an answer. Give it only to operations the user started: an automatic refresh must
// fail instead of asking.
func WithGitAuthentication(ctx context.Context, prompt func(GitAuthChallenge)) context.Context {
	return context.WithValue(ctx, gitAuthenticationKey{}, prompt)
}

// gitAuthenticationOf is the prompt of a request of command, nil when ctx has none or command
// starts no Git process.
func gitAuthenticationOf(ctx context.Context, command string) func(GitAuthChallenge) {
	if !strings.HasPrefix(command, "git.") || gitConsoleUnrecorded[command] {
		return nil
	}
	prompt, _ := ctx.Value(gitAuthenticationKey{}).(func(GitAuthChallenge))
	return prompt
}

// gitAuthenticationEvent is the execution event of a question Git asked.
var gitAuthenticationEvent = []byte(`"authentication"`)

// gitAuthenticationObserver hands each authentication event of a request to prompt, with done
// closed when the request returns, and passes every event on to next.
func gitAuthenticationObserver(prompt func(GitAuthChallenge), done <-chan struct{}, next func(json.RawMessage)) func(json.RawMessage) {
	return func(raw json.RawMessage) {
		// Git prints many output lines and asks rarely; only a line naming the kind is decoded.
		if bytes.Contains(raw, gitAuthenticationEvent) {
			var event struct {
				Type             string `json:"type"`
				RequestID        string `json:"requestId"`
				Prompt           string `json:"prompt"`
				Secret           bool   `json:"secret"`
				Retry            bool   `json:"retry"`
				Attempt          int    `json:"attempt"`
				WorkingDirectory string `json:"workingDirectory"`
				Kind             string `json:"kind"`
				KeyType          string `json:"keyType"`
				Fingerprint      string `json:"fingerprint"`
			}
			if json.Unmarshal(raw, &event) == nil && event.Type == "authentication" && event.RequestID != "" {
				prompt(GitAuthChallenge{
					RequestID:        event.RequestID,
					Prompt:           event.Prompt,
					Secret:           event.Secret,
					Retry:            event.Retry,
					Attempt:          event.Attempt,
					WorkingDirectory: event.WorkingDirectory,
					Kind:             RemoteQuestionKind(event.Kind),
					KeyType:          event.KeyType,
					Fingerprint:      event.Fingerprint,
					Done:             done,
				})
			}
		}
		if next != nil {
			next(raw)
		}
	}
}

// gitAuthReply is the payload of git.authRespond. A nil Answer cancels the question.
type gitAuthReply struct {
	RequestID string  `json:"requestId"`
	Answer    *string `json:"answer"`
}

// GitAuthRespond answers the challenge requestID with the text the user typed, GitRetryAnswer to
// retry, or nil to cancel. accepted is false when the challenge no longer waits: it was already
// answered, it expired, its request returned, or Core refused the answer (longer than 8192 bytes,
// or containing NUL, CR or LF). The answer is never logged. Core answers at once, so the call
// may run on any goroutine, but not on the UI thread.
func (c *Client) GitAuthRespond(ctx context.Context, requestID string, answer *string) (accepted bool, err error) {
	var result struct {
		Accepted bool `json:"accepted"`
	}
	err = c.Execute(ctx, "git.authRespond", gitAuthReply{RequestID: requestID, Answer: answer}, &result)
	return result.Accepted, err
}

// gitAskPassModeVariable is set by Core in the environment of the helper it names to Git.
const gitAskPassModeVariable = "LITHE_GIT_ASKPASS_MODE"

// GitAskPassRequest reports whether this process was started as the AskPass helper of an
// interactive Git process, and the question Git or SSH passed as its first argument. args is
// os.Args.
func GitAskPassRequest(args []string) (prompt string, helper bool) {
	if os.Getenv(gitAskPassModeVariable) != "1" {
		return "", false
	}
	if len(args) > 1 {
		prompt = args[1]
	}
	return prompt, true
}
