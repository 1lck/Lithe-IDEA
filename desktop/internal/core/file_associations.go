package core

import "context"

// FileAssociationLanguage is observed metadata from the bundled syntax registry.
type FileAssociationLanguage struct {
	ID          string   `json:"id"`
	Highlighted bool     `json:"highlighted"`
	Extensions  []string `json:"extensions"`
}

// FileAssociationFormat is a registrable text suffix selected by Core.
type FileAssociationFormat struct {
	Extension string `json:"extension"`
	Language  string `json:"language"`
}

func (c *Client) FileAssociationCatalog(ctx context.Context, languages []FileAssociationLanguage) ([]FileAssociationFormat, error) {
	var result struct {
		Formats []FileAssociationFormat `json:"formats"`
	}
	err := c.Execute(ctx, "application.fileAssociations.catalog", struct {
		Languages []FileAssociationLanguage `json:"languages"`
	}{nonNil(languages)}, &result)
	return result.Formats, err
}

// FileAssociationObservation contains native identities, excluding display labels.
type FileAssociationObservation struct {
	Extension    string `json:"extension"`
	DefaultID    string `json:"defaultId"`
	Registration string `json:"registration"`
}

type FileAssociationPlan struct {
	Conflict   bool     `json:"conflict"`
	Extensions []string `json:"extensions"`
}

func (c *Client) PlanFileAssociations(ctx context.Context, formats []FileAssociationFormat, selected []string, baseline, current []FileAssociationObservation) (FileAssociationPlan, error) {
	var result FileAssociationPlan
	err := c.Execute(ctx, "application.fileAssociations.plan", struct {
		Formats  []FileAssociationFormat      `json:"formats"`
		Selected []string                     `json:"selected"`
		Baseline []FileAssociationObservation `json:"baseline"`
		Current  []FileAssociationObservation `json:"current"`
	}{nonNil(formats), nonNil(selected), nonNil(baseline), nonNil(current)}, &result)
	return result, err
}
