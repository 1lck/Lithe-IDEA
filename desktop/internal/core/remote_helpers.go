package core

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
)

// Connection window helpers: Core parses a quick-connect address, asks OpenSSH what it would use
// for a connection (`ssh -G`), lists the hosts of ~/.ssh/config and of Motty that the window can
// import, and keeps the trust decisions of remote workspaces. None of them connects to a host or
// reads a secret; the desktop only presents the results.

// RemoteAddress is a quick-connect address split into the form's fields; Port is 0 and User
// empty when the address names none.
type RemoteAddress struct {
	Host string `json:"host"`
	User string `json:"user,omitempty"`
	Port uint16 `json:"port,omitempty"`
}

// RemoteParseAddress splits text, `[ssh://][user@]host[:port]` with an IPv6 host written in
// brackets, into the fields of a connection. A refused address fails with CodeInvalidRequest and
// names host, user or port in RemoteConnectionFieldError. Nothing is resolved or contacted.
func (c *Client) RemoteParseAddress(ctx context.Context, text string) (RemoteAddress, error) {
	var address RemoteAddress
	err := c.Execute(ctx, "remote.parseAddress", struct {
		Text string `json:"text"`
	}{text}, &address)
	return address, err
}

// RemoteSettingSource says where an effective value comes from.
type RemoteSettingSource string

const (
	// RemoteSettingFromConnection is a value the saved connection sets.
	RemoteSettingFromConnection RemoteSettingSource = "connection"
	// RemoteSettingFromSSHConfig is a value the user's or the system's SSH configuration sets.
	RemoteSettingFromSSHConfig RemoteSettingSource = "sshConfig"
	// RemoteSettingDefault is OpenSSH's or Lithe's default.
	RemoteSettingDefault RemoteSettingSource = "default"
)

// RemoteEffectiveText is a text value OpenSSH would use and where it comes from.
type RemoteEffectiveText struct {
	Value  string              `json:"value"`
	Source RemoteSettingSource `json:"source"`
}

// RemoteEffectiveNumber is a number OpenSSH would use and where it comes from.
type RemoteEffectiveNumber struct {
	Value  uint32              `json:"value"`
	Source RemoteSettingSource `json:"source"`
}

// RemoteEffectiveList is a list of paths OpenSSH would use and where it comes from.
type RemoteEffectiveList struct {
	Value  []string            `json:"value"`
	Source RemoteSettingSource `json:"source"`
}

// RemoteEffectiveSettings is what OpenSSH would use for a connection. IdentityFiles are paths as
// the configuration writes them, empty for password authentication; ProxyJump is nil for a
// direct connection.
type RemoteEffectiveSettings struct {
	HostName              RemoteEffectiveText   `json:"hostName"`
	Port                  RemoteEffectiveNumber `json:"port"`
	User                  RemoteEffectiveText   `json:"user"`
	IdentityFiles         RemoteEffectiveList   `json:"identityFiles"`
	ProxyJump             *RemoteEffectiveText  `json:"proxyJump"`
	ConnectTimeoutSeconds RemoteEffectiveNumber `json:"connectTimeoutSeconds"`
	KeepAliveSeconds      RemoteEffectiveNumber `json:"keepAliveSeconds"`
}

// RemoteEffectiveSettings asks OpenSSH what it would use for connection, without connecting.
// Core bounds the run to 10 seconds: CodeRuntimeMissing without ssh, CodeProcessFailed with the
// redacted standard error in Details, CodeTimedOut and CodeParseFailed. preferences is the
// remote workspace preference document, or nil, naming the SSH program.
func (c *Client) RemoteEffectiveSettings(ctx context.Context, connection SSHConnection, preferences *string) (RemoteEffectiveSettings, error) {
	var settings RemoteEffectiveSettings
	err := c.Execute(ctx, "remote.effectiveSettings", struct {
		Connection  SSHConnection `json:"connection"`
		Preferences *string       `json:"preferences,omitempty"`
	}{connection, preferences}, &settings)
	return settings, err
}

