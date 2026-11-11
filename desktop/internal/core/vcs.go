package core

import (
	"context"
	"encoding/json"
)

// This file binds the VCS-provider commands of rust/contracts/vcs-provider-v1.md: root
// detection, the request a negotiated provider session runs, and the check of its reply. Core
// owns every rule (which roots exist, which operation needs which capability, what a valid
// reply is); the types below only carry its answers.

// VcsMarker is one file or directory whose presence directly inside a directory makes it a root.
type VcsMarker struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

// VcsTool is the version control client a provider runs: bare command names the host resolves
// like a system-command launch, and an optional probe.
type VcsTool struct {
	Commands            []string `json:"commands"`
	ValidationArguments []string `json:"validationArguments"`
}

// VcsProviderDescriptor is one VCS Core knows: the built-in Git, or a plugin's provider.
type VcsProviderDescriptor struct {
	Vcs         string `json:"vcs"`
	DisplayName string `json:"displayName"`
	Origin      struct {
		Kind     string `json:"kind"`
		PluginID string `json:"pluginID"`
	} `json:"origin"`
	Markers       []VcsMarker `json:"markers"`
	MetadataPaths []string    `json:"metadataPaths"`
	Tool          *VcsTool    `json:"tool"`
	MayUseNetwork bool        `json:"mayUseNetwork"`
}

// VcsRoot is one working copy Core found: its workspace-relative identity ("" for the
// workspace, ".." segments for an enclosing directory), its VCS and its native path.
type VcsRoot struct {
	ID     string `json:"id"`
	Vcs    string `json:"vcs"`
	Path   string `json:"path"`
	Mapped bool   `json:"mapped"`
}

// VcsAmbiguous is a directory holding the markers of several VCSs; no root is made of it until
// a mapping names one of them.
type VcsAmbiguous struct {
	ID  string   `json:"id"`
	Vcs []string `json:"vcs"`
}

// VcsMapping is the user's choice of the VCS of an ambiguous directory.
type VcsMapping struct {
	ID  string `json:"id"`
	Vcs string `json:"vcs"`
}

// VcsDetection is what vcs.detectRoots found in a workspace.
type VcsDetection struct {
	Providers      []VcsProviderDescriptor `json:"providers"`
	Roots          []VcsRoot               `json:"roots"`
	Ambiguous      []VcsAmbiguous          `json:"ambiguous"`
	UnusedMappings []VcsMapping            `json:"unusedMappings"`
	// Truncated says the directory budget ran out, so a root may be missing.
	Truncated bool `json:"truncated"`
	// Rejected are the manifests Core refused, by their index in the request.
	Rejected []struct {
		Index int                   `json:"index"`
		Error *MarketplaceRejection `json:"error"`
	} `json:"rejected"`
	// Conflicts are the plugins that lost a VCS to another plugin.
	Conflicts []struct {
		PluginID string `json:"pluginID"`
		Vcs      string `json:"vcs"`
		By       string `json:"by"`
	} `json:"conflicts"`
}

// Provider is the descriptor of vcs, or nil.
func (d *VcsDetection) Provider(vcs string) *VcsProviderDescriptor {
	for index := range d.Providers {
		if d.Providers[index].Vcs == vcs {
			return &d.Providers[index]
		}
	}
	return nil
}

