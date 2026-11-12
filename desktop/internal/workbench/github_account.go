package workbench

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
	"github.com/1lck/Lithe-IDEA/desktop/internal/githubapi"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/app"
)

// This file signs the client in to GitHub with the device flow (matrix id
// github-device-authorization): it shows the user code, opens GitHub's verification page, polls
// until the user answers, stores the token in the platform's credential store and validates it
// with currentUser. The token never leaves this file's state and the store; the settings page
// shows the login and the phase only. The client ID is the product's public OAuth client, read
// from LITHE_GITHUB_CLIENT_ID; without one sign-in is unavailable.

const (
	// githubCredentialPlugin and githubCredentialKey name the stored token in the credential store.
	githubCredentialPlugin = "github"
	githubCredentialKey    = "access-token"
	// githubAccountTimeout bounds one validation or one start request.
	githubAccountTimeout = 30 * time.Second
)

// githubPhase is where the sign-in stands.
type githubPhase uint8

const (
	githubIdle githubPhase = iota
	githubStarting
	githubWaiting
	githubValidating
)

// githubAccount is the window's GitHub account: whether it is connected and as whom, and the device
// authorization in progress. Background tasks write it through a.post; the settings page reads
// a snapshot, so the mutex guards it.
type githubAccount struct {
	mu        sync.Mutex
	login     string
	connected bool
	phase     githubPhase
	code      githubapi.DeviceCode
	err       string
	// cancel stops the sign-in in progress; gen drops the answer of one a newer sign-in replaced.
	cancel context.CancelFunc
	gen    int
	// token is kept in memory after it is validated, for the requests the account makes.
	token  string
	client *githubapi.Client
}

// errGitHubUnavailable reports that the kernel cannot plan GitHub requests.
var errGitHubUnavailable = errors.New("GitHub is unavailable")

// githubClientID is the OAuth client of the product, or empty when none is configured.
func githubClientID() string {
	return strings.TrimSpace(os.Getenv("LITHE_GITHUB_CLIENT_ID"))
}

// githubAPI is the client that plans and sends GitHub requests, made once with the kernel.
func (a *App) githubAPI() *githubapi.Client {
	g := &a.github
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.client == nil {
		if planner, ok := a.kernel.(githubapi.Planner); ok {
			g.client = githubapi.New(planner)
		}
	}
	return g.client
}

// loadGitHubAccount reads the stored token and validates it in the background. A network failure
// keeps the stored token: only GitHub saying it is invalid removes the connection.
func (a *App) loadGitHubAccount() {
	client := a.githubAPI()
	if client == nil {
		return
	}
	a.background(nil, githubAccountTimeout, func(ctx context.Context) func(*App) {
		token, found, err := credentials.Default().Get(ctx, githubCredentialPlugin, githubCredentialKey)
		if err != nil || !found {
			return func(a *App) {}
		}
		login, verr := a.validateGitHubToken(ctx, client, token)
		return func(a *App) {
			g := &a.github
			g.mu.Lock()
			defer g.mu.Unlock()
			g.token = token
			if verr == nil {
				g.login, g.connected = login, true
			}
		}
	})
}

// validateGitHubToken asks GitHub who the token belongs to.
func (a *App) validateGitHubToken(ctx context.Context, client *githubapi.Client, token string) (string, error) {
	raw, err := client.Do(ctx, core.GitHubRequest{Operation: "currentUser"}, token)
	if err != nil {
		return "", err
	}
	user, err := githubapi.DecodeUser(raw)
	if err != nil {
		return "", err
	}
	return user.Login, nil
}