// RemoteImportStatus is whether a host of ~/.ssh/config or Motty can be imported.
type RemoteImportStatus string

const (
	// RemoteImportable is a host the import saves with every setting.
	RemoteImportable RemoteImportStatus = "importable"
	// RemoteImportPartial is a Motty host saved without some of its settings.
	RemoteImportPartial RemoteImportStatus = "partial"
	// RemoteImportExists is a host a saved entry probably already reaches.
	RemoteImportExists RemoteImportStatus = "exists"
	// RemoteImportPattern is a Host line with wildcards or a negation, naming no single host.
	RemoteImportPattern RemoteImportStatus = "pattern"
	// RemoteImportInvalid is a host name Lithe refuses, or a Motty SSH host with a setting Lithe
	// refuses; the refused field is marked RemoteMottySkipInvalid.
	RemoteImportInvalid RemoteImportStatus = "invalid"
	// RemoteImportUnreadable is a host `ssh -G` failed or timed out for.
	RemoteImportUnreadable RemoteImportStatus = "unreadable"
	// RemoteImportUnsupported is a Motty host that is not an SSH host or whose address Lithe
	// refuses.
	RemoteImportUnsupported RemoteImportStatus = "unsupported"
)

// RemoteResolvedHost is what `ssh -G` resolved a ~/.ssh/config alias to.
type RemoteResolvedHost struct {
	HostName  string `json:"hostName"`
	User      string `json:"user"`
	Port      uint16 `json:"port"`
	ProxyJump string `json:"proxyJump,omitempty"`
}

// RemoteSSHConfigHost is one Host name of ~/.ssh/config. ExistingID and ExistingName name the
// saved entry of a RemoteImportExists host; UsedAsJumpBy names the aliases that jump through it.
type RemoteSSHConfigHost struct {
	Alias        string              `json:"alias"`
	Status       RemoteImportStatus  `json:"status"`
	Resolved     *RemoteResolvedHost `json:"resolved"`
	ExistingID   string              `json:"existingId,omitempty"`
	ExistingName string              `json:"existingName,omitempty"`
	UsedAsJumpBy []string            `json:"usedAsJumpBy"`
}

// RemoteSSHConfigHosts lists the Host names of ~/.ssh/config and the files it includes; Files
// are the paths read, and Truncated says more than 256 names were left out.
type RemoteSSHConfigHosts struct {
	Files     []string              `json:"files"`
	Hosts     []RemoteSSHConfigHost `json:"hosts"`
	Truncated bool                  `json:"truncated"`
}

// RemoteSSHConfigHosts reads ~/.ssh/config below homeDirectory, an absolute path, and checks each
// host against document, the saved connections or nil. Core runs `ssh -G` for each alias within
// 30 seconds for the whole list; CodeRuntimeMissing without ssh. preferences is the remote
// workspace preference document, or nil, naming the SSH program.
func (c *Client) RemoteSSHConfigHosts(ctx context.Context, homeDirectory string, document, preferences *string) (RemoteSSHConfigHosts, error) {
	var hosts RemoteSSHConfigHosts
	err := c.Execute(ctx, "remote.sshConfigHosts", struct {
		HomeDirectory string  `json:"homeDirectory"`
		Document      *string `json:"document"`
		Preferences   *string `json:"preferences,omitempty"`
	}{homeDirectory, document, preferences}, &hosts)
	hosts.Files = nonNil(hosts.Files)
	hosts.Hosts = nonNil(hosts.Hosts)
	return hosts, err
}

// RemoteMottyUnavailable says why Motty's hosts cannot be listed.
type RemoteMottyUnavailable string

const (
	// RemoteMottyMissing means Motty's config.db does not exist.
	RemoteMottyMissing RemoteMottyUnavailable = "missing"
	// RemoteMottyUnreadable means the database could not be opened or read.
	RemoteMottyUnreadable RemoteMottyUnavailable = "unreadable"
	// RemoteMottyTooLarge means it is over 64 MiB or 4096 records.
	RemoteMottyTooLarge RemoteMottyUnavailable = "tooLarge"
	// RemoteMottyUnsupportedFormat means its layout is not the one Core reads.
	RemoteMottyUnsupportedFormat RemoteMottyUnavailable = "unsupportedFormat"
)