// VcsDetectRoots has Core find the working copies of the workspace at root, for the built-in Git
// and for each provider the manifests declare. Core validates every manifest again; detection
// reads static markers and never starts a process.
func (c *Client) VcsDetectRoots(ctx context.Context, workspaceRoot string, manifests []json.RawMessage, mappings []VcsMapping) (VcsDetection, error) {
	const command = "vcs.detectRoots"
	type plugin struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	plugins := make([]plugin, len(manifests))
	for index, manifest := range manifests {
		plugins[index] = plugin{manifest}
	}
	if mappings == nil {
		mappings = []VcsMapping{}
	}
	var result struct {
		Status    string                `json:"status"`
		Error     *MarketplaceRejection `json:"error"`
		Detection *VcsDetection         `json:"detection"`
	}
	if err := c.Execute(ctx, command, struct {
		WorkspaceRoot string       `json:"workspaceRoot"`
		Plugins       []plugin     `json:"plugins"`
		Mappings      []VcsMapping `json:"mappings"`
	}{workspaceRoot, plugins, mappings}, &result); err != nil {
		return VcsDetection{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return VcsDetection{}, result.Error
	}
	if result.Status != "ok" || result.Detection == nil {
		return VcsDetection{}, newParseError(command, "root detection returned an invalid outcome", "")
	}
	return *result.Detection, nil
}

// PlanPluginVcsProvider asks Core to expand the process of one VCS provider. The plan's
// VcsProvider is the provider's descriptor.
func (c *Client) PlanPluginVcsProvider(ctx context.Context, manifest json.RawMessage, vcsProviderID string, directories PluginBackendDirectories) (PluginBackendPlan, error) {
	if vcsProviderID == "" {
		return PluginBackendPlan{}, newParseError("plugins.declarative.languageServerLaunchPlan", "no VCS provider was selected", "")
	}
	return c.planPluginLaunch(ctx, struct {
		Manifest      json.RawMessage          `json:"manifest"`
		VcsProviderID string                   `json:"vcsProviderID"`
		Request       PluginBackendDirectories `json:"request"`
	}{manifest, vcsProviderID, directories})
}

// Operations of a VCS provider, as lsp.vcsRequest and vcs.decodeReply name them.
const (
	VcsStatus        = "status"
	VcsBaseContent   = "baseContent"
	VcsHistory       = "history"
	VcsFileHistory   = "fileHistory"
	VcsAnnotate      = "annotate"
	VcsCheckin       = "checkin"
	VcsRollback      = "rollback"
	VcsUpdate        = "update"
	VcsFileOperation = "fileOperation"
	VcsResolve       = "resolve"
	VcsCleanup       = "cleanup"
)

// Capabilities a provider may negotiate beyond the required status, baseContent, checkin and
// rollback. The capability of an operation is named after it, except fileOperation
// (fileOperations) and resolve (conflicts).
const (
	VcsCapabilityHistory        = "history"
	VcsCapabilityFileHistory    = "fileHistory"
	VcsCapabilityAnnotate       = "annotate"
	VcsCapabilityUpdate         = "update"
	VcsCapabilityPush           = "push"
	VcsCapabilityStaging        = "staging"
	VcsCapabilityFileOperations = "fileOperations"
	VcsCapabilityConflicts      = "conflicts"
	VcsCapabilityCleanup        = "cleanup"
)

// PluginVcsRequest is one operation for a negotiated provider session. The completion arrives as
// a session event carrying the operation ID.
type PluginVcsRequest struct {
	SessionID   string `json:"sessionId"`
	OperationID string `json:"operationId,omitempty"`
	// Vcs is the VCS the session was launched for; Core refuses a session that negotiated
	// another one.
	Vcs       string `json:"vcs"`
	Operation string `json:"operation"`
	// Root is the native absolute path of the working copy, and Tool the absolute path of the VCS
	// client the host resolved, nil when the provider declares none.
	Root                string          `json:"root"`
	Tool                *string         `json:"tool"`
	Arguments           json.RawMessage `json:"arguments"`
	TimeoutMilliseconds int             `json:"timeoutMilliseconds,omitempty"`
}

// RequestPluginVcs queues one VCS operation and returns Core's operation ID. Core refuses an
// operation whose capability the provider did not negotiate, and malformed arguments, before
// anything reaches the provider.
func (c *Client) RequestPluginVcs(ctx context.Context, request PluginVcsRequest) (string, error) {
	const command = "lsp.vcsRequest"
	var response struct {
		OperationID string `json:"operationId"`
	}
	if err := c.Execute(ctx, command, request, &response); err != nil {
		return "", err
	}
	if response.OperationID == "" {
		return "", newParseError(command, "VCS request returned no operation ID", "")
	}
	return response.OperationID, nil
}

// VcsDecodeReply has Core check the reply of operation and returns the normalized result.
// capabilities are what the session negotiated, request the arguments the host sent and reply
// the provider's value. An invalid reply is a *MarketplaceRejection with the code
// plugin.vcs.invalidOutput.
func (c *Client) VcsDecodeReply(ctx context.Context, operation string, capabilities map[string]int, request, reply json.RawMessage) (json.RawMessage, error) {
	const command = "vcs.decodeReply"
	if capabilities == nil {
		capabilities = map[string]int{}
	}
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Result json.RawMessage       `json:"result"`
	}
	if err := c.Execute(ctx, command, struct {
		Operation    string          `json:"operation"`
		Capabilities map[string]int  `json:"capabilities"`
		Request      json.RawMessage `json:"request"`
		Reply        json.RawMessage `json:"reply"`
	}{operation, capabilities, request, reply}, &result); err != nil {
		return nil, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return nil, result.Error
	}
	if result.Status != "ok" || len(result.Result) == 0 {
		return nil, newParseError(command, "reply decoding returned an invalid outcome", "")
	}
	return result.Result, nil
}

