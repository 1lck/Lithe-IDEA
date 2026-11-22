package core

import (
	"context"
	"encoding/json"
	"fmt"
)

// MarketplaceSourceKind identifies whether Core should apply official or third-party policy.
type MarketplaceSourceKind string

const (
	MarketplaceOfficial   MarketplaceSourceKind = "official"
	MarketplaceThirdParty MarketplaceSourceKind = "thirdParty"
)

// MarketplaceRejection is an index, source, or package refusal returned by Core.
type MarketplaceRejection struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Field   string `json:"field,omitempty"`
}

func (r *MarketplaceRejection) Error() string { return fmt.Sprintf("%s: %s", r.Code, r.Message) }

type marketplaceOutcome struct {
	Status         string                           `json:"status"`
	Error          *MarketplaceRejection            `json:"error"`
	Index          *MarketplaceIndex                `json:"index"`
	Source         *MarketplaceSource               `json:"source"`
	Selection      *MarketplaceAvailability         `json:"selection"`
	Manifest       json.RawMessage                  `json:"manifest"`
	Review         *MarketplaceReview               `json:"review"`
	Recommendation *MarketplaceRecommendationResult `json:"recommendation"`
}

func (o marketplaceOutcome) failure(command string) error {
	if o.Status == "rejected" && o.Error != nil {
		return o.Error
	}
	if o.Status != "ok" {
		return newParseError(command, "marketplace returned an invalid outcome", "")
	}
	return nil
}

// MarketplaceSource is Core's canonical index location and its optional repository.
type MarketplaceSource struct {
	IndexURL           string  `json:"indexURL"`
	RecommendationsURL string  `json:"recommendationsURL"`
	Repository         *string `json:"repository"`
	DisplayName        string  `json:"displayName"`
}

// MarketplaceAvailability is Core's platform and capability decision.
type MarketplaceAvailability struct {
	Status           string `json:"status"`
	Code             string `json:"code"`
	Platform         string `json:"platform"`
	Message          string `json:"message"`
	Version          string `json:"version"`
	PluginAPIVersion int    `json:"pluginAPIVersion"`
	ReleaseDate      string `json:"releaseDate"`
	DownloadURL      string `json:"downloadURL"`
	SHA256           string `json:"sha256"`
}

// MarketplaceVersion is one validated, ordered version of a marketplace entry.
type MarketplaceVersion struct {
	Version          string         `json:"version"`
	PluginAPIVersion int            `json:"pluginAPIVersion"`
	ReleaseDate      string         `json:"releaseDate"`
	Platforms        []string       `json:"platforms"`
	Requires         map[string]int `json:"requires"`
}

// MarketplacePlugin is a validated listing, with upstream-provided display text.
type MarketplacePlugin struct {
	ID                    string            `json:"id"`
	Name                  string            `json:"name"`
	Author                string            `json:"author"`
	Repository            string            `json:"repository"`
	Homepage              *string           `json:"homepage"`
	Description           string            `json:"description"`
	LocalizedDescriptions map[string]string `json:"localizedDescriptions"`
	Tags                  []string          `json:"tags"`
	License               string            `json:"license"`
	Icon                  *string           `json:"icon"`
	Platforms             []string          `json:"platforms"`
	LatestVersion         string            `json:"latestVersion"`
	LatestReleaseDate     string            `json:"latestReleaseDate"`
	// MarketplaceIndexURL identifies the validated source of a fetched listing. It is
	// native-only provenance and must never appear in the Core JSON contract.
	MarketplaceIndexURL string                  `json:"-"`
	Availability        MarketplaceAvailability `json:"availability"`
	Versions            []MarketplaceVersion    `json:"versions"`
}

// MarketplaceEntryRejection describes one rejected entry without hiding accepted entries.
type MarketplaceEntryRejection struct {
	ID    *string              `json:"id"`
	Error MarketplaceRejection `json:"error"`
}
type MarketplaceIndex struct {
	Plugins  []MarketplacePlugin         `json:"plugins"`
	Rejected []MarketplaceEntryRejection `json:"rejected"`
}

// MarketplaceReview lists the permissions and complete program declarations the user reviews.
type MarketplaceReview struct {
	ID          string            `json:"id"`
	Version     string            `json:"version"`
	Permissions []string          `json:"permissions"`
	Programs    []json.RawMessage `json:"programs"`
	NewPrograms []json.RawMessage `json:"newPrograms"`
}

// ResolveMarketplaceSource delegates URL validation and canonicalization to Core.
func (c *Client) ResolveMarketplaceSource(ctx context.Context, url string) (MarketplaceSource, error) {
	const command = "plugins.marketplace.resolveSource"
	var result marketplaceOutcome
	if err := c.Execute(ctx, command, struct {
		URL string `json:"url"`
	}{url}, &result); err != nil {
		return MarketplaceSource{}, err
	}
	if err := result.failure(command); err != nil {
		return MarketplaceSource{}, err
	}
	if result.Source == nil {
		return MarketplaceSource{}, newParseError(command, "marketplace returned no source", "")
	}
	return *result.Source, nil
}