// RemoteMottySkip says why a Motty setting is not imported.
type RemoteMottySkip string

const (
	// RemoteMottySkipSecret is stored in Motty's vault, which Core never opens.
	RemoteMottySkipSecret RemoteMottySkip = "secret"
	// RemoteMottySkipNoSetting has no connection setting in Lithe.
	RemoteMottySkipNoSetting RemoteMottySkip = "noSetting"
	// RemoteMottySkipProtocol belongs to a protocol other than SSH.
	RemoteMottySkipProtocol RemoteMottySkip = "protocol"
	// RemoteMottySkipCommand is a jump route that runs a command.
	RemoteMottySkipCommand RemoteMottySkip = "command"
	// RemoteMottySkipKerberos is left to the SSH configuration.
	RemoteMottySkipKerberos RemoteMottySkip = "kerberos"
	// RemoteMottySkipExtraKey is a key file after the first, which alone is imported.
	RemoteMottySkipExtraKey RemoteMottySkip = "extraKey"
	// RemoteMottySkipInvalid is a value Lithe refuses.
	RemoteMottySkipInvalid RemoteMottySkip = "invalid"
)

// RemoteMottyField is one Motty setting of a host: Lithe names the connection field it becomes,
// or Skip says why it is not imported. Value is Motty's value as the window shows it, empty for
// a secret.
type RemoteMottyField struct {
	Motty string          `json:"motty"`
	Value string          `json:"value"`
	Lithe string          `json:"lithe,omitempty"`
	Skip  RemoteMottySkip `json:"skip,omitempty"`
}

// RemoteMottyCandidate is one Motty host. Name is the label an import saves it under, Address
// `[user@]host[:port]` and System Motty's operating system tag. Connection is what the import
// saves, nil for RemoteImportUnsupported and RemoteImportInvalid; ExistingID names the saved
// entry of a RemoteImportExists host.
type RemoteMottyCandidate struct {
	Key        string                `json:"key"`
	Name       string                `json:"name"`
	Address    string                `json:"address"`
	System     string                `json:"system,omitempty"`
	Color      RemoteConnectionColor `json:"color,omitempty"`
	Group      string                `json:"group,omitempty"`
	Status     RemoteImportStatus    `json:"status"`
	ExistingID string                `json:"existingId,omitempty"`
	Connection *SSHConnection        `json:"connection"`
	Fields     []RemoteMottyField    `json:"fields"`
}

// RemoteMottyHosts is Motty's database read for an import: either Unavailable, or Format, the
// Groups that have a host, in Motty's order, and the Candidates.
type RemoteMottyHosts struct {
	Database    string                 `json:"database"`
	Unavailable RemoteMottyUnavailable `json:"unavailable,omitempty"`
	Format      string                 `json:"format,omitempty"`
	Groups      []string               `json:"groups"`
	Candidates  []RemoteMottyCandidate `json:"candidates"`
}

// RemoteMottyHosts opens motty/config.db below configDirectory, the platform's absolute user
// configuration directory, read only, and checks each host against document, the saved
// connections or nil. Core never opens Motty's vault, so no password or key is read, and writes
// nothing to Motty's files.
func (c *Client) RemoteMottyHosts(ctx context.Context, configDirectory string, document *string) (RemoteMottyHosts, error) {
	var hosts RemoteMottyHosts
	err := c.Execute(ctx, "remote.mottyHosts", struct {
		ConfigDirectory string  `json:"configDirectory"`
		Document        *string `json:"document"`
	}{configDirectory, document}, &hosts)
	hosts.Groups = nonNil(hosts.Groups)
	hosts.Candidates = nonNil(hosts.Candidates)
	return hosts, err
}