// startGitHubSignIn begins a device authorization. A sign-in already running is replaced.
func (a *App) startGitHubSignIn() {
	client := a.githubAPI()
	clientID := githubClientID()
	g := &a.github
	g.mu.Lock()
	if client == nil || clientID == "" || g.phase != githubIdle {
		if clientID == "" {
			g.err = i18n.Shared(a.language(), "desktop.github.notConfigured")
		}
		g.mu.Unlock()
		return
	}
	if g.cancel != nil {
		g.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	g.gen++
	gen := g.gen
	g.cancel, g.phase, g.err, g.code = cancel, githubStarting, "", githubapi.DeviceCode{}
	g.mu.Unlock()
	a.performed("github.signIn", surfaceButton)
	started := time.Now()
	a.background(nil, 0, func(context.Context) func(*App) {
		startCtx, stop := context.WithTimeout(ctx, githubAccountTimeout)
		code, err := client.StartDevice(startCtx, clientID)
		stop()
		if err != nil {
			return a.finishGitHubSignIn(gen, "", "", err)
		}
		g.mu.Lock()
		if g.gen == gen {
			g.phase, g.code = githubWaiting, code
		}
		g.mu.Unlock()
		_ = app.OpenURL(code.VerificationURI)
		transitions, ok := a.kernel.(githubapi.Transitioner)
		if !ok {
			return a.finishGitHubSignIn(gen, "", "", errGitHubUnavailable)
		}
		token, err := client.AwaitDevice(ctx, transitions, clientID, code, started, nil)
		if err != nil {
			return a.finishGitHubSignIn(gen, "", "", err)
		}
		g.mu.Lock()
		if g.gen == gen {
			g.phase = githubValidating
		}
		g.mu.Unlock()
		login, verr := a.validateGitHubToken(ctx, client, token)
		if verr == nil {
			verr = credentials.Default().Set(ctx, githubCredentialPlugin, githubCredentialKey, token)
		}
		return a.finishGitHubSignIn(gen, token, login, verr)
	})
}

// finishGitHubSignIn ends a sign-in: on success the account is connected, otherwise the failure is
// shown. An answer from a sign-in that was replaced is dropped.
func (a *App) finishGitHubSignIn(gen int, token, login string, err error) func(*App) {
	return func(a *App) {
		g := &a.github
		g.mu.Lock()
		defer g.mu.Unlock()
		if g.gen != gen {
			return
		}
		g.cancel, g.phase, g.code = nil, githubIdle, githubapi.DeviceCode{}
		if err != nil {
			g.err = githubFailure(a.language(), err)
			return
		}
		g.token, g.login, g.connected = token, login, true
	}
}

// githubFailure is the text a failed sign-in shows; a cancelled one shows nothing.
func githubFailure(language i18n.Language, err error) string {
	switch {
	case err == nil:
		return ""
	case err == context.Canceled:
		return ""
	case err == githubapi.ErrDeviceExpired:
		return i18n.Shared(language, "desktop.github.expired")
	case err == githubapi.ErrDeviceDenied:
		return i18n.Shared(language, "desktop.github.denied")
	}
	return i18n.SharedFormat(language, "desktop.github.failed", map[string]string{"reason": err.Error()})
}

// cancelGitHubSignIn stops the sign-in in progress.
func (a *App) cancelGitHubSignIn() {
	g := &a.github
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.cancel != nil {
		g.cancel()
	}
	g.gen++
	g.cancel, g.phase, g.code = nil, githubIdle, githubapi.DeviceCode{}
}

// signOutGitHub removes the stored token and forgets the account.
func (a *App) signOutGitHub() {
	a.cancelGitHubSignIn()
	a.performed("github.signOut", surfaceButton)
	g := &a.github
	g.mu.Lock()
	g.token, g.login, g.connected, g.err = "", "", false, ""
	g.mu.Unlock()
	a.background(nil, githubAccountTimeout, func(ctx context.Context) func(*App) {
		err := credentials.Default().Delete(ctx, githubCredentialPlugin, githubCredentialKey)
		return func(a *App) {
			if err != nil {
				a.notifyError(i18n.SharedFormat(a.language(), "desktop.github.signOutFailed", map[string]string{"reason": err.Error()}))
			}
		}
	})
}

// githubSnapshot is what the settings page shows of the account.
type githubSnapshot struct {
	available       bool
	connected       bool
	login           string
	phase           githubPhase
	userCode        string
	verificationURI string
	err             string
}

// githubAccountSnapshot copies the account for a paint.
func (a *App) githubAccountSnapshot() githubSnapshot {
	g := &a.github
	g.mu.Lock()
	defer g.mu.Unlock()
	return githubSnapshot{
		available:       githubClientID() != "",
		connected:       g.connected,
		login:           g.login,
		phase:           g.phase,
		userCode:        g.code.UserCode,
		verificationURI: g.code.VerificationURI,
		err:             g.err,
	}
}

// githubSettings is the GitHub account the Version Control page of the settings window drives.
// The window calls it on its own thread, so every action is posted to the window's.
func (a *App) githubSettings() *settingswindow.GitHubAccount {
	return &settingswindow.GitHubAccount{
		Snapshot: func() settingswindow.GitHubState {
			s := a.githubAccountSnapshot()
			return settingswindow.GitHubState{
				Available:       s.available,
				Connected:       s.connected,
				Login:           s.login,
				Starting:        s.phase == githubStarting,
				Waiting:         s.phase == githubWaiting,
				Validating:      s.phase == githubValidating,
				UserCode:        s.userCode,
				VerificationURI: s.verificationURI,
				Error:           s.err,
			}
		},
		SignIn:  func() { a.post(func(a *App) { a.startGitHubSignIn() }) },
		Cancel:  func() { a.post(func(a *App) { a.cancelGitHubSignIn() }) },
		SignOut: func() { a.post(func(a *App) { a.signOutGitHub() }) },
	}
}
