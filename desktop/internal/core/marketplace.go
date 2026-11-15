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
	Status string                `json:"status"`
	Error  *MarketplaceRejection `json:"error"`
	Index  *MarketplaceIndex     `json:"index"`
	Source *MarketplaceSource    `json:"source"`
	Review *MarketplaceReview    `json:"review"`
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
	IndexURL    string  `json:"indexURL"`
	Repository  *string `json:"repository"`
	DisplayName string  `json:"displayName"`
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
	ID                    string                  `json:"id"`
	Name                  string                  `json:"name"`
	Author                string                  `json:"author"`
	Repository            string                  `json:"repository"`
	Homepage              *string                 `json:"homepage"`
	Description           string                  `json:"description"`
	LocalizedDescriptions map[string]string       `json:"localizedDescriptions"`
	Tags                  []string                `json:"tags"`
	License               string                  `json:"license"`
	Icon                  *string                 `json:"icon"`
	Platforms             []string                `json:"platforms"`
	LatestVersion         string                  `json:"latestVersion"`
	LatestReleaseDate     string                  `json:"latestReleaseDate"`
	Availability          MarketplaceAvailability `json:"availability"`
	Versions              []MarketplaceVersion    `json:"versions"`
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