// RemoteWorkspaceTrustStorage says where the host keeps the remote trust document: RelativePath
// inside the platform preference directory, at most MaximumBytes long.
type RemoteWorkspaceTrustStorage struct {
	RelativePath string `json:"relativePath"`
	MaximumBytes int64  `json:"maximumBytes"`
}

// RemoteWorkspaceTrustOf is one remote workspace's trust: State is WorkspaceTrusted,
// WorkspaceDistrusted or WorkspaceTrustUnset; Workspace is the host's real path of the root,
// Location the trusted folder that trusts it and OfferedLocation the parent folder a prompt may
// offer, nil when that is the host's root. Target is Core's key of the connection.
type RemoteWorkspaceTrustOf struct {
	State           string          `json:"state"`
	Workspace       string          `json:"workspace"`
	Location        *string         `json:"location"`
	OfferedLocation *string         `json:"offeredLocation"`
	Target          json.RawMessage `json:"target"`
}

// RemoteWorkspaceTrustState is the remote trust document as Core reads it, and the trust of the
// workspace the request named.
type RemoteWorkspaceTrustState struct {
	Document           RemoteWorkspaceTrustDocument `json:"document"`
	Storage            RemoteWorkspaceTrustStorage  `json:"storage"`
	ProjectCodeAllowed bool                         `json:"projectCodeAllowed"`
	WorkspaceTrust     *RemoteWorkspaceTrustOf      `json:"workspaceTrust"`
}

// RemoteWorkspaceTrustDocument is the validated remote trust document: the decisions of every
// connection target, sorted by target.
type RemoteWorkspaceTrustDocument struct {
	Version int                          `json:"version"`
	Targets []RemoteWorkspaceTrustTarget `json:"targets"`
}

// The lists of one target's decisions, as RemoteWorkspaceTrustRevoke names them.
const (
	RemoteTrustTrustedWorkspaces    = "trustedWorkspaces"
	RemoteTrustDistrustedWorkspaces = "distrustedWorkspaces"
	RemoteTrustTrustedLocations     = "trustedLocations"
)

// RemoteWorkspaceTrustTarget is the decisions on the workspaces of one connection target. Target
// is Core's key of the connection, passed back as it is; Label is the connection name shown with
// it, empty when no decision gave one. Each list holds sorted, distinct host real paths.
type RemoteWorkspaceTrustTarget struct {
	Target               json.RawMessage `json:"target"`
	Label                string          `json:"label,omitempty"`
	TrustedWorkspaces    []string        `json:"trustedWorkspaces,omitempty"`
	DistrustedWorkspaces []string        `json:"distrustedWorkspaces,omitempty"`
	TrustedLocations     []string        `json:"trustedLocations,omitempty"`
}

// Place is the route of the target's hops, outermost first: "destination:port" for an SSH hop,
// with the User option in front when the destination names no user, "engine:container" for a
// container and "wsl:[user@]distribution" for a WSL distribution, as WSLConnection.Identity
// writes it, joined by " → ". It is empty for a target it cannot read.
func (t RemoteWorkspaceTrustTarget) Place() string {
	var target struct {
		Hops []struct {
			SSH *struct {
				Destination string  `json:"destination"`
				Port        *uint16 `json:"port"`
				PortOption  string  `json:"portOption"`
				User        string  `json:"user"`
			} `json:"ssh"`
			Container *struct {
				Engine    string `json:"engine"`
				Context   string `json:"context"`
				Container string `json:"container"`
			} `json:"container"`
			WSL *WSLConnection `json:"wsl"`
		} `json:"hops"`
	}
	if json.Unmarshal(t.Target, &target) != nil {
		return ""
	}
	hops := make([]string, 0, len(target.Hops))
	for _, hop := range target.Hops {
		switch {
		case hop.SSH != nil:
			place := hop.SSH.Destination
			if hop.SSH.User != "" && !strings.Contains(place, "@") {
				place = hop.SSH.User + "@" + place
			}
			if hop.SSH.Port != nil {
				place += ":" + strconv.Itoa(int(*hop.SSH.Port))
			} else if hop.SSH.PortOption != "" {
				place += ":" + hop.SSH.PortOption
			}
			hops = append(hops, place)
		case hop.Container != nil:
			hops = append(hops, (ContainerConnection{Engine: hop.Container.Engine, Context: hop.Container.Context, Container: hop.Container.Container}).Identity())
		case hop.WSL != nil:
			hops = append(hops, hop.WSL.Identity())
		}
	}
	return strings.Join(hops, " → ")
}

