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
		mode := stored.Mode
		if mode == "" {
			mode = "system"
		}
		proxyType := stored.ProxyType
		if proxyType == "" {
			proxyType = "http"
		}
		policy, err := kernel.ProxyPolicy(ctx, core.NetworkProxyRequest{
			Mode: mode, ProxyType: proxyType, Host: stored.Host, Port: stored.Port,
			Username: stored.Username, Password: password, PasswordIdentity: stored.PasswordIdentity,
			Exclusions: stored.Exclusions,
		})
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
			proxyType := next.ProxyType
			if proxyType == "" {
				proxyType = "http"
			}
			next.PasswordIdentity = &core.NetworkProxyIdentity{ProxyType: proxyType, Host: next.Host, Port: next.Port, Username: next.Username}
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
				a.notify(a.text.Errors.SaveFailed(err.Error()))
			}
			a.applyNetwork()
		})
	}()
}
