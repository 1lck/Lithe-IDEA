package core

import (
	"context"
)

// ToolchainCatalog contains registrations and workspace trust owned by this machine, independent of project pins.
// DistrustedWorkspaces are the workspaces the user chose to keep in safe mode, and
// TrustedLocations the folders whose every workspace is trusted unless distrusted itself; Core
// normalizes both for the platform and never lists a filesystem root as a location.
type ToolchainCatalog struct {
	Version              int                              `json:"version"`
	Tools                map[string]ToolchainCatalogEntry `json:"tools"`
	TrustedWorkspaces    []string                         `json:"trustedWorkspaces,omitempty"`
	DistrustedWorkspaces []string                         `json:"distrustedWorkspaces,omitempty"`
	TrustedLocations     []string                         `json:"trustedLocations,omitempty"`
}

type ToolchainCatalogEntry struct {
	Homes       []string `json:"homes"`
	DefaultHome *string  `json:"defaultHome,omitempty"`
}

type ToolchainCatalogState struct {
	Document           ToolchainCatalog `json:"document"`
	ProjectCodeAllowed bool             `json:"projectCodeAllowed,omitempty"`
	// WorkspaceTrust is the trust of the requested workspace root; nil without one.
	WorkspaceTrust *ToolchainWorkspaceTrust `json:"workspaceTrust,omitempty"`
	Storage        struct {
		RelativePath string `json:"relativePath"`
		MaximumBytes int64  `json:"maximumBytes"`
	} `json:"storage"`
}

type ToolchainCatalogEdit struct {
	Tool        string   `json:"tool"`
	Homes       []string `json:"homes"`
	DefaultHome *string  `json:"defaultHome"`
}

// ToolchainWorkspaceTrustEdit records one decision on a workspace: Trusted lets its project code
// run and false keeps it in safe mode; Location also trusts its offered parent folder.
type ToolchainWorkspaceTrustEdit struct {
	Workspace string `json:"workspace"`
	Trusted   bool   `json:"trusted"`
	Location  bool   `json:"location,omitempty"`
}

// Workspace trust states Core reports.
const (
	WorkspaceTrusted    = "trusted"
	WorkspaceDistrusted = "distrusted"
	WorkspaceTrustUnset = "unknown"
)

// ToolchainWorkspaceTrust is a workspace's trust as Core decides it from the machine-local
// catalog: State is WorkspaceTrusted, WorkspaceDistrusted (kept in safe mode) or
// WorkspaceTrustUnset (never asked). Location is the trusted folder that trusts it, and
// OfferedLocation the parent folder a trust prompt may offer; nil when there is none.
type ToolchainWorkspaceTrust struct {
	State           string  `json:"state"`
	Location        *string `json:"location"`
	OfferedLocation *string `json:"offeredLocation"`
}

type ToolchainCatalogPublication struct {
	Changed  bool             `json:"changed"`
	Document *string          `json:"document"`
	Catalog  ToolchainCatalog `json:"catalog"`
}

func (c *Client) ReadToolchainCatalog(ctx context.Context, document *string, platform string) (ToolchainCatalogState, error) {
	return c.ReadToolchainCatalogForWorkspace(ctx, document, platform, "")
}

func (c *Client) ReadToolchainCatalogForWorkspace(ctx context.Context, document *string, platform, workspaceRoot string) (ToolchainCatalogState, error) {
	return settingsSurfaceResult[ToolchainCatalogState](ctx, c, "toolchains.catalogState", "state", struct {
		Document      *string `json:"document"`
		Platform      string  `json:"platform"`
		WorkspaceRoot string  `json:"workspaceRoot,omitempty"`
	}{document, platform, workspaceRoot})
}

func (c *Client) EditToolchainCatalog(ctx context.Context, document *string, platform string, edits []ToolchainCatalogEdit) (ToolchainCatalogPublication, error) {
	return settingsSurfaceResult[ToolchainCatalogPublication](ctx, c, "toolchains.editCatalog", "edit", struct {
		Document *string                `json:"document"`
		Platform string                 `json:"platform"`
		Edits    []ToolchainCatalogEdit `json:"edits"`
	}{document, platform, edits})
}

func (c *Client) EditToolchainWorkspaceTrust(ctx context.Context, document *string, platform string, trust ToolchainWorkspaceTrustEdit) (ToolchainCatalogPublication, error) {
	return settingsSurfaceResult[ToolchainCatalogPublication](ctx, c, "toolchains.editCatalog", "edit", struct {
		Document       *string                     `json:"document"`
		Platform       string                      `json:"platform"`
		WorkspaceTrust ToolchainWorkspaceTrustEdit `json:"workspaceTrust"`
	}{document, platform, trust})
}

// ToolchainTrustedLocationsEdit adds folders to the trusted locations and removes others. Core
// matches folders by the platform's path identity and refuses a filesystem root
// (plugin.toolchain.rootLocation), a folder both added and removed (invalidDocument) and a
// list past its bound (plugin.toolchain.trustListFull).
type ToolchainTrustedLocationsEdit struct {
	Add    []string `json:"add,omitempty"`
	Remove []string `json:"remove,omitempty"`
}

// EditToolchainTrustedLocations applies edit to document and returns the result. It writes
// nothing: the caller publishes the document against the bytes it read.
func (c *Client) EditToolchainTrustedLocations(ctx context.Context, document *string, platform string, edit ToolchainTrustedLocationsEdit) (ToolchainCatalogPublication, error) {
	return settingsSurfaceResult[ToolchainCatalogPublication](ctx, c, "toolchains.editCatalog", "edit", struct {
		Document         *string                       `json:"document"`
		Platform         string                        `json:"platform"`
		TrustedLocations ToolchainTrustedLocationsEdit `json:"trustedLocations"`
	}{document, platform, edit})
}