// RemoteWorkspaceTrust reads document, the remote trust source or nil, and, when sessionID is
// set, the trust of workspace, an absolute host path opened over the session. Decisions are
// keyed by the connection's target and the workspace's real path, and never mix with local ones.
func (c *Client) RemoteWorkspaceTrust(ctx context.Context, document *string, sessionID, workspace string) (RemoteWorkspaceTrustState, error) {
	var state RemoteWorkspaceTrustState
	err := c.Execute(ctx, "remote.workspaceTrust", struct {
		Document  *string `json:"document"`
		SessionID string  `json:"sessionId,omitempty"`
		Workspace string  `json:"workspace,omitempty"`
	}{document, sessionID, workspace}, &state)
	return state, err
}

// RemoteWorkspaceTrustDecision records one decision on the workspace opened over SessionID:
// Trusted lets its project code run and false keeps it in safe mode; Location also trusts the
// offered parent folder. Label is the connection name shown with the target's decisions.
type RemoteWorkspaceTrustDecision struct {
	SessionID string `json:"sessionId"`
	Workspace string `json:"workspace"`
	Trusted   bool   `json:"trusted"`
	Location  bool   `json:"location,omitempty"`
	Label     string `json:"label,omitempty"`
}

// RemoteWorkspaceTrustPublication is the outcome of a decision or a removal. Document is the text
// to publish, nil when the edit changed nothing; Decisions is the document after the edit.
type RemoteWorkspaceTrustPublication struct {
	Changed   bool                         `json:"changed"`
	Document  *string                      `json:"document"`
	Decisions RemoteWorkspaceTrustDocument `json:"decisions"`
}

// RemoteWorkspaceTrustRevoke removes Path from the List (RemoteTrustTrustedWorkspaces,
// RemoteTrustDistrustedWorkspaces or RemoteTrustTrustedLocations) of Target's decisions, as
// RemoteWorkspaceTrustState listed them. It needs no open connection.
type RemoteWorkspaceTrustRevoke struct {
	Target json.RawMessage `json:"target"`
	List   string          `json:"list"`
	Path   string          `json:"path"`
}

// EditRemoteWorkspaceTrust records decision in document, the remote trust source or nil. A
// closed session fails with CodeConnectionClosed.
func (c *Client) EditRemoteWorkspaceTrust(ctx context.Context, document *string, decision RemoteWorkspaceTrustDecision) (RemoteWorkspaceTrustPublication, error) {
	var publication RemoteWorkspaceTrustPublication
	err := c.Execute(ctx, "remote.editWorkspaceTrust", struct {
		Document *string                      `json:"document"`
		Decision RemoteWorkspaceTrustDecision `json:"decision"`
	}{document, decision}, &publication)
	return publication, err
}

// RevokeRemoteWorkspaceTrust removes one entry from document, the remote trust source or nil.
// Removing an absent entry changes nothing; a target left without entries is dropped.
func (c *Client) RevokeRemoteWorkspaceTrust(ctx context.Context, document *string, revoke RemoteWorkspaceTrustRevoke) (RemoteWorkspaceTrustPublication, error) {
	var publication RemoteWorkspaceTrustPublication
	err := c.Execute(ctx, "remote.editWorkspaceTrust", struct {
		Document *string                    `json:"document"`
		Revoke   RemoteWorkspaceTrustRevoke `json:"revoke"`
	}{document, revoke}, &publication)
	return publication, err
}
