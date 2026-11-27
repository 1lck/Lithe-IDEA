package agents

import (
	"slices"
)

// The API-45 permissions. Installing a plugin approves every permission its manifest asks for
// except PermissionReadSessions, which the user grants per plugin in the AI settings.
const (
	PermissionRun          = "agents.run"
	PermissionNative       = "agents.native"
	PermissionReadSessions = "agents.sessions.read"
	PermissionReadUsage    = "agents.usage.read"
)

// Consent is the set of plugins whose agents' local sessions the user lets Lithe read, by plugin
// ID. Core grants agents.sessions.read to a whole plugin, so the consent is a plugin's too: a
// plugin with two agents shows them under one switch. The zero value consents to none.
type Consent map[string]bool

// Plugin reports whether the user lets Lithe read the sessions of the plugin's agents.
func (c Consent) Plugin(pluginID string) bool { return c[pluginID] }

// Clone is an independent copy that keeps only the plugins consented to.
func (c Consent) Clone() Consent {
	if c == nil {
		return nil
	}
	out := make(Consent, len(c))
	for key, granted := range c {
		if granted {
			out[key] = true
		}
	}
	return out
}

// GrantedPermissions is the permission set agents.configure takes for one plugin: what its
// manifest asks for, without agents.sessions.read unless the user consented for the plugin.
func GrantedPermissions(manifestPermissions []string, readSessions bool) []string {
	out := make([]string, 0, len(manifestPermissions))
	for _, permission := range manifestPermissions {
		if permission == PermissionReadSessions && !readSessions {
			continue
		}
		if !slices.Contains(out, permission) {
			out = append(out, permission)
		}
	}
	return out
}

// UsesAgents reports whether a plugin takes part in API-45: it declares agents or reads their
// usage.
func UsesAgents(declaresAgents bool, manifestPermissions []string) bool {
	return declaresAgents || slices.Contains(manifestPermissions, PermissionReadUsage)
}