// ValidateMarketplaceIndex asks Core to reject untrusted entries and compute availability.
// hostCapabilities must describe what this client actually supports, not what Core can parse.
func (c *Client) ValidateMarketplaceIndex(ctx context.Context, index json.RawMessage, kind MarketplaceSourceKind, platform string, hostCapabilities map[string][]int) (MarketplaceIndex, error) {
	const command = "plugins.marketplace.validateIndex"
	request := struct {
		Index            json.RawMessage       `json:"index"`
		SourceKind       MarketplaceSourceKind `json:"sourceKind"`
		Platform         string                `json:"platform"`
		HostCapabilities map[string][]int      `json:"hostCapabilities,omitempty"`
	}{index, kind, platform, hostCapabilities}
	var result marketplaceOutcome
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return MarketplaceIndex{}, err
	}
	if err := result.failure(command); err != nil {
		return MarketplaceIndex{}, err
	}
	if result.Index == nil {
		return MarketplaceIndex{}, newParseError(command, "marketplace returned no index", "")
	}
	return *result.Index, nil
}

// ReviewMarketplaceInstall asks Core to validate a package's manifest and enumerate programs.
func (c *Client) ReviewMarketplaceInstall(ctx context.Context, manifest json.RawMessage, expectedID, expectedVersion string, approvedPrograms []json.RawMessage, hostCapabilities map[string][]int) (MarketplaceReview, error) {
	const command = "plugins.marketplace.installReview"
	if hostCapabilities == nil {
		hostCapabilities = map[string][]int{}
	}
	request := struct {
		Manifest         json.RawMessage   `json:"manifest"`
		ExpectedID       string            `json:"expectedID,omitempty"`
		ExpectedVersion  string            `json:"expectedVersion,omitempty"`
		ApprovedPrograms []json.RawMessage `json:"approvedPrograms,omitempty"`
		HostCapabilities map[string][]int  `json:"hostCapabilities"`
	}{manifest, expectedID, expectedVersion, approvedPrograms, hostCapabilities}
	var result marketplaceOutcome
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return MarketplaceReview{}, err
	}
	if err := result.failure(command); err != nil {
		return MarketplaceReview{}, err
	}
	if result.Review == nil {
		return MarketplaceReview{}, newParseError(command, "marketplace returned no review", "")
	}
	return *result.Review, nil
}

// MarketplaceRemoteVariantRequest binds the fetched index to an approved release.
type MarketplaceRemoteVariantRequest struct {
	Index             json.RawMessage       `json:"index"`
	SourceKind        MarketplaceSourceKind `json:"sourceKind"`
	PluginID          string                `json:"pluginID"`
	Version           string                `json:"version"`
	InstalledPlatform string                `json:"installedPlatform"`
	InstalledSHA256   string                `json:"installedSha256"`
	Repository        string                `json:"repository,omitempty"`
	Target            RemotePlatform        `json:"target"`
	HostCapabilities  map[string][]int      `json:"hostCapabilities"`
}

// SelectMarketplaceRemoteVariant requests only the remote archive of the approved release.
func (c *Client) SelectMarketplaceRemoteVariant(ctx context.Context, request MarketplaceRemoteVariantRequest) (MarketplaceAvailability, error) {
	const command = "plugins.marketplace.selectRemoteVariant"
	var result marketplaceOutcome
	if err := c.Execute(WithoutRemoteWorkspace(ctx), command, request, &result); err != nil {
		return MarketplaceAvailability{}, err
	}
	if err := result.failure(command); err != nil {
		return MarketplaceAvailability{}, err
	}
	if result.Selection == nil || result.Selection.Status != "available" {
		return MarketplaceAvailability{}, newParseError(command, "marketplace returned no remote archive", "")
	}
	return *result.Selection, nil
}

// MarketplaceVariantReview carries the extracted manifest and the installed approval.
type MarketplaceVariantReview struct {
	InstalledManifest json.RawMessage   `json:"installedManifest"`
	VariantManifest   json.RawMessage   `json:"variantManifest"`
	PluginID          string            `json:"pluginID"`
	Version           string            `json:"version"`
	ApprovedPrograms  []json.RawMessage `json:"approvedPrograms"`
	HostCapabilities  map[string][]int  `json:"hostCapabilities"`
}

// VerifyMarketplaceRemoteVariant validates declaration equality and program approval in Core.
func (c *Client) VerifyMarketplaceRemoteVariant(ctx context.Context, request MarketplaceVariantReview) (json.RawMessage, error) {
	const command = "plugins.marketplace.verifyRemoteVariant"
	if request.ApprovedPrograms == nil {
		request.ApprovedPrograms = []json.RawMessage{}
	}
	var result marketplaceOutcome
	if err := c.Execute(WithoutRemoteWorkspace(ctx), command, request, &result); err != nil {
		return nil, err
	}
	if err := result.failure(command); err != nil {
		return nil, err
	}
	if len(result.Manifest) == 0 {
		return nil, newParseError(command, "marketplace returned no verified manifest", "")
	}
	return result.Manifest, nil
}