// VcsRevision is one revision as the provider names it. Only the provider compares IDs; Display
// is what the user reads.
type VcsRevision struct {
	ID      string `json:"id"`
	Display string `json:"display"`
	Kind    string `json:"kind"`
}

// Label is the revision as the user reads it.
func (r *VcsRevision) Label() string {
	if r == nil {
		return ""
	}
	if r.Display != "" {
		return r.Display
	}
	return r.ID
}

// VcsHead is the revision, branch and remote location a working copy is at.
type VcsHead struct {
	Revision *VcsRevision `json:"revision"`
	Branch   *string      `json:"branch"`
	Location *string      `json:"location"`
}

// VcsChange is one changed path of a root, root-relative.
type VcsChange struct {
	Path    string   `json:"path"`
	OldPath *string  `json:"oldPath"`
	Status  string   `json:"status"`
	Flags   []string `json:"flags"`
	Staging string   `json:"staging,omitempty"`
}

// HasFlag reports whether the change carries flag.
func (c *VcsChange) HasFlag(flag string) bool {
	for _, f := range c.Flags {
		if f == flag {
			return true
		}
	}
	return false
}

// VcsStatusReply is the decoded status of a root, its changes sorted by path. A truncated status
// is not complete and is never shown as if it were.
type VcsStatusReply struct {
	Head      VcsHead     `json:"head"`
	Changes   []VcsChange `json:"changes"`
	Truncated bool        `json:"truncated"`
}

// VcsBaseContentReply is a file at its base revision: nil content when it has none (added or
// unversioned), and no content when it is binary.
type VcsBaseContentReply struct {
	Content *string `json:"content"`
	Binary  bool    `json:"binary"`
}

// VcsHistoryEntry is one revision of a history page.
type VcsHistoryEntry struct {
	Revision         VcsRevision `json:"revision"`
	Author           *string     `json:"author"`
	Date             *string     `json:"date"`
	Message          string      `json:"message"`
	Changes          []VcsChange `json:"changes"`
	ChangesTruncated bool        `json:"changesTruncated"`
}

// VcsHistoryReply is one page of revisions, newest first, and the cursor of the next one.
type VcsHistoryReply struct {
	Entries    []VcsHistoryEntry `json:"entries"`
	NextCursor *string           `json:"nextCursor"`
}

// VcsCheckinReply is the revision a check-in made, nil when the VCS reports none.
type VcsCheckinReply struct {
	Revision *VcsRevision `json:"revision"`
}

// VcsUpdateReply is the revision an update reached and the paths it left conflicted.
type VcsUpdateReply struct {
	Revision  *VcsRevision `json:"revision"`
	Conflicts []string     `json:"conflicts"`
}
