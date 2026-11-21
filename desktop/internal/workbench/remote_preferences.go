package workbench

import (
	"context"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
)

// remotePreferencesDocument is the remote workspace preference document kept under root, for a
// Core request that starts OpenSSH: nil when there is no preference directory or no document, so
// every value is automatic. A damaged document fails with remoteconn.ErrDamaged, so OpenSSH does
// not start with a program the user did not choose. It runs off the window thread; root is
// a.globalToolchainRoot() read on it.
func remotePreferencesDocument(ctx context.Context, kernel Kernel, root string) (*string, error) {
	if root == "" {
		return nil, nil
	}
	return remoteconn.PreferencesDocument(ctx, kernel, root)
}

// remoteReconnectDelays is the pause before each automatic attempt to connect again, as Core
// derives it from the reconnect limit of the preferences under root; none when the limit is 0.
// It runs off the window thread.
func remoteReconnectDelays(ctx context.Context, kernel Kernel, root string) ([]time.Duration, error) {
	var reconnect core.RemoteReconnect
	if root == "" {
		state, err := kernel.RemotePreferences(ctx, nil, "")
		if err != nil {
			return nil, err
		}
		reconnect = state.Reconnect
	} else {
		preferences, err := remoteconn.ReadPreferences(ctx, kernel, root, "")
		if err != nil {
			return nil, err
		}
		reconnect = preferences.State.Reconnect
	}
	delays := make([]time.Duration, len(reconnect.DelaysMilliseconds))
	for i, milliseconds := range reconnect.DelaysMilliseconds {
		delays[i] = time.Duration(milliseconds) * time.Millisecond
	}
	return delays, nil
}
