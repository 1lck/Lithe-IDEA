package workbench

import (
	"context"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/credentials"
	"github.com/1lck/Lithe-IDEA/desktop/internal/netproxy"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// The proxy settings of the application's own HTTP traffic are stored with the other
// settings, except the password, which lives in the platform secret store under a
// namespace no plugin ID can take. Core turns them into the policy (network.proxyPolicy),
// which netproxy applies to Go's default transport.

const (
	networkCredentialNamespace = "@host/network-proxy"
	networkCredentialKey       = "password"
)

// networkCheckTarget is what the Network page's check asks for. The marketplace, plugin
// downloads and the update feed are served from GitHub, so an answer means they work through
// the server.
const networkCheckTarget = "https://github.com"

// networkKernel is the part of Core the proxy settings need.
type networkKernel interface {
	ProxyPolicy(context.Context, core.NetworkProxyRequest) (core.NetworkProxyPolicy, error)
}

// applyNetwork works out the policy of the stored settings off the window thread and
// applies it. A failure keeps the policy in force and is logged.
func (a *App) applyNetwork() {
	netproxy.Install()
	kernel, ok := a.kernel.(networkKernel)
	if !ok {
		return
	}
	stored := a.settings.Network
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		password := ""
		if stored.HasPassword {
			if secret, found, err := credentials.Default().Get(ctx, networkCredentialNamespace, networkCredentialKey); err == nil && found {
				password = secret
			}
		}
		policy, err := kernel.ProxyPolicy(ctx, networkProxyRequest(stored, password))
		if err != nil {
			a.post(func(a *App) {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("network_proxy_policy", err))
			})
			return
		}
		netproxy.Set(policy)
	}()
}

// setNetwork stores the Network page's applied settings. A new password is saved for
// the endpoint and account it was typed with, an empty one removes the stored password,
// and nil keeps it; then the policy is applied again.
func (a *App) setNetwork(next settingswindow.NetworkSettings, password *string) {
	if password != nil {
		next.HasPassword = *password != ""
		next.PasswordIdentity = nil
		if *password != "" {
			next.PasswordIdentity = networkIdentity(next)
		}
	}
	a.settings.Network = next
	a.saveSettings()
	if password == nil {
		a.applyNetwork()
		return
	}
	secret := *password
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		store := credentials.Default()
		var err error
		if secret == "" {
			err = store.Delete(ctx, networkCredentialNamespace, networkCredentialKey)
			if err == credentials.ErrNotFound {
				err = nil
			}
		} else {
			err = store.Set(ctx, networkCredentialNamespace, networkCredentialKey, secret)
		}
		a.post(func(a *App) {
			if err != nil {
				a.notifyError(a.text.Errors.SaveFailed(err.Error()))
			}
			a.applyNetwork()
		})
	}()
}

// networkProxyRequest is settings as network.proxyPolicy takes them, with the password stored
// or typed for them.
func networkProxyRequest(settings settingswindow.NetworkSettings, password string) core.NetworkProxyRequest {
	mode := settings.Mode
	if mode == "" {
		mode = "system"
	}
	return core.NetworkProxyRequest{
		Mode: mode, ProxyType: networkProxyType(settings), Host: settings.Host, Port: settings.Port,
		Username: settings.Username, Password: password, PasswordIdentity: settings.PasswordIdentity,
		Exclusions: settings.Exclusions,
	}
}

// networkIdentity is the endpoint and account of settings: a password typed with them is
// saved for it, and Core hands that password only to the same endpoint and account.
func networkIdentity(settings settingswindow.NetworkSettings) *core.NetworkProxyIdentity {
	return &core.NetworkProxyIdentity{ProxyType: networkProxyType(settings), Host: settings.Host, Port: settings.Port, Username: settings.Username}
}

// networkProxyType is the stored proxy type, "" being HTTP.
func networkProxyType(settings settingswindow.NetworkSettings) string {
	if settings.ProxyType == "" {
		return "http"
	}
	return settings.ProxyType
}

// networkChecker is the Network page's connection check, or nil when Core cannot read
// proxy settings. It runs off the window thread.
func (a *App) networkChecker() func(context.Context, settingswindow.NetworkSettings, *string) settingswindow.NetworkCheck {
	kernel, ok := a.kernel.(networkKernel)
	if !ok {
		return nil
	}
	return func(ctx context.Context, draft settingswindow.NetworkSettings, password *string) settingswindow.NetworkCheck {
		return checkNetwork(ctx, kernel, credentials.Default(), networkCheckTarget, draft, password)
	}
}

// secretReader is the part of the secret store the check reads the saved password from.
type secretReader interface {
	Get(ctx context.Context, namespace, key string) (string, bool, error)
}

// checkNetwork sends one request for target through the Network page's draft, unsaved. Core
// reads the draft as it would the stored settings: a typed password goes with the draft's
// endpoint, and an untouched field hands over the saved one, which Core keeps only when the
// draft still names the endpoint it was saved for. A draft Core does not turn into a custom
// server is incomplete, and nothing is sent.
func checkNetwork(ctx context.Context, kernel networkKernel, secrets secretReader, target string, draft settingswindow.NetworkSettings, password *string) settingswindow.NetworkCheck {
	secret := ""
	switch {
	case password != nil:
		secret = *password
		draft.PasswordIdentity = nil
		if secret != "" {
			draft.PasswordIdentity = networkIdentity(draft)
		}
	case draft.HasPassword:
		value, found, err := secrets.Get(ctx, networkCredentialNamespace, networkCredentialKey)
		if err != nil {
			return settingswindow.NetworkCheck{Err: err}
		}
		if found {
			secret = value
		}
	}
	policy, err := kernel.ProxyPolicy(ctx, networkProxyRequest(draft, secret))
	if err != nil {
		return settingswindow.NetworkCheck{Err: err}
	}
	if policy.Policy != "custom" || !policy.Configured {
		return settingswindow.NetworkCheck{Incomplete: true}
	}
	status, elapsed, err := netproxy.Check(ctx, policy, target)
	return settingswindow.NetworkCheck{Status: status, Elapsed: elapsed, Err: err}
}