// MarketplaceDeployment identifies a verified package and its process inputs.
type MarketplaceDeployment struct {
	SHA256 string   `json:"sha256"`
	Paths  []string `json:"paths"`
}

// MarketplaceDeploymentRequest first plans a key and, after review and
// extraction, selects files from the verified archive inventory.
type MarketplaceDeploymentRequest struct {
	ArchiveSHA256       string          `json:"archiveSha256,omitempty"`
	InstalledTreeSHA256 string          `json:"installedTreeSha256,omitempty"`
	Manifest            json.RawMessage `json:"manifest"`
	Target              RemotePlatform  `json:"target"`
	RequiredPaths       []string        `json:"requiredPaths"`
	ArchiveFiles        []string        `json:"archiveFiles"`
}

// PlanMarketplaceRemoteDeployment validates the package paths and derives the lease key.
func (c *Client) PlanMarketplaceRemoteDeployment(ctx context.Context, request MarketplaceDeploymentRequest) (MarketplaceDeployment, error) {
	const command = "plugins.marketplace.planRemoteDeployment"
	var result struct {
		marketplaceOutcome
		Deployment *MarketplaceDeployment `json:"deployment"`
	}
	if err := c.Execute(WithoutRemoteWorkspace(ctx), command, request, &result); err != nil {
		return MarketplaceDeployment{}, err
	}
	if err := result.failure(command); err != nil {
		return MarketplaceDeployment{}, err
	}
	if result.Deployment == nil {
		return MarketplaceDeployment{}, newParseError(command, "marketplace returned no deployment", "")
	}
	return *result.Deployment, nil
}

// MarketplaceRecommendationCatalog pairs one marketplace index with its companion recommendations catalog.
type MarketplaceRecommendationCatalog struct {
	Index           json.RawMessage       `json:"index"`
	SourceKind      MarketplaceSourceKind `json:"sourceKind"`
	IndexURL        string                `json:"indexURL,omitempty"`
	Recommendations json.RawMessage       `json:"recommendations"`
}

// MarketplaceRecommendation is one validated plugin recommendation matched against the workspace.
type MarketplaceRecommendation struct {
	Plugin              MarketplacePlugin `json:"plugin"`
	MatchedMarkers      []string          `json:"matchedMarkers"`
	MatchedExtensions   []string          `json:"matchedExtensions"`
	MarketplaceIndexURL string            `json:"marketplaceIndexURL,omitempty"`
}

// MarketplaceRecommendationResult holds accepted recommendations and isolated catalog/entry rejections.
type MarketplaceRecommendationResult struct {
	Plugins  []MarketplaceRecommendation `json:"plugins"`
	Rejected []MarketplaceEntryRejection `json:"rejected"`
}

// RecommendMarketplacePlugins asks Core to match workspace signals against recommendation catalogs.
func (c *Client) RecommendMarketplacePlugins(
	ctx context.Context,
	platform string,
	workspaceFiles []string,
	catalogs []MarketplaceRecommendationCatalog,
	hostCapabilities map[string][]int,
	installedPluginIDs []string,
	dismissedPluginIDs []string,
) (MarketplaceRecommendationResult, error) {
	const command = "plugins.marketplace.recommendForWorkspace"
	if workspaceFiles == nil {
		workspaceFiles = []string{}
	}
	if catalogs == nil {
		catalogs = []MarketplaceRecommendationCatalog{}
	}
	if installedPluginIDs == nil {
		installedPluginIDs = []string{}
	}
	if dismissedPluginIDs == nil {
		dismissedPluginIDs = []string{}
	}
	request := struct {
		Platform           string                             `json:"platform"`
		WorkspaceFiles     []string                           `json:"workspaceFiles"`
		Catalogs           []MarketplaceRecommendationCatalog `json:"catalogs"`
		HostCapabilities   map[string][]int                   `json:"hostCapabilities,omitempty"`
		InstalledPluginIDs []string                           `json:"installedPluginIDs"`
		DismissedPluginIDs []string                           `json:"dismissedPluginIDs"`
	}{
		Platform:           platform,
		WorkspaceFiles:     workspaceFiles,
		Catalogs:           catalogs,
		HostCapabilities:   hostCapabilities,
		InstalledPluginIDs: installedPluginIDs,
		DismissedPluginIDs: dismissedPluginIDs,
	}
	var result marketplaceOutcome
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return MarketplaceRecommendationResult{}, err
	}
	if err := result.failure(command); err != nil {
		return MarketplaceRecommendationResult{}, err
	}
	if result.Recommendation == nil {
		return MarketplaceRecommendationResult{}, newParseError(command, "marketplace returned no recommendations", "")
	}
	for i := range result.Recommendation.Plugins {
		if result.Recommendation.Plugins[i].MarketplaceIndexURL != "" {
			result.Recommendation.Plugins[i].Plugin.MarketplaceIndexURL = result.Recommendation.Plugins[i].MarketplaceIndexURL
		}
	}
	return *result.Recommendation, nil
}
