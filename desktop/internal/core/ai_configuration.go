package core

import (
	"context"
)

// AIConfigurationFile is one native file Core asks the platform to read for an
// AI CLI configuration source. File is the key the text is passed back under.
type AIConfigurationFile struct {
	File string `json:"file"`
	Path string `json:"path"`
}

// AIConfigurationProvider is the credential-free provider metadata parsed from a
// local Codex or Claude configuration. APIProtocol is responses,
// chatCompletions or anthropicMessages; Authentication is bearer or apiKey.
type AIConfigurationProvider struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Endpoint       string `json:"endpoint"`
	Model          string `json:"model"`
	APIProtocol    string `json:"apiProtocol"`
	Authentication string `json:"authentication"`
	Source         string `json:"source"`
	RequiresAPIKey bool   `json:"requiresApiKey"`
}

// AIConfigurationCredential locates the credential in the same files or
// environment that were passed to the parser. The value itself never crosses
// the Core boundary.
type AIConfigurationCredential struct {
	Kind string   `json:"kind"`
	Name string   `json:"name,omitempty"`
	File string   `json:"file,omitempty"`
	Path []string `json:"path,omitempty"`
}

// AIConfiguration is Core's parse result. A nil value from ParseAIConfiguration
// means nothing is configured. Provider is nil when the configuration parsed
// but is not a usable provider; Issue then names the stable reason code.
type AIConfiguration struct {
	Model                     string                     `json:"model"`
	Provider                  *AIConfigurationProvider   `json:"provider"`
	Issue                     *string                    `json:"issue"`
	ReasoningEffort           *string                    `json:"reasoningEffort"`
	HasCredential             bool                       `json:"hasCredential"`
	Credential                *AIConfigurationCredential `json:"credential"`
	UnsupportedAuthentication bool                       `json:"unsupportedAuthentication"`
}

// AIConfigurationParseRequest is the payload of ai.configuration.parse. Files is
// keyed like AIConfigurationFile.File: config, auth, settings, credentials and
// root. Environment is the process snapshot the credential locator is resolved
// against; it is not returned or logged.
type AIConfigurationParseRequest struct {
	Source          string            `json:"source"`
	Files           map[string]string `json:"files,omitempty"`
	Environment     map[string]string `json:"environment,omitempty"`
	AllowIncomplete bool              `json:"allowIncomplete,omitempty"`
}

// AIConfigurationSources names the native files of one AI CLI source. Core
// decides the paths; the platform only reads them. It is read-only and must run
// off the UI thread.
func (c *Client) AIConfigurationSources(ctx context.Context, source, home string, environment map[string]string) ([]AIConfigurationFile, error) {
	var result struct {
		Files []AIConfigurationFile `json:"files"`
	}
	err := c.Execute(ctx, "ai.configuration.sources", struct {
		Source      string            `json:"source"`
		Home        string            `json:"home"`
		Environment map[string]string `json:"environment,omitempty"`
	}{Source: source, Home: home, Environment: environment}, &result)
	return result.Files, err
}

// ParseAIConfiguration applies Core's shared rules to the text of the files
// named by AIConfigurationSources. The result carries metadata and a credential
// locator only; the platform resolves the locator natively.
func (c *Client) ParseAIConfiguration(ctx context.Context, request AIConfigurationParseRequest) (*AIConfiguration, error) {
	var result *AIConfiguration
	if err := c.Execute(ctx, "ai.configuration.parse", request, &result); err != nil {
		return nil, err
	}
	return result, nil
}
